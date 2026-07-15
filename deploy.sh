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

const port = Number(process.env.PORT || 3014);
const indexHtml = fs.readFileSync('/app/index.html');
const supportedVoices = new Set(['en-gb', 'en-us', 'es', 'fr', 'de', 'zh', 'ja']);

function send(res, status, headers, body) {
  res.writeHead(status, headers);
  res.end(body);
}

http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (url.pathname === '/api/tts') {
    const text = (url.searchParams.get('text') || '').slice(0, 1200).trim();
    const requestedVoice = (url.searchParams.get('voice') || 'en-gb').toLowerCase();
    const voice = supportedVoices.has(requestedVoice) ? requestedVoice : 'en-gb';

    if (!text) return send(res, 400, { 'Content-Type': 'text/plain' }, 'Missing text');

    res.writeHead(200, {
      'Content-Type': 'audio/wav',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff'
    });

    const espeak = spawn('espeak-ng', ['--stdout', '-v', voice, '-s', '165', text]);
    espeak.stdout.pipe(res);
    espeak.stderr.on('data', chunk => console.error(chunk.toString()));
    espeak.on('error', error => {
      console.error(error);
      if (!res.headersSent) res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('TTS failed');
    });
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
FROM node:22-alpine
RUN apk add --no-cache espeak-ng
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
echo "Local TTS: http://localhost:${PORT_ARG}/api/tts"
echo "========================================="
