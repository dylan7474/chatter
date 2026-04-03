#!/usr/bin/env bash

set -euo pipefail

# --- Configuration ---
PORT_ARG=${1:-3014}
PROJECT_NAME="Plane Spotter"
IMAGE_NAME="plane-spotter"
CONTAINER_NAME="plane-spotter"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Deploying ${PROJECT_NAME} ==="

# 1. Environment setup
cd "$SCRIPT_DIR"

# 2. Generate .dockerignore to prevent large context uploads
echo "Generating .dockerignore..."
cat <<'IGNORE_EOF' > .dockerignore
.git
.gitignore
node_modules
deploy.sh
README.md
LICENSE
AGENTS.md
Dockerfile
.dockerignore
IGNORE_EOF

# 3. Generate static server.js
echo "Generating server.js..."
cat <<'SERVER_EOF' > server.js
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const PORT = Number(process.env.PORT) || 3013;
const STATIC_ROOT = process.env.STATIC_ROOT || __dirname;
const DUMP1090_BASE_URL = process.env.DUMP1090_BASE_URL || 'http://192.168.50.100:8080';
const dumpBaseUrl = new URL(DUMP1090_BASE_URL);

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

const serveStatic = (req, res, url) => {
  const pathname = decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname);
  const safePath = path.normalize(pathname).replace(/^([.][./\\])+/, '');
  const filePath = path.join(STATIC_ROOT, safePath);

  fs.stat(filePath, (err, stats) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Not found');
      return;
    }

    if (stats.isDirectory()) {
      const indexPath = path.join(filePath, 'index.html');
      fs.stat(indexPath, (indexErr, indexStats) => {
        if (indexErr || !indexStats.isFile()) {
          res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
          res.end('Directory listing disabled');
          return;
        }

        res.writeHead(200, {
          'Content-Length': indexStats.size,
          'Content-Type': 'text/html; charset=utf-8',
          'Accept-Ranges': 'bytes',
        });
        fs.createReadStream(indexPath).pipe(res);
      });
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    const range = req.headers.range;

    if (range) {
      const parts = range.replace(/bytes=/, '').split('-');
      const start = parseInt(parts[0], 10);
      const end = parts[1] ? parseInt(parts[1], 10) : stats.size - 1;

      if (Number.isNaN(start) || Number.isNaN(end) || start > end || end >= stats.size) {
        res.writeHead(416, { 'Content-Range': `bytes */${stats.size}` });
        res.end();
        return;
      }

      res.writeHead(206, {
        'Content-Range': `bytes ${start}-${end}/${stats.size}`,
        'Accept-Ranges': 'bytes',
        'Content-Length': (end - start) + 1,
        'Content-Type': MIME_TYPES[ext] || 'application/octet-stream',
      });
      fs.createReadStream(filePath, { start, end }).pipe(res);
      return;
    }

    res.writeHead(200, {
      'Content-Length': stats.size,
      'Content-Type': MIME_TYPES[ext] || 'application/octet-stream',
      'Accept-Ranges': 'bytes',
    });
    fs.createReadStream(filePath).pipe(res);
  });
};

const proxyDump1090 = (req, res, url) => {
  const upstreamPath = url.pathname + (url.search || '');
  const isHttps = dumpBaseUrl.protocol === 'https:';
  const transport = isHttps ? https : http;

  const proxyReq = transport.request({
    protocol: dumpBaseUrl.protocol,
    hostname: dumpBaseUrl.hostname,
    port: dumpBaseUrl.port || (isHttps ? 443 : 80),
    method: req.method,
    path: upstreamPath,
    headers: {
      ...req.headers,
      host: dumpBaseUrl.host,
      connection: 'close',
      'x-forwarded-host': req.headers.host || '',
      'x-forwarded-proto': req.socket.encrypted ? 'https' : 'http'
    }
  }, (proxyRes) => {
    res.writeHead(proxyRes.statusCode || 502, proxyRes.headers);
    proxyRes.pipe(res);
  });

  proxyReq.on('error', (err) => {
    console.error('Dump1090 proxy error:', err.message);
    res.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({
      error: 'dump1090_proxy_error',
      message: err.message
    }));
  });

  if (req.method === 'GET' || req.method === 'HEAD') {
    proxyReq.end();
    return;
  }

  req.pipe(proxyReq);
};

http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname.startsWith('/dump1090-fa/')) {
    proxyDump1090(req, res, url);
    return;
  }
  serveStatic(req, res, url);
}).listen(PORT, () => {
  console.log(`Plane Spotter static server listening on port ${PORT}`);
  console.log(`Proxying /dump1090-fa/ to ${dumpBaseUrl.origin}`);
});
SERVER_EOF

# 4. Create Dockerfile optimized for this static app
cat <<DOCKER_EOF > Dockerfile
FROM node:20-slim
WORKDIR /app
COPY index.html server.js ./
EXPOSE ${PORT_ARG}
ENV PORT=${PORT_ARG}
ENV STATIC_ROOT=/app
CMD ["node", "server.js"]
DOCKER_EOF

# 5. Build and launch
echo "Building Docker image..."
docker build -t "$IMAGE_NAME" .

echo "Stopping existing container..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

echo "Starting new container..."
docker run -d \
  --name "$CONTAINER_NAME" \
  -p "$PORT_ARG:$PORT_ARG" \
  -e DUMP1090_BASE_URL="${DUMP1090_BASE_URL:-http://192.168.50.100:8080}" \
  --restart unless-stopped \
  "$IMAGE_NAME"

# Robust IP detection
IP_ADDR=$(python3 -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8', 80)); print(s.getsockname()[0]); s.close()" 2>/dev/null || echo "localhost")

echo "========================================="
echo "Deployed at http://${IP_ADDR}:${PORT_ARG}"
echo "========================================="
