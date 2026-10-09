#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v forge >/dev/null 2>&1; then
  echo "forge not found on PATH. Install Foundry: https://book.getfoundry.sh/getting-started/installation" >&2
  exit 1
fi

# Deps (forge-std, openzeppelin-contracts) are pinned git submodules under lib/.
# Idempotent: no-op when already initialised.
git submodule update --init --recursive

echo "Bootstrap complete. Run: forge test -vv"
