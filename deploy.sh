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

if ! [[ "$PORT_ARG" =~ ^[0-9]+$ ]] || [ "$PORT_ARG" -lt 1 ] || [ "$PORT_ARG" -gt 65535 ]; then
  echo "Error: port must be a number between 1 and 65535." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is required to deploy this application." >&2
  exit 1
fi

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
  let urlPath;
  try {
    urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
  } catch {
    res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Bad request');
    return;
  }

  const requestedPath = urlPath === '/' ? 'index.html' : urlPath.replace(/^\/+/, '');
  const filePath = path.resolve(ROOT, requestedPath);

  if (filePath !== ROOT && !filePath.startsWith(`${ROOT}${path.sep}`)) {
    res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Forbidden');
    return;
  }

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
    case "${TLS_HOST:-localhost}" in
      ''|*[!0-9.]*)
        TLS_SAN="DNS:${TLS_HOST:-localhost},DNS:localhost,IP:127.0.0.1"
        ;;
      *)
        TLS_SAN="IP:${TLS_HOST:-localhost},DNS:localhost,IP:127.0.0.1"
        ;;
    esac

    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${TLS_KEY_PATH:-/app/tls/key.pem}" \
      -out "${TLS_CERT_PATH:-/app/tls/cert.pem}" \
      -sha256 -days 365 \
      -subj "/CN=${TLS_HOST:-localhost}" \
      -addext "subjectAltName=${TLS_SAN}"
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

echo "Checking container health..."
HEALTHY=0
for _ in $(seq 1 20); do
  if docker exec "$CONTAINER_NAME" node -e "
    const https = require('https');
    const req = https.get({
      hostname: '127.0.0.1',
      port: process.env.PORT || '${PORT_ARG}',
      path: '/',
      rejectUnauthorized: false,
      timeout: 1000
    }, res => process.exit(res.statusCode === 200 ? 0 : 1));
    req.on('error', () => process.exit(1));
    req.on('timeout', () => req.destroy());
  " >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 0.5
done

if [ "$HEALTHY" -ne 1 ] || ! docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Error: deployment container failed to stay running." >&2
  docker logs "$CONTAINER_NAME" >&2 || true
  exit 1
fi

IP_ADDR=$(python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8', 80)); print(s.getsockname()[0]); s.close()" 2>/dev/null || echo "localhost")
DISPLAY_HOST="$HOST_ARG"
if [ "$DISPLAY_HOST" = "localhost" ] && [ "$IP_ADDR" != "localhost" ]; then
  DISPLAY_HOST="$IP_ADDR"
fi

echo "========================================="
echo "Deployed at https://${DISPLAY_HOST}:${PORT_ARG}"
echo "Note: first load uses a self-signed certificate; trust/accept it in your browser."
echo "========================================="
