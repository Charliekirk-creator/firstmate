#!/usr/bin/env bash
# Hold the canonical Main ownership transaction for one planning-store caller.
# Usage: FM_STATE_OVERRIDE=<home/state> fm-planning-lock-broker.sh <nonce> <parent-pid>
# The only lock is $STATE/.lock.acquire. No command or lock path is accepted.
# The caller creates $STATE/.planning-transaction.<nonce> mode 0700 and owns stdin.
# READY <nonce> <broker-pid> is published there and on stdout after acquisition.
# Send RELEASE <nonce>, or close stdin, to release. Parent death/signals also release.
# Orphan recovery and exact-owner release are exclusively fm-wake-lib.sh's protocol.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in --help|-h) head -n 8 "$0"; exit 0 ;; esac
[ "$#" -eq 2 ] || exit 2
nonce=$1 parent=$2
case "$nonce" in ''|*[!a-f0-9]*) exit 2 ;; esac
[ "${#nonce}" -eq 32 ] || exit 2
case "$parent" in ''|*[!0-9]*) exit 2 ;; esac
[ "$parent" -gt 1 ] && [ "$PPID" = "$parent" ] || exit 2
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
STATE="$(cd "$STATE" && pwd -P)"
receipt_dir="$STATE/.planning-transaction.$nonce"
[ -d "$receipt_dir" ] && [ ! -L "$receipt_dir" ] || exit 2
lock="$STATE/.lock.acquire"
held=0
cleanup() {
  if [ "$held" -eq 1 ]; then fm_lock_release "$lock"; held=0; fi
  rm -f "$receipt_dir/ready"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# Validate evidence without implementing another acquisition/steal algorithm.
# shellcheck source=bin/fm-session-transaction-lib.sh
. "$SCRIPT_DIR/fm-session-transaction-lib.sh"
for ((attempt=0; attempt<50; attempt++)); do
  kill -0 "$parent" 2>/dev/null || exit 1
  fm_session_transaction_evidence_valid "$lock" || { echo 'Planning lock is busy or ambiguous: malformed evidence' >&2; exit 1; }
  if fm_lock_try_acquire "$lock"; then held=1; break; fi
  sleep 0.1
done
[ "$held" -eq 1 ] || { echo 'Planning lock is busy: bounded acquisition timed out' >&2; exit 1; }
printf 'READY %s %s\n' "$nonce" "$$" > "$receipt_dir/prepared"
mv "$receipt_dir/prepared" "$receipt_dir/ready"
printf 'READY %s %s\n' "$nonce" "$$"
# This pipe is private to the spawning Node parent. Its death closes the last
# write end, so blocking read handles both ordinary EOF and abrupt parent loss.
command=
if IFS= read -r command; then
  [ "$command" = "RELEASE $nonce" ] && exit 0
  exit 2
fi
exit 0
