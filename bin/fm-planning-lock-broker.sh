#!/usr/bin/env bash
# Hold the canonical Main ownership transaction for one planning-store caller.
# Usage: FM_STATE_OVERRIDE=<home/state> fm-planning-lock-broker.sh <nonce> <parent-pid> <ledger-name>
# The only lock is $STATE/.lock.acquire. No command or lock path is accepted.
# The caller creates $STATE/.planning-transaction.<nonce> mode 0700 and owns stdin.
# Orphan recovery and acquisition are exclusively fm-wake-lib.sh's protocol.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in --help|-h) head -n 6 "$0"; exit 0 ;; esac
[ "$#" -eq 3 ] || exit 2
nonce=$1 parent=$2 ledger=$3
case "$nonce" in ''|*[!a-f0-9]*) exit 2 ;; esac
[ "${#nonce}" -eq 32 ] || exit 2
case "$parent" in ''|*[!0-9]*) exit 2 ;; esac
[ "$parent" -gt 1 ] && [ "$PPID" = "$parent" ] || exit 2
case "$ledger" in *.json) ;; *) exit 2 ;; esac
case "$ledger" in *[!A-Za-z0-9._-]*|.*|*/*) exit 2 ;; esac
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
STATE="$(cd "$STATE" && pwd -P)"
receipt_dir="$STATE/.planning-transaction.$nonce"
[ -d "$receipt_dir" ] && [ ! -L "$receipt_dir" ] || exit 2
lock="$STATE/.lock.acquire"
held=0
cleanup() {
  if [ "$held" -eq 1 ]; then fm_lock_release "$lock"; held=0; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# shellcheck source=bin/fm-session-transaction-lib.sh
. "$SCRIPT_DIR/fm-session-transaction-lib.sh"
for ((attempt=0; attempt<50; attempt++)); do
  kill -0 "$parent" 2>/dev/null || exit 1
  fm_session_transaction_evidence_valid "$lock" || { echo 'Planning lock is busy or ambiguous: malformed evidence' >&2; exit 1; }
  if fm_lock_try_acquire "$lock"; then held=1; break; fi
  sleep 0.1
done
[ "$held" -eq 1 ] || { echo 'Planning lock is busy: bounded acquisition timed out' >&2; exit 1; }
owner=${FM_LOCK_OWNER_DIR:-}
[ -n "$owner" ] || exit 1
trap - EXIT HUP INT TERM
exec node "$SCRIPT_DIR/fm-planning-lock-holder.mjs" "$nonce" "$parent" "$owner" "$ledger"
