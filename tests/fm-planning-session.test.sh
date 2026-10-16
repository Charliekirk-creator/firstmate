#!/usr/bin/env bash
# Executable slot scheduler, ledger, Wi-Fi evidence and table-delivery contracts.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo 'skip: Node is required for planning-session contracts'; exit 0; }
NODE_NO_WARNINGS=1 node --experimental-strip-types "$ROOT/tests/planning-lock-contract.mjs"
NODE_NO_WARNINGS=1 node --experimental-strip-types "$ROOT/tests/planning-session-contract.mjs"
NODE_NO_WARNINGS=1 node --experimental-strip-types "$ROOT/tests/planning-session-concurrent.mjs"
