#!/usr/bin/env bash
set -uo pipefail
cd ~/Proyectos/ethereum-infra-lab
NET="ethereum-infra-lab_ethnet"

while true; do
  EXEC=$(docker run --rm --network "$NET" curlimages/curl -s -X POST \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
    http://execution:8545)
  CONS=$(docker run --rm --network "$NET" curlimages/curl -s http://consensus:5052/eth/v1/node/syncing)

  echo "$(date +%T) exec=${EXEC} cons=${CONS}"

  if echo "$CONS" | grep -q '"is_syncing":false' && echo "$CONS" | grep -q '"is_optimistic":false'; then
    echo "SYNCED"
    exit 0
  fi
  sleep 60
done
