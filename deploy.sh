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
const piperModel = process.env.PIPER_MODEL || '/app/piper/en_US-lessac-low.onnx';
const piperBinary = process.env.PIPER_BINARY || 'piper';
const kokoroModel = process.env.KOKORO_MODEL || '/app/kokoro/kokoro-v1.0.onnx';
const kokoroVoices = process.env.KOKORO_VOICES || '/app/kokoro/voices-v1.0.bin';
const kokoroVoice = process.env.KOKORO_VOICE || 'af_heart';
const tmpDir = fs.existsSync('/dev/shm') ? '/dev/shm' : '/tmp';
const ttsCache = new Map();
const inFlightTts = new Map();
const maxCacheEntries = Number(process.env.TTS_CACHE_ENTRIES || 128);

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

http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

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
samples, sample_rate = kokoro.create(text, voice=voice, speed=1.0, lang='en-us')
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
  && curl -fsSL -o /app/piper/en_US-lessac-low.onnx https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/low/en_US-lessac-low.onnx \
  && curl -fsSL -o /app/piper/en_US-lessac-low.onnx.json https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/low/en_US-lessac-low.onnx.json \
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
  --restart unless-stopped \
  "${IMAGE_NAME}" >/dev/null

echo "========================================="
echo "Deployed ${PROJECT_NAME}."
echo "URL: http://localhost:${PORT_ARG}/"
echo "App file: http://localhost:${PORT_ARG}/index.html"
echo "Local TTS: http://localhost:${PORT_ARG}/api/tts
eSpeak, a default local Piper voice, and Kokoro-82M are bundled. Override PIPER_MODEL to use a mounted Piper .onnx voice model, or KOKORO_MODEL/KOKORO_VOICES/KOKORO_VOICE for Kokoro."
echo "========================================="
