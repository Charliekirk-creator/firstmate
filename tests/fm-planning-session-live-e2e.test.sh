#!/usr/bin/env bash
# Opt-in real Pi SDK lifecycle with a local mock provider and denied networking.
# No credentials, live Main state, activation, or runtime lifecycle operations.
set -eu
if [ "${FM_PLANNING_SESSION_LIVE:-0}" != 1 ]; then
  echo 'skip: set FM_PLANNING_SESSION_LIVE=1 for isolated real-Pi planning-session verification'
  exit 0
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo 'not ok - installed Pi SDK missing' >&2; exit 1; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-planning-session-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/code/.pi/extensions/lib" "$LAB/home/state" "$LAB/home/data/planning" "$LAB/pi" "$LAB/sessions"
git init -q "$LAB/code"
cp "$ROOT/.pi/extensions/fm-primary-planning-session.ts" "$LAB/code/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-planning-session.ts" "$LAB/code/.pi/extensions/lib/"
printf '%s\n' '# Fixture planning list: do not mutate' > "$LAB/home/data/planning/planning.md"
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_SUPERVISION_ACTOR
export LAB
FM_HOME="$LAB/home" PI_CODING_AGENT_DIR="$LAB/pi" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
  NODE_NO_WARNINGS=1 node --experimental-strip-types "$ROOT/tests/planning-session-live.mjs"
