#!/usr/bin/env bash

set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-database}"
LOCAL_PORT="${LOCAL_PORT:-8081}"

echo "Opening phpMyAdmin on http://127.0.0.1:${LOCAL_PORT}"
echo "Press Ctrl+C to stop the port-forward."

kubectl port-forward \
  --namespace "${NAMESPACE}" \
  service/phpmyadmin \
  "${LOCAL_PORT}:8081" \
  --address 127.0.0.1