#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v forge >/dev/null 2>&1; then
  echo "forge not found on PATH. Install Foundry: https://book.getfoundry.sh/getting-started/installation" >&2
  exit 1
fi

# Install deps if missing (idempotent-ish: forge install skips/updates as needed)
if [[ ! -d lib/forge-std ]]; then
  forge install foundry-rs/forge-std --no-commit
fi
if [[ ! -d lib/openzeppelin-contracts ]]; then
  forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-commit
fi

echo "Bootstrap complete. Run: forge test -vv"
