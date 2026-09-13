#!/usr/bin/env bash
# Tira un servicio para practicar el runbook. Uso: ./simulate-outage.sh execution|consensus
set -euo pipefail

SERVICE="${1:?uso: simulate-outage.sh execution|consensus}"

echo "Deteniendo $SERVICE..."
docker compose stop "$SERVICE"

echo "Esperando a que Prometheus marque TargetDown (mirar http://localhost:9090/alerts)."
echo "Cuando termines de practicar la deteccion/diagnostico, levantalo con:"
echo "  docker compose start $SERVICE"
