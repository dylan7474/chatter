#!/usr/bin/env bash

set -euo pipefail

PORT_ARG=${1:-3014}
PROJECT_NAME="chatter"
IMAGE_NAME="chatter"
CONTAINER_NAME="chatter"
HOST_ARG=${2:-localhost}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP_DOCKERFILE="${SCRIPT_DIR}/.Dockerfile.deploy"
TMP_SERVER="${SCRIPT_DIR}/.server.deploy.js"
TMP_ENTRYPOINT="${SCRIPT_DIR}/.entrypoint.deploy.sh"

cleanup() {
  rm -f "$TMP_DOCKERFILE" "$TMP_SERVER" "$TMP_ENTRYPOINT"
}
trap cleanup EXIT

echo "=== Deploying ${PROJECT_NAME} on port ${PORT_ARG} (host: ${HOST_ARG}) ==="
cd "$SCRIPT_DIR"

echo "Generating temporary static server..."
cat > "$TMP_SERVER" <<'SERVER_EOF'
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 3014);
const ROOT = process.env.STATIC_ROOT || '/app';
const ENABLE_HTTPS = process.env.ENABLE_HTTPS === '1';
const TLS_CERT_PATH = process.env.TLS_CERT_PATH || '/app/tls/cert.pem';
const TLS_KEY_PATH = process.env.TLS_KEY_PATH || '/app/tls/key.pem';

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.ico': 'image/x-icon',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
};

function sendFile(filePath, res) {
  fs.stat(filePath, (err, stat) => {
    if (err || !stat.isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Not found');
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, {
      'Content-Type': MIME_TYPES[ext] || 'application/octet-stream',
      'Content-Length': stat.size,
      'Cache-Control': 'no-cache',
    });

    fs.createReadStream(filePath).pipe(res);
  });
}

const requestHandler = (req, res) => {
  const urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
  const requestedPath = urlPath === '/' ? '/index.html' : urlPath;
  const safePath = path.normalize(requestedPath).replace(/^([.][./\\])+/, '');
  const filePath = path.join(ROOT, safePath);

  sendFile(filePath, res);
};

if (ENABLE_HTTPS) {
  const tlsOptions = {
    cert: fs.readFileSync(TLS_CERT_PATH),
    key: fs.readFileSync(TLS_KEY_PATH),
  };
  https.createServer(tlsOptions, requestHandler).listen(PORT, () => {
    console.log(`chatter static server listening with HTTPS on ${PORT}`);
  });
} else {
  http.createServer(requestHandler).listen(PORT, () => {
    console.log(`chatter static server listening with HTTP on ${PORT}`);
  });
}
SERVER_EOF

echo "Generating temporary entrypoint..."
cat > "$TMP_ENTRYPOINT" <<'ENTRYPOINT_EOF'
#!/usr/bin/env sh
set -eu

if [ "${ENABLE_HTTPS:-1}" = "1" ]; then
  mkdir -p /app/tls
  if [ ! -s "${TLS_CERT_PATH:-/app/tls/cert.pem}" ] || [ ! -s "${TLS_KEY_PATH:-/app/tls/key.pem}" ]; then
    echo "Generating self-signed TLS certificate for host: ${TLS_HOST:-localhost}"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${TLS_KEY_PATH:-/app/tls/key.pem}" \
      -out "${TLS_CERT_PATH:-/app/tls/cert.pem}" \
      -sha256 -days 365 \
      -subj "/CN=${TLS_HOST:-localhost}" \
      -addext "subjectAltName=DNS:${TLS_HOST:-localhost},IP:127.0.0.1"
  fi
fi

exec node /app/server.js
ENTRYPOINT_EOF

echo "Generating temporary Dockerfile..."
cat > "$TMP_DOCKERFILE" <<DOCKER_EOF
FROM node:20-alpine
RUN apk add --no-cache openssl
WORKDIR /app
COPY . /app
COPY .server.deploy.js /app/server.js
COPY .entrypoint.deploy.sh /app/entrypoint.sh
EXPOSE ${PORT_ARG}
ENV PORT=${PORT_ARG}
ENV STATIC_ROOT=/app
ENV ENABLE_HTTPS=1
ENV TLS_HOST=${HOST_ARG}
ENV TLS_CERT_PATH=/app/tls/cert.pem
ENV TLS_KEY_PATH=/app/tls/key.pem
RUN chmod +x /app/entrypoint.sh
CMD ["/app/entrypoint.sh"]
DOCKER_EOF

echo "Building Docker image..."
docker build -f "$TMP_DOCKERFILE" -t "$IMAGE_NAME" .

echo "Stopping existing container (if any)..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

echo "Starting container..."
docker run -d \
  --name "$CONTAINER_NAME" \
  -p "${PORT_ARG}:${PORT_ARG}" \
  --restart unless-stopped \
  "$IMAGE_NAME"

IP_ADDR=$(python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8', 80)); print(s.getsockname()[0]); s.close()" 2>/dev/null || echo "localhost")

echo "========================================="
echo "Deployed at https://${IP_ADDR}:${PORT_ARG}"
echo "Note: first load uses a self-signed certificate; trust/accept it in your browser."
echo "========================================="
