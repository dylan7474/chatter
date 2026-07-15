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

cat > "${BUILD_DIR}/nginx.conf" <<NGINX_EOF
server {
  listen ${PORT_ARG};
  server_name _;

  root /usr/share/nginx/html;
  index index.html;

  location / {
    try_files \$uri \$uri/ /index.html;
  }
}
NGINX_EOF

cat > "${BUILD_DIR}/Dockerfile" <<'DOCKER_EOF'
FROM nginx:1.29-alpine
COPY index.html /usr/share/nginx/html/index.html
COPY nginx.conf /etc/nginx/conf.d/default.conf
DOCKER_EOF

echo "Building Docker image..."
docker build -t "${IMAGE_NAME}" "${BUILD_DIR}"

echo "Stopping existing container (if any)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

echo "Starting container..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  -p "${PORT_ARG}:${PORT_ARG}" \
  --restart unless-stopped \
  "${IMAGE_NAME}" >/dev/null

echo "========================================="
echo "Deployed ${PROJECT_NAME}."
echo "URL: http://localhost:${PORT_ARG}/"
echo "App file: http://localhost:${PORT_ARG}/index.html"
echo "========================================="
