#!/usr/bin/env bash
set -euo pipefail

# Reset Envio local indexer for Anvil (clears generated + docker volumes) and regenerates from ./config.yaml
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# Stop and clean docker resources used by Envio (if any)
docker compose down -v || true

# Remove generated code to avoid stale USDC/mainnet artifacts
rm -rf generated

# Ensure deps are installed
pnpm install

# Regenerate with the local anvil config
pnpm exec envio codegen --config ./config.yaml

echo "\n✅ Reset complete. Now start indexer with:\n  ENVIO_CONFIG=./config.yaml TUI_OFF=true pnpm exec envio dev\n"
