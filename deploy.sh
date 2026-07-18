#!/usr/bin/env bash

set -euo pipefail

PORT_ARG=${1:-3014}
PROJECT_NAME="Chatter"
IMAGE_NAME="chatter"
CONTAINER_NAME="chatter"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! [[ "${PORT_ARG}" =~ ^[0-9]+$ ]] || (( PORT_ARG < 1 || PORT_ARG > 65535 )); then
  echo "Error: PORT must be an integer between 1 and 65535."
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is required but was not found in PATH."
  exit 1
fi

if [ ! -f "${SCRIPT_DIR}/index.html" ]; then
  echo "Error: index.html was not found in ${SCRIPT_DIR}."
  exit 1
fi

echo "=== Deploying ${PROJECT_NAME} on http://localhost:${PORT_ARG} ==="

BUILD_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${BUILD_DIR}"
}
trap cleanup EXIT

cp "${SCRIPT_DIR}/index.html" "${BUILD_DIR}/index.html"

cat > "${BUILD_DIR}/server.js" <<'NODE_EOF'
const http = require('http');
const fs = require('fs');
const { spawn } = require('child_process');
const crypto = require('crypto');

const port = Number(process.env.PORT || 3014);
const indexHtml = fs.readFileSync('/app/index.html');
const supportedVoices = new Set(['en-gb', 'en-us', 'es', 'fr', 'de', 'zh', 'ja']);
const piperModel = process.env.PIPER_MODEL || '/app/piper/en_GB-southern_english_female-low.onnx';
const piperBinary = process.env.PIPER_BINARY || 'piper';
const kokoroModel = process.env.KOKORO_MODEL || '/app/kokoro/kokoro-v1.0.onnx';
const kokoroVoices = process.env.KOKORO_VOICES || '/app/kokoro/voices-v1.0.bin';
const kokoroVoice = process.env.KOKORO_VOICE || 'bf_emma';
const tmpDir = fs.existsSync('/dev/shm') ? '/dev/shm' : '/tmp';
const ttsCache = new Map();
const inFlightTts = new Map();
const maxCacheEntries = Number(process.env.TTS_CACHE_ENTRIES || 128);
const geminiModel = process.env.GEMINI_MODEL || 'gemini-3.5-flash';
const defaultOllamaEndpoint = process.env.OLLAMA_ENDPOINT || 'http://host.docker.internal:11434';
const geminiKeys = {
  primary: process.env.GEMINI_API_KEY_PRIMARY || process.env.GEMINI_API_KEY || '',
  secondary: process.env.GEMINI_API_KEY_SECONDARY || ''
};

function cacheKey(engine, voice, text) {
  return crypto.createHash('sha256').update(`${engine}\0${voice}\0${text}`).digest('hex');
}

function getCachedAudio(key) {
  const cached = ttsCache.get(key);
  if (!cached) return null;
  ttsCache.delete(key);
  ttsCache.set(key, cached);
  return cached;
}

function setCachedAudio(key, audio) {
  ttsCache.set(key, audio);
  while (ttsCache.size > maxCacheEntries) {
    const oldestKey = ttsCache.keys().next().value;
    ttsCache.delete(oldestKey);
  }
}

function synthesizeWithProcess(command, args, text, outputFile, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      ...options,
      env: {
        ...process.env,
        OMP_NUM_THREADS: process.env.OMP_NUM_THREADS || '1',
        ORT_NUM_THREADS: process.env.ORT_NUM_THREADS || '1',
        ...options.env
      }
    });
    let stderr = '';
    child.stderr?.on('data', chunk => {
      stderr += chunk.toString();
      if (stderr.length > 4000) stderr = stderr.slice(-4000);
    });
    child.on('error', reject);
    child.on('close', code => {
      if (code !== 0) return reject(new Error(`${command} exited with status ${code}: ${stderr}`));
      fs.readFile(outputFile, (readError, audio) => {
        fs.rm(outputFile, { force: true }, () => {});
        if (readError) return reject(readError);
        resolve(audio);
      });
    });
    child.stdin.end(text);
  });
}

async function synthesizeCached(key, synthesize) {
  const cached = getCachedAudio(key);
  if (cached) return cached;
  if (inFlightTts.has(key)) return inFlightTts.get(key);
  const promise = synthesize().then(audio => {
    setCachedAudio(key, audio);
    return audio;
  }).finally(() => inFlightTts.delete(key));
  inFlightTts.set(key, promise);
  return promise;
}

function send(res, status, headers, body) {
  res.writeHead(status, headers);
  res.end(body);
}

function readJsonBody(req, limit = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk;
      if (body.length > limit) {
        reject(new Error('Request body too large'));
        req.destroy();
      }
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (error) {
        reject(new Error('Invalid JSON body'));
      }
    });
    req.on('error', reject);
  });
}


function normalizeOllamaEndpoint(endpoint) {
  let parsed;
  try {
    parsed = new URL(endpoint);
  } catch (error) {
    throw new Error('Invalid Ollama endpoint');
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error('Ollama endpoint must use http or https');
  parsed.username = '';
  parsed.password = '';
  parsed.hash = '';
  parsed.search = '';
  return parsed;
}

async function proxyOllama(req, res, url) {
  const allowedPaths = new Set(['/api/tags', '/api/chat']);
  const path = url.searchParams.get('path') || '';
  if (!allowedPaths.has(path)) return send(res, 400, { 'Content-Type': 'text/plain' }, 'Unsupported Ollama proxy path');
  if (path === '/api/tags' && req.method !== 'GET') return send(res, 405, { 'Content-Type': 'text/plain' }, 'Method not allowed');
  if (path === '/api/chat' && req.method !== 'POST') return send(res, 405, { 'Content-Type': 'text/plain' }, 'Method not allowed');

  let upstreamUrl;
  try {
    const endpoint = normalizeOllamaEndpoint(url.searchParams.get('endpoint') || defaultOllamaEndpoint);
    upstreamUrl = new URL(path, endpoint);
  } catch (error) {
    return send(res, 400, { 'Content-Type': 'text/plain' }, error.message);
  }

  try {
    const headers = { 'Accept': req.headers.accept || 'application/json' };
    let body;
    if (req.method === 'POST') {
      const requestBody = await readJsonBody(req);
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(requestBody);
    }

    const upstream = await fetch(upstreamUrl, { method: req.method, headers, body });
    res.writeHead(upstream.status, {
      'Content-Type': upstream.headers.get('content-type') || 'application/json',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff'
    });
    if (upstream.body) {
      for await (const chunk of upstream.body) res.write(chunk);
    }
    res.end();
  } catch (error) {
    console.error(error);
    if (!res.headersSent) send(res, 502, { 'Content-Type': 'text/plain' }, 'Ollama proxy failed');
    else res.end();
  }
}

async function proxyGemini(req, res, url) {
  if (req.method !== 'POST') return send(res, 405, { 'Content-Type': 'text/plain' }, 'Method not allowed');
  const slot = url.searchParams.get('slot') === 'secondary' ? 'secondary' : 'primary';
  const apiKey = geminiKeys[slot];
  if (!apiKey) return send(res, 503, { 'Content-Type': 'text/plain' }, 'Gemini API key is not configured on the server');

  try {
    const requestBody = await readJsonBody(req);
    const shouldStream = url.searchParams.get('stream') === '1';
    const geminiEndpoint = shouldStream ? 'streamGenerateContent?alt=sse' : 'generateContent';
    const separator = shouldStream ? '&' : '?';
    const geminiUrl = `https://generativelanguage.googleapis.com/v1beta/models/${geminiModel}:${geminiEndpoint}${separator}key=${encodeURIComponent(apiKey)}`;
    const upstream = await fetch(geminiUrl, {
      method: 'POST',
      headers: {
        'Accept': shouldStream ? 'text/event-stream' : 'application/json',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(requestBody)
    });

    res.writeHead(upstream.status, {
      'Content-Type': upstream.headers.get('content-type') || (shouldStream ? 'text/event-stream' : 'application/json'),
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff'
    });
    if (upstream.body) {
      for await (const chunk of upstream.body) res.write(chunk);
    }
    res.end();
  } catch (error) {
    console.error(error);
    if (!res.headersSent) send(res, 500, { 'Content-Type': 'text/plain' }, 'Gemini proxy failed');
    else res.end();
  }
}

http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (url.pathname === '/api/config') {
    return send(res, 200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }, JSON.stringify({
      geminiKeys: { primary: Boolean(geminiKeys.primary), secondary: Boolean(geminiKeys.secondary) },
      ollamaProxy: true,
      defaultOllamaEndpoint
    }));
  }

  if (url.pathname === '/api/gemini') {
    return proxyGemini(req, res, url);
  }

  if (url.pathname === '/api/ollama') {
    return proxyOllama(req, res, url);
  }

  if (url.pathname === '/api/tts') {
    const text = (url.searchParams.get('text') || '').slice(0, 1200).trim();
    const engine = (url.searchParams.get('engine') || 'espeak').toLowerCase();
    const requestedVoice = (url.searchParams.get('voice') || 'en-gb').toLowerCase();
    const voice = supportedVoices.has(requestedVoice) ? requestedVoice : 'en-gb';

    if (!text) return send(res, 400, { 'Content-Type': 'text/plain' }, 'Missing text');
    const audioHeaders = {
      'Content-Type': 'audio/wav',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff'
    };

    const fail = error => {
      console.error(error);
      if (!res.headersSent) res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('TTS failed');
    };

    if (engine === 'piper') {
      if (!fs.existsSync(piperModel)) {
        return send(res, 503, { 'Content-Type': 'text/plain' }, `Piper model was not found at ${piperModel}`);
      }

      const key = cacheKey(engine, piperModel, text);
      const outputFile = `${tmpDir}/piper-${Date.now()}-${Math.random().toString(16).slice(2)}.wav`;
      synthesizeCached(key, () => synthesizeWithProcess(piperBinary, ['--model', piperModel, '--output_file', outputFile], text, outputFile))
        .then(audio => send(res, 200, { ...audioHeaders, 'Content-Length': audio.length }, audio))
        .catch(fail);
      return;
    }

    if (engine === 'kokoro') {
      if (!fs.existsSync(kokoroModel) || !fs.existsSync(kokoroVoices)) {
        return send(res, 503, { 'Content-Type': 'text/plain' }, 'Kokoro model files were not found');
      }

      const key = cacheKey(engine, kokoroVoice, text);
      const outputFile = `${tmpDir}/kokoro-${Date.now()}-${Math.random().toString(16).slice(2)}.wav`;
      const kokoroScript = `import sys
from kokoro_onnx import Kokoro
import soundfile as sf
model, voices, output_file, voice = sys.argv[1:5]
text = sys.stdin.read().strip()
kokoro = Kokoro(model, voices)
samples, sample_rate = kokoro.create(text, voice=voice, speed=1.0, lang='en-gb')
sf.write(output_file, samples, sample_rate)
`;
      synthesizeCached(key, () => synthesizeWithProcess('python3', ['-c', kokoroScript, kokoroModel, kokoroVoices, outputFile, kokoroVoice], text, outputFile, { stdio: ['pipe', 'ignore', 'pipe'] }))
        .then(audio => send(res, 200, { ...audioHeaders, 'Content-Length': audio.length }, audio))
        .catch(fail);
      return;
    }

    res.writeHead(200, audioHeaders);
    const espeak = spawn('espeak-ng', ['--stdout', '-v', voice, '-s', '165', text]);
    espeak.stdout.pipe(res);
    espeak.stderr.on('data', chunk => console.error(chunk.toString()));
    espeak.on('error', fail);
    return;
  }

  if (url.pathname === '/' || url.pathname === '/index.html') {
    return send(res, 200, { 'Content-Type': 'text/html; charset=utf-8' }, indexHtml);
  }

  send(res, 404, { 'Content-Type': 'text/plain' }, 'Not found');
}).listen(port, '0.0.0.0', () => {
  console.log(`Chatter listening on http://0.0.0.0:${port}`);
});
NODE_EOF

cat > "${BUILD_DIR}/Dockerfile" <<'DOCKER_EOF'
FROM node:22-bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl espeak-ng python3-pip \
  && pip3 install --break-system-packages --no-cache-dir piper-tts kokoro-onnx soundfile \
  && mkdir -p /app/piper /app/kokoro \
  && curl -fsSL -o /app/piper/en_GB-southern_english_female-low.onnx https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/southern_english_female/low/en_GB-southern_english_female-low.onnx \
  && curl -fsSL -o /app/piper/en_GB-southern_english_female-low.onnx.json https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/southern_english_female/low/en_GB-southern_english_female-low.onnx.json \
  && curl -fsSL -o /app/kokoro/kokoro-v1.0.onnx https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx \
  && curl -fsSL -o /app/kokoro/voices-v1.0.bin https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY index.html server.js ./
ENV PORT=3014
CMD ["node", "server.js"]
DOCKER_EOF

echo "Building Docker image..."
docker build -t "${IMAGE_NAME}" "${BUILD_DIR}"

echo "Stopping existing container (if any)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

echo "Starting container..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  -p "${PORT_ARG}:${PORT_ARG}" \
  -e PORT="${PORT_ARG}" \
  -e GEMINI_API_KEY \
  -e GEMINI_API_KEY_PRIMARY \
  -e GEMINI_API_KEY_SECONDARY \
  -e GEMINI_MODEL \
  -e OLLAMA_ENDPOINT \
  --add-host=host.docker.internal:host-gateway \
  --restart unless-stopped \
  "${IMAGE_NAME}" >/dev/null

echo "========================================="
echo "Deployed ${PROJECT_NAME}."
echo "URL: http://localhost:${PORT_ARG}/"
echo "App file: http://localhost:${PORT_ARG}/index.html"
echo "Local TTS: http://localhost:${PORT_ARG}/api/tts
Gemini proxy: http://localhost:${PORT_ARG}/api/gemini
Ollama proxy: http://localhost:${PORT_ARG}/api/ollama (defaults host Ollama to ${OLLAMA_ENDPOINT:-http://host.docker.internal:11434})
Gemini keys: set GEMINI_API_KEY, GEMINI_API_KEY_PRIMARY, or GEMINI_API_KEY_SECONDARY before running deploy.sh
eSpeak, a default UK English local Piper voice, and Kokoro-82M are bundled. Override PIPER_MODEL to use a mounted Piper .onnx voice model, or KOKORO_MODEL/KOKORO_VOICES/KOKORO_VOICE for Kokoro."
echo "========================================="
