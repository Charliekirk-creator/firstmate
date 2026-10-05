#!/usr/bin/env bash
# Additional public-interface relaunch cases, sourced by fm-control-relaunch.

cwd_case() { # <mode>
  local dir=$1 mode=${2:-}
  add_ship_task "$dir" rcwd claude
  python3 - "$dir" "$mode" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1])
meta=p/'home/state/rcwd.meta'
s=meta.read_text().replace('window=fmses:fm-rcwd', 'window=fm-lab-control:w1:p1')
s+='backend=herdr\nherdr_session=fm-lab-control\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\n'
meta.write_text(s)
(p/'fake/herdr-state').write_text(json.dumps({'mode':sys.argv[2], 'primary':str(p/'proj'), 'target':str((p/'wt').resolve()), 'panes':{'w1:p1':{'cwd':str(p/'proj')}}}))
(p/'fake/home-state').symlink_to(p/'home/state')
PY
  cp "$ROOT/tests/control-cwd-herdr.py" "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"
  cat > "$dir/fakebin/ps-herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-axo pid=,ppid=') printf '44101 1\n44102 1\n' ;;
  *'-o stat=') printf 'Ss+\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/ps-herdr"
  cp "$dir/home/state/rcwd.meta" "$dir/meta-before"
  cp "$dir/home/data/rcwd/brief.md" "$dir/brief-before"
}

cwd_control() {
  local dir=$1; shift
  FM_HERDR_PS_BIN="$dir/fakebin/ps-herdr" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_control "$dir" rcwd relaunch --note 'resume preserved task' "$@"
}

cwd_assert_no_launch() {
  python3 - "$1/fake/herdr-log" <<'PY'
import json, sys
rows=[json.loads(x) for x in open(sys.argv[1])]
assert not any('encode launch-brief' in x for row in rows for x in row), rows
PY
  expect_code 0 $? "refused cwd repair must not deliver a launch"
}

cwd_assert_no_old_input() {
  [ ! -e "$1/fake/old-input" ] || fail "cwd repair sent input/reset to the old shell"
}

cwd_assert_preserved() {
  local dir=$1
  cmp -s "$dir/meta-before" "$dir/home/state/rcwd.meta" || fail "refusal changed task metadata"
  cmp -s "$dir/brief-before" "$dir/home/data/rcwd/brief.md" || fail "pre-publication refusal changed instructions"
  cwd_assert_no_launch "$dir"
  cwd_assert_no_old_input "$dir"
}

cwd_assert_preflight_evidence() {
  local dir=$1 expected=$2 refusal
  [ "$(journal_field "$dir" rcwd phase)" = failed:preflight ] || fail "preflight refusal phase was not journaled"
  [ "$(journal_field "$dir" rcwd repair_state)" = refused ] || fail "preflight refusal state was not journaled"
  [ "$(journal_field "$dir" rcwd repair_old_pane)" = w1:p1 ] || fail "refused old pane was not journaled"
  refusal=$(journal_field "$dir" rcwd repair_refusal_json | jq -er '.') || fail "preflight refusal evidence was not valid JSON"
  [ "$refusal" = "$expected" ] || fail "preflight refusal recorded '$refusal', expected '$expected'"
  [ "$(journal_field "$dir" rcwd rollback)" = prior-binding-kept ] || fail "preflight preservation outcome was not journaled"
}

cwd_projection() {
  local dir=$1
  # Real projection writer API, not a second hand-written record format.
  # shellcheck disable=SC2016 # Expansion belongs to the child shell.
  env FM_HOME="$dir/home" bash -c '
    . "$1/bin/fm-backend.sh"; fm_backend_source herdr
    token=$(fm_backend_herdr_projection_journal_create "$2/home/state" rcwd) || exit
    label=$(fm_backend_herdr_projection_workspace_label rcwd "$token")
    fm_backend_herdr_projection_journal_bind "$2/home/state/rcwd.herdr-presentation" rcwd \
      "$(cd "$2/home" && pwd -P)" fm-lab-control w1 w1:t1 w1:p1 w0 firstmate "$label" fm-rcwd
    printf "%s" "$label" > "$2/fake/label"
  ' _ "$ROOT" "$dir" || fail "could not seed projection through its owner"
  python3 - "$dir/fake" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); s=json.loads((p/'herdr-state').read_text()); s['label']=(p/'label').read_text()
(p/'herdr-state').write_text(json.dumps(s))
PY
}

test_cwd_repair_success_and_preservation() {
  local dir out rc head
  dir=$(new_case cwd-success rcwd); cwd_case "$dir"
  printf 'untracked progress\n' > "$dir/wt/scratch"
  printf 'unlanded commit\n' > "$dir/wt/progress"
  git -C "$dir/wt" add progress
  git -C "$dir/wt" commit -qm 'unlanded task progress'
  head=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'validation_owner=preserve-me\n' >> "$dir/home/state/rcwd.meta"
  cwd_projection "$dir"
  out=$(cwd_control "$dir" --repair-cwd); rc=$?
  expect_code 0 "$rc" "explicit Herdr repair should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rcwd window)" = fm-lab-control:w1:p2 ] || fail "new endpoint was not adopted"
  [ "$(meta_field "$dir" rcwd worktree)" = "$dir/wt" ] || fail "worktree identity changed"
  [ "$(meta_field "$dir" rcwd validation_owner)" = preserve-me ] || fail "validation ownership changed"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "unlanded commit changed"
  assert_grep 'untracked progress' "$dir/wt/scratch" "untracked work was not preserved"
  assert_grep 'pane_id=w1:p2' "$dir/home/state/rcwd.herdr-presentation" "projection was not rebound"
  [ "$(journal_field "$dir" rcwd repair_source)" = "$dir/proj" ] || fail "source path not journaled"
  [ "$(journal_field "$dir" rcwd repair_target)" = "$(cd "$dir/wt" && pwd -P)" ] || fail "target path not journaled"
  [ "$(journal_field "$dir" rcwd repair_state)" = complete ] || fail "repair completion not journaled"
  [ "$(journal_field "$dir" rcwd worktree_head)" = "$head" ] || fail "checkpoint head not preserved"
  cwd_assert_no_old_input "$dir"
  python3 - "$dir/fake" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); s=json.loads((p/'herdr-state').read_text())
assert list(s['panes']) == ['w1:p2']
rows=[json.loads(x) for x in (p/'herdr-log').read_text().splitlines()]
launch=next(i for i,row in enumerate(rows) if any('encode launch-brief' in x for x in row))
close=next(i for i,row in enumerate(rows) if row[:3] == ['pane','close','w1:p1'])
assert close > launch
assert s.get('focus','w0:t1') == 'w0:t1'
PY
  expect_code 0 $? "old pane must retire after launch, preserving focus"
  pass "cwd repair: API-created sibling, ordinary guarded launch, projection and all work preserved"
}

test_cwd_repair_refusals() {
  local mode dir out rc refusal
  for mode in live ambiguous foreground shell-script wrong-old-binding new-process; do
    dir=$(new_case "cwd-$mode" rcwd); cwd_case "$dir" "$mode"
    out=$(cwd_control "$dir" --repair-cwd); rc=$?
    [ "$rc" -ne 0 ] || fail "unsafe $mode must refuse: $out"
    cwd_assert_preserved "$dir"
    case "$mode" in
      wrong-old-binding) refusal='old pane identity or foreground path is ambiguous' ;;
      *) refusal='old endpoint is not a positively agent-free lone idle shell' ;;
    esac
    cwd_assert_preflight_evidence "$dir" "$refusal"
    [ "$(journal_field "$dir" rcwd repair_target)" = "$(cd "$dir/wt" && pwd -P)" ] || fail "$mode target was not journaled"
    [ "$(journal_field "$dir" rcwd repair_source)" = "$dir/proj" ] || [ "$mode" = wrong-old-binding ] \
      || fail "$mode observed source was not journaled"
    if grep -q '"split"' "$dir/fake/herdr-log"; then fail "$mode allocated a pane"; fi
  done
  for mode in missing nonroot primary family active extra-pane; do
    dir=$(new_case "cwd-$mode" rcwd); cwd_case "$dir"
    case "$mode" in
      missing) rm -rf "$dir/wt" ;;
      nonroot) mkdir "$dir/wt/sub"; perl -pi -e 's@/wt$@/wt/sub@' "$dir/home/state/rcwd.meta" ;;
      primary) perl -pi -e 's@/wt$@/proj@' "$dir/home/state/rcwd.meta" ;;
      family) git init -q "$dir/foreign"; python3 - "$dir/home/state/rcwd.meta" "$dir/foreign" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text('\n'.join('project='+sys.argv[2] if x.startswith('project=') else x for x in p.read_text().splitlines())+'\n')
PY
        ;;
      active|extra-pane) python3 - "$dir/fake/herdr-state" "$mode" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p))
if sys.argv[2]=='active': s['focus']='w1:t1'
else: s['panes']['w1:p3']={'cwd':s['primary']}
open(p,'w').write(json.dumps(s))
PY
        ;;
    esac
    cp "$dir/home/state/rcwd.meta" "$dir/meta-before"
    out=$(cwd_control "$dir" --repair-cwd); rc=$?
    [ "$rc" -ne 0 ] || fail "$mode must refuse: $out"
    cmp -s "$dir/meta-before" "$dir/home/state/rcwd.meta" || fail "$mode mutated metadata"
    cwd_assert_no_old_input "$dir"
    case "$mode" in
      primary) cwd_assert_preflight_evidence "$dir" 'recorded worktree is the primary project copy' ;;
      family) cwd_assert_preflight_evidence "$dir" 'recorded worktree belongs to a conflicting project family' ;;
      active) cwd_assert_preflight_evidence "$dir" 'task tab is active; focus another tab before repair' ;;
      extra-pane) cwd_assert_preflight_evidence "$dir" 'task tab has ambiguous or additional panes' ;;
    esac
    case "$mode" in
      active|extra-pane)
        [ "$(journal_field "$dir" rcwd repair_source)" = "$dir/proj" ] || fail "$mode observed source was not journaled"
        [ "$(journal_field "$dir" rcwd repair_target)" = "$(cd "$dir/wt" && pwd -P)" ] || fail "$mode target was not journaled"
        ;;
    esac
  done
  pass "cwd repair: live, ambiguous, foreign, primary, missing, non-root, active and conflicting endpoints refuse"
}

test_cwd_repair_retries_resolved_preflight_refusal() {
  local dir out rc
  dir=$(new_case cwd-refusal-retry rcwd); cwd_case "$dir"
  python3 - "$dir/fake/herdr-state" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); s['focus']='w1:t1'
open(p,'w').write(json.dumps(s))
PY
  out=$(cwd_control "$dir" --repair-cwd); rc=$?
  [ "$rc" -ne 0 ] || fail "active tab must refuse before retry: $out"
  cwd_assert_preserved "$dir"
  cwd_assert_preflight_evidence "$dir" 'task tab is active; focus another tab before repair'
  python3 - "$dir/fake/herdr-state" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); s['focus']='w0:t1'
open(p,'w').write(json.dumps(s))
PY
  out=$(cwd_control "$dir" --repair-cwd); rc=$?
  expect_code 0 "$rc" "resolved preflight refusal should be retryable"$'\n'"$out"
  [ "$(meta_field "$dir" rcwd window)" = fm-lab-control:w1:p2 ] || fail "retry did not adopt the replacement pane"
  [ "$(journal_field "$dir" rcwd repair_state)" = complete ] || fail "retry did not complete its repair journal"
  pass "cwd repair: resolved preflight refusal can be retried safely"
}

test_cwd_repair_rollback_and_guard() {
  local mode dir out rc
  for mode in wrong-cwd nonconsecutive read-fail wrong-new-binding bad-split split-fail new-live new-process old-agent-race rollback-close-fail; do
    dir=$(new_case "cwd-$mode" rcwd); cwd_case "$dir" "$mode"
    out=$(cwd_control "$dir" --repair-cwd); rc=$?
    [ "$rc" -ne 0 ] || fail "$mode must refuse: $out"
    cwd_assert_preserved "$dir"
    if [ "$mode" = wrong-cwd ] || [ "$mode" = nonconsecutive ]; then
      assert_contains "$out" 'two consecutive' "$mode must fail directory verification"
      [ "$(journal_field "$dir" rcwd rollback)" = unadopted-pane-removed ] || fail "unadopted pane not rolled back"
    fi
  done
  for mode in guard-race launch-fail cleanup-fail focus-steal; do
    dir=$(new_case "cwd-$mode" rcwd); cwd_case "$dir" "$mode"
    out=$(cwd_control "$dir" --repair-cwd); rc=$?
    if [ "$mode" = focus-steal ]; then
      expect_code 0 "$rc" "split focus should be restored"$'\n'"$out"
    else
      [ "$rc" -ne 0 ] || fail "$mode must report failure: $out"
      [ "$(meta_field "$dir" rcwd window)" = fm-lab-control:w1:p2 ] || fail "$mode reverted an adopted binding"
      [ "$(journal_field "$dir" rcwd rollback)" = new-binding-kept ] || fail "$mode did not record partial outcome"
      if [ "$mode" = guard-race ]; then
        assert_contains "$out" 'not its recorded worktree' "independent launch guard must still refuse a path race"
        cwd_assert_no_launch "$dir"
      fi
    fi
    cwd_assert_no_old_input "$dir"
  done
  pass "cwd repair: verification, publication, launch and cleanup failures preserve accurate partial outcomes"
}

test_cwd_repair_opt_in_and_path_bytes() {
  local dir out rc backend
  dir=$(new_case cwd-no-opt-in rcwd); cwd_case "$dir"
  out=$(cwd_control "$dir"); rc=$?
  [ "$rc" -ne 0 ] || fail "ordinary relaunch must still refuse wrong cwd"
  assert_contains "$out" 'not its recorded worktree' "absent option must retain original launch guard"
  if grep -q '"split"' "$dir/fake/herdr-log"; then fail "absent option allocated sibling"; fi
  for backend in tmux zellij orca cmux; do
    dir=$(new_case "cwd-$backend" rcwd); add_ship_task "$dir" rcwd
    python3 - "$dir/home/state/rcwd.meta" "$backend" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); b=sys.argv[2]; text=p.read_text()
extra={
 'tmux': '',
 'zellij': 'zellij_session=fs\nzellij_tab_id=1\nzellij_pane_id=2\n',
 'orca': 'terminal=term1\norca_worktree_id=wt1\n',
 'cmux': 'cmux_workspace_id=ws1\ncmux_surface_id=surface1\n'
}[b]
windows={'tmux':'fmses:fm-rcwd','zellij':'fs:2','orca':'fm-rcwd','cmux':'ws1:surface1'}
text=text.replace('window=fmses:fm-rcwd','window='+windows[b])
p.write_text(text+'backend='+b+'\n'+extra)
PY
    cp "$dir/home/state/rcwd.meta" "$dir/meta-before"
    out=$(run_control "$dir" rcwd relaunch --repair-cwd --note resume); rc=$?
    [ "$rc" -ne 0 ] || fail "$backend must refuse cwd repair"
    assert_contains "$out" 'Herdr only' "unsupported backend should be explicit"
    cmp -s "$dir/meta-before" "$dir/home/state/rcwd.meta" || fail "$backend refusal changed metadata"
  done
  dir=$(new_case cwd-quoted rcwd)
  # Shell-sensitive bytes remain one literal --cwd argument, never shell text.
  dir="$dir/space ' \" \$(touch INJECTED); end"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  make_tmux_stub "$dir"
  cwd_case "$dir"
  out=$(cwd_control "$dir" --repair-cwd); rc=$?
  expect_code 0 "$rc" "spaces and shell metacharacters must remain literal"$'\n'"$out"
  [ ! -e INJECTED ] || fail "recorded path executed shell input"
  cwd_assert_no_old_input "$dir"
  pass "cwd repair: explicit opt-in, Herdr-only boundary and literal path arguments"
}

test_cwd_repair_publication_and_concurrency() {
  local dir out rc mode control_pid writer_pid i expected
  for mode in metadata post-rename presentation-old presentation-new presentation-unconfirmed; do
    dir=$(new_case "cwd-publish-$mode" rcwd); cwd_case "$dir"
    case "$mode" in presentation-*) cwd_projection "$dir" ;; esac
    make_mv_failure_stub "$dir"
    if [ "$mode" = metadata ]; then
      out=$(FM_REAL_MV="$(command -v mv)" FM_FAKE_META_PUBLISH_MV_FAIL="$dir/home/state/rcwd.meta" cwd_control "$dir" --repair-cwd); rc=$?
      [ "$rc" -ne 0 ] || fail "metadata publish must refuse"
      cwd_assert_preserved "$dir"
      [ "$(journal_field "$dir" rcwd rollback)" = unadopted-pane-removed ] || fail "publication failure did not remove unadopted pane"
    elif [ "$mode" = post-rename ]; then
      cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
"$FM_REAL_MV" "$@" || exit $?
for path in "$@"; do
  case "$path" in */rcwd.meta) exit 1 ;; esac
done
SH
      chmod +x "$dir/fakebin/mv"
      out=$(FM_REAL_MV="$(command -v mv)" cwd_control "$dir" --repair-cwd); rc=$?
      [ "$rc" -ne 0 ] || fail "post-rename publication failure must report failure"
      [ "$(meta_field "$dir" rcwd window)" = fm-lab-control:w1:p2 ] || fail "post-rename failure lost published binding"
      [ "$(journal_field "$dir" rcwd repair_published)" = 1 ] || fail "journal failed to observe actual publication"
      [ "$(journal_field "$dir" rcwd rollback)" = new-binding-kept ] || fail "adopted pane was rolled back after rename"
      cwd_assert_no_launch "$dir"
      if grep -q '"close"' "$dir/fake/herdr-log"; then fail "post-rename failure closed a published endpoint"; fi
    else
      case "$mode" in
        presentation-old)
          expected=pending
          out=$(FM_REAL_MV="$(command -v mv)" FM_FAKE_META_PUBLISH_MV_FAIL="$dir/home/state/rcwd.herdr-presentation" cwd_control "$dir" --repair-cwd); rc=$?
          ;;
        presentation-new)
          expected=rebound
          cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
"$FM_REAL_MV" "$@" || exit $?
for path in "$@"; do
  case "$path" in */rcwd.herdr-presentation) exit 1 ;; esac
done
SH
          chmod +x "$dir/fakebin/mv"
          out=$(FM_REAL_MV="$(command -v mv)" cwd_control "$dir" --repair-cwd); rc=$?
          ;;
        presentation-unconfirmed)
          expected=unconfirmed
          cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
"$FM_REAL_MV" "$@" || exit $?
for path in "$@"; do
  case "$path" in
    */rcwd.herdr-presentation) printf 'indeterminate\n' > "$path"; exit 1 ;;
  esac
done
SH
          chmod +x "$dir/fakebin/mv"
          out=$(FM_REAL_MV="$(command -v mv)" cwd_control "$dir" --repair-cwd); rc=$?
          ;;
      esac
      [ "$rc" -ne 0 ] || fail "$mode presentation publish must refuse"
      [ "$(meta_field "$dir" rcwd window)" = fm-lab-control:w1:p2 ] || fail "$mode reverted accurate new binding"
      [ "$(journal_field "$dir" rcwd repair_projection)" = "$expected" ] || fail "$mode lost exact durable presentation evidence"
      cwd_assert_no_launch "$dir"
      out=$(cwd_control "$dir" --repair-cwd); rc=$?
      [ "$rc" -ne 0 ] || fail "unresolved $mode repair must refuse another allocation"
      assert_contains "$out" 'earlier repair remains' "$mode retry must retain partial transaction evidence"
    fi
  done
  dir=$(new_case cwd-concurrent rcwd); cwd_case "$dir" split-wait
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  cwd_control "$dir" --repair-cwd > "$dir/control.out" 2>&1 &
  control_pid=$!
  i=0
  while [ ! -e "$dir/fake/split-ready" ] && [ "$i" -lt 1000 ]; do /bin/sleep 0.02; i=$((i + 1)); done
  if [ ! -e "$dir/fake/split-ready" ]; then
    kill "$control_pid" 2>/dev/null || true; wait "$control_pid" 2>/dev/null || true
    fail "repair did not reach split with metadata lock held: $(cat "$dir/control.out")"
  fi
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_LOCK_WAITING="$dir/writer-waiting" "$X_LINK" rcwd request-cwd > "$dir/writer.out" 2>&1 &
  writer_pid=$!
  i=0
  while [ ! -e "$dir/writer-waiting" ] && [ "$i" -lt 1000 ]; do /bin/sleep 0.02; i=$((i + 1)); done
  : > "$dir/fake/split-release"
  wait "$writer_pid"; rc=$?
  expect_code 0 "$rc" "concurrent metadata writer must complete: $(cat "$dir/writer.out")"
  wait "$control_pid"; rc=$?
  expect_code 0 "$rc" "repair must complete: $(cat "$dir/control.out")"
  [ -e "$dir/writer-waiting" ] || fail "concurrent writer never waited for the repair lock"
  [ "$(meta_field "$dir" rcwd x_request)" = request-cwd ] || fail "repair lost concurrent metadata"
  [ "$(meta_field "$dir" rcwd window)" = fm-lab-control:w1:p2 ] || fail "concurrent writer lost rebound endpoint"
  pass "cwd repair: atomic publication failures and a concurrent metadata writer preserve truthful ownership"
}

test_cwd_repair_success_and_preservation
test_cwd_repair_publication_and_concurrency
test_cwd_repair_refusals
test_cwd_repair_retries_resolved_preflight_refusal
test_cwd_repair_rollback_and_guard
test_cwd_repair_opt_in_and_path_bytes
