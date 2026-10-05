#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real agent is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, so registering and not registering an agent on a plain
# shell pane exercises exactly the classification the control plane gates on.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_HELPER="$(cd "$(dirname "$HERDR_LAB_HELPER")" && pwd -P)/$(basename "$HERDR_LAB_HELPER")"
SESSION=$("$HERDR_LAB_HELPER" name "${HERDR_LAB_LABEL:-control-cwd-smoke}") || exit 1
export HERDR_SESSION="$SESSION"
REAL_PATH=$PATH
SCRATCH=
cleanup_all() {
  local rc=$?
  PATH="$REAL_PATH" "$HERDR_LAB_HELPER" teardown "$SESSION" || rc=1
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
  return "$rc"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd -P)
# Even backend-internal CLI reads and the version probe go through the lab
# owner. The wrapper removes only the verified trailing session, then lets the
# helper append its own exact scope with an unwrapped PATH (no recursion).
mkdir "$SCRATCH/fakebin"
export FM_SMOKE_LAB_HELPER="$HERDR_LAB_HELPER" FM_SMOKE_LAB_SESSION="$SESSION" FM_SMOKE_REAL_PATH="$REAL_PATH"
cat > "$SCRATCH/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "$#" = 2 ] && [ "$2" = "$FM_SMOKE_LAB_SESSION" ] || exit 1
    break
  fi
  args+=("$1"); shift
done
PATH="$FM_SMOKE_REAL_PATH" "$FM_SMOKE_LAB_HELPER" run "$FM_SMOKE_LAB_SESSION" "${args[@]}"
SH
chmod +x "$SCRATCH/fakebin/herdr"
export PATH="$SCRATCH/fakebin:$PATH"
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent: classification flips, and the verbs follow ---------

# Keep the fixture off its shell prompt while the registration is tested:
# modern shell integration retires a synthetic agent report at an idle prompt.
"$HERDR_LAB_HELPER" run "$SESSION" pane run "$PANE_ID" 'sleep 300' || fail "could not start foreground fixture"
sleep 0.5
herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Last, because it deliberately types a harness command into a pane that hosts
# a plain shell: the registered agent cannot actually be stopped that way, and
# the control plane must say so rather than report a stop it did not achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

# --- cwd drift repair: real split, binding, guard and launch -----------------
# A real child process stands in for Pi's expensive model invocation. The
# actual fm-control/fm-spawn path still drives the real backend, and this
# process reports through Herdr's real registry only once launched in the pane.
python3 - "$SCRATCH/fakebin/pi" "$HERDR_LAB_HELPER" "$SESSION" "$SCRATCH/launch-proof" <<'PY'
import json, sys
from pathlib import Path
p, helper, session, proof = sys.argv[1:]
Path(p).write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
if '--version' in sys.argv:
    print('test-pi 1.0'); sys.exit(0)
pathlib.Path(PROOF).write_text(os.getcwd())
subprocess.run([HELPER, 'run', SESSION, 'pane', 'report-agent', os.environ['HERDR_PANE_ID'],
                '--source', 'cwd-smoke', '--agent', 'pi', '--state', 'idle'], check=True)
time.sleep(300)
'''.replace('PROOF', json.dumps(proof)).replace('HELPER', json.dumps(helper)).replace('SESSION', json.dumps(session)))
Path(p).chmod(0o755)
PY
REPAIR_RAW=$("$HERDR_LAB_HELPER" run "$SESSION" workspace create --label cwd-repair --cwd "$PROJ" --no-focus) \
  || fail "could not create repair fixture"
REPAIR_PANE=$(printf '%s' "$REPAIR_RAW" | jq -r '.result.root_pane.pane_id')
REPAIR_TAB=$(printf '%s' "$REPAIR_RAW" | jq -r '.result.tab.tab_id')
REPAIR_WS=$(printf '%s' "$REPAIR_RAW" | jq -r '.result.workspace.workspace_id')
# Fixture setup alone controls this lab shell. The repair must send it no
# input even if text is already buffered there.
"$HERDR_LAB_HELPER" run "$SESSION" pane run "$REPAIR_PANE" 'exec /bin/bash --noprofile --norc -i' || fail "could not seed bare fixture shell"
sleep 1
fm_backend_herdr_pane_idle_shell_pid "$SESSION" "$REPAIR_PANE" interactive >/dev/null \
  || fail "interactive Bash pane did not provide exact TTY ownership evidence"
ZSH_RAW=$("$HERDR_LAB_HELPER" run "$SESSION" workspace create --label cwd-zsh-proof --cwd "$PROJ" --no-focus) \
  || fail "could not create Zsh proof fixture"
ZSH_PANE=$(printf '%s' "$ZSH_RAW" | jq -r '.result.root_pane.pane_id')
"$HERDR_LAB_HELPER" run "$SESSION" pane run "$ZSH_PANE" 'exec /bin/zsh -f -i' || fail "could not seed Zsh proof fixture"
sleep 1
fm_backend_herdr_pane_idle_shell_pid "$SESSION" "$ZSH_PANE" interactive >/dev/null \
  || fail "interactive Zsh pane did not provide exact TTY ownership evidence"
"$HERDR_LAB_HELPER" run "$SESSION" pane close "$ZSH_PANE" || fail "could not close Zsh proof fixture"
FIFO_PATH="$SCRATCH/noninteractive-shell.fifo"
mkfifo "$FIFO_PATH" || fail "could not create FIFO proof fixture"
exec 8<> "$FIFO_PATH"
FIFO_RAW=$("$HERDR_LAB_HELPER" run "$SESSION" workspace create --label cwd-fifo-proof --cwd "$PROJ" --no-focus) \
  || fail "could not create FIFO proof pane"
FIFO_PANE=$(printf '%s' "$FIFO_RAW" | jq -r '.result.root_pane.pane_id')
printf -v FIFO_COMMAND 'exec /bin/bash --noprofile --norc < %q' "$FIFO_PATH"
"$HERDR_LAB_HELPER" run "$SESSION" pane run "$FIFO_PANE" "$FIFO_COMMAND" || fail "could not seed FIFO-blocked shell"
sleep 1
if fm_backend_herdr_pane_idle_shell_pid "$SESSION" "$FIFO_PANE" interactive >/dev/null 2>&1; then
  fail "FIFO-blocked noninteractive Bash was accepted as an interactive pane shell"
fi
"$HERDR_LAB_HELPER" run "$SESSION" pane close "$FIFO_PANE" || fail "could not close FIFO proof fixture"
exec 8>&-
pass "real herdr: exact TTY proof accepts interactive Bash/Zsh and rejects FIFO stdin"
printf -v OLD_BUFFER 'printf OLD-INPUT-MUST-NOT-RUN > %q; ' "$SCRATCH/old-input-ran"
"$HERDR_LAB_HELPER" run "$SESSION" pane send-text "$REPAIR_PANE" "$OLD_BUFFER" || fail "could not buffer old fixture input"
mkdir -p "$HOME_DIR/data/rsmoke"
printf '# Lab-only task.\n' > "$HOME_DIR/data/rsmoke/brief.md"
{
  printf 'window=%s:%s\nendpoint_task_id=rsmoke\nworktree=%s\nproject=%s\n' "$SESSION" "$REPAIR_PANE" "$WT" "$PROJ"
  printf 'harness=pi\nkind=ship\nmode=no-mistakes\nyolo=off\nmodel=default\neffort=default\nbackend=herdr\n'
  printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$SESSION" "$REPAIR_WS" "$REPAIR_TAB" "$REPAIR_PANE"
} > "$HOME_DIR/state/rsmoke.meta"
printf 'preserved\n' > "$WT/untracked-progress"
HEAD_BEFORE=$(git -C "$WT" rev-parse HEAD)
OUT=$(FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=10 \
  "$ROOT/bin/fm-control.sh" rsmoke relaunch --repair-cwd --note 'lab repair proof' 2>&1) || fail "real cwd repair refused: $OUT"
NEW_PANE=$(fm_meta_get "$HOME_DIR/state/rsmoke.meta" herdr_pane_id)
[ "$NEW_PANE" != "$REPAIR_PANE" ] || fail "repair did not rebind to a sibling"
[ "$(fm_backend_herdr_pane_agent_state "$SESSION" "$REPAIR_PANE")" = dead ] || fail "old pane was not retired"
[ "$(fm_backend_herdr_pane_agent_state "$SESSION" "$NEW_PANE")" = live ] || fail "replacement did not register"
[ "$(cat "$SCRATCH/launch-proof")" = "$WT" ] || fail "replacement ran outside its recorded worktree"
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail "repair changed HEAD"
[ "$(cat "$WT/untracked-progress")" = preserved ] || fail "repair lost untracked work"
[ ! -e "$SCRATCH/old-input-ran" ] || fail "repair submitted the old shell's buffered input"
pass "real herdr: cwd repair splits in the recorded worktree, rebinds, launches and retires only the old pane"
pass "real herdr: repair preserves HEAD, untracked work and the independent launch directory guard"
# Session-wide cleanup stays exclusively with the guarded lab owner.
