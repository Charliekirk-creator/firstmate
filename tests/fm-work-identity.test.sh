#!/usr/bin/env bash
# Public-interface coverage for exact project/plan/work-unit intake and fleet projection.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK_IDENTITY="$ROOT/bin/fm-work-identity.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
FLEET_VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-work-identity)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

make_max_manifest() {  # <home> <task> <path>
  local home=$1 task=$2 path=$3
  FM_HOME="$home" "$WORK_IDENTITY" template "$task" \
    | jq '
      def padded($prefix): $prefix + ("x" * (240 - ($prefix | length)));
      def display: "🚢" * 160;
      .initiative = {namespace:"work-aligner",kind:"project",id:padded("initiative-"),label:display}
      | .plan_id = {namespace:"work-aligner",kind:"plan",id:padded("plan-"),label:display}
      | .stage = {namespace:"work-aligner",kind:"stage",id:padded("stage-"),label:display}
      | .work_units = [range(0;20) as $n
          | {namespace:"work-aligner",kind:"work-unit",id:padded("unit-\($n)-"),label:display}]
      | .sources = [range(0;20) as $n
          | {namespace:"dtm",kind:"issue",id:padded("source-\($n)-"),label:display}]
    ' > "$path"
}

make_manifest() {  # <home> <task> <path> [multi]
  local home=$1 task=$2 path=$3 multi=${4:-single}
  FM_HOME="$home" "$WORK_IDENTITY" template "$task" \
    | jq --argjson multi "$([ "$multi" = multi ] && printf true || printf false)" '
      .initiative = {namespace:"work-aligner",kind:"project",id:"wa-project-42",label:"Roadmap Accuracy"}
      | .plan_id = {namespace:"work-aligner",kind:"plan",id:"wa-plan-2026-q3",label:"Identity Plan"}
      | .stage = {namespace:"work-aligner",kind:"stage",id:"implementation",label:"Implementation"}
      | .work_units = (
          if $multi then [
            {namespace:"work-aligner",kind:"work-unit",id:"wu-exact-intake",label:"Exact Intake"},
            {namespace:"work-aligner",kind:"work-unit",id:"wu-fleet-projection",label:"Fleet Projection"}
          ] else [
            {namespace:"work-aligner",kind:"work-unit",id:"wu-exact-intake",label:"Exact Intake"}
          ] end)
      | .sources = [
          {namespace:"dtm",kind:"project",id:"dtm-project-17",label:"Delivery Tracking"},
          {namespace:"dtm",kind:"issue",id:"DTM-431",label:"Worker Relation Gap"},
          {namespace:"data-team-ticket",kind:"ticket",id:"DTT-88",label:"Dashboard Tracking"}
        ]' > "$path"
}

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_WORKTREE:-${FM_HOME:?}}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-codex}"; exit 0 ;;
esac
case "${1:-}" in
  list-windows) exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane) printf 'worker ready\n> \n'; exit 0 ;;
  new-window)
    if [ -n "${FM_TEST_MUTATE_BRIEF:-}" ]; then
      printf 'MUTATED_SOURCE_BRIEF\n' > "$FM_TEST_MUTATE_BRIEF"
    fi
    exit 0
    ;;
  send-keys)
    literal=0
    for arg in "$@"; do [ "$arg" != -l ] || literal=1; done
    if [ "$literal" -eq 1 ] && [ -n "${FM_TEST_MUTATE_LAUNCH_BRIEF:-}" ]; then
      printf 'MUTATED_LAUNCH_BRIEF\n' > "$FM_TEST_MUTATE_LAUNCH_BRIEF.replacement"
      mv -f "$FM_TEST_MUTATE_LAUNCH_BRIEF.replacement" "$FM_TEST_MUTATE_LAUNCH_BRIEF"
    fi
    if [ "$literal" -eq 1 ] && [ -n "${FM_TEST_LAUNCH_COMMAND:-}" ]; then
      printf '%s\n' "${!#}" > "$FM_TEST_LAUNCH_COMMAND"
    fi
    exit 0
    ;;
  has-session|new-session|kill-window) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_DELIVERED_BRIEF:-}" ] || printf '%s' "${!#}" > "$FM_TEST_DELIVERED_BRIEF"
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/codex" "$fakebin/treehouse" "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

record_and_brief() {  # <home> <task> <manifest> [mode]
  local home=$1 task=$2 manifest=$3 mode=${4:-no-mistakes}
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode "$mode" >/dev/null
}

write_bound_meta() {  # <home> <task> <worktree> [window]
  local home=$1 task=$2 worktree=$3 window=${4:-firstmate:fm-$2} projection hash
  projection=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task") || fail "could not verify linked fixture $task"
  hash=$(printf '%s' "$projection" | jq -r '.sha256')
  fm_write_meta "$home/state/$task.meta" \
    "window=$window" \
    "endpoint_task_id=$task" \
    "worktree=$worktree" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" \
    "work_identity_status=linked" \
    "work_identity_sha256=$hash"
}

# Record, generated instructions, spawn metadata, canonical fleet snapshot, and
# Bearings all carry one exact multi-work-unit relation without multiplying the worker.
test_intake_through_fleet_projection() {
  local home task manifest project wt fakebin out first second projection before_state after_state
  home=$(make_home end-to-end)
  task=exact-worker
  manifest="$home/manifest.json"
  project="$home/project"
  wt="$home/worker-copy"
  make_manifest "$home" "$task" "$manifest" multi
  before_state=$(find "$home/state" -mindepth 1 -print | sort)
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest") \
    || fail "valid multi-work-unit intake was refused: $out"
  after_state=$(find "$home/state" -mindepth 1 -print | sort)
  [ "$before_state" = "$after_state" ] || fail "recording identity changed runtime task state"
  first=$(sha256_file_for_test "$home/data/$task/work-identity.json")
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest") \
    || fail "idempotent record was refused: $out"
  second=$(sha256_file_for_test "$home/data/$task/work-identity.json")
  [ "$first" = "$second" ] || fail "idempotent record changed canonical bytes"
  assert_contains "$out" "(unchanged)" "idempotent intake did not report convergence"

  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null \
    || fail "linked brief did not scaffold"
  assert_grep "Work identity contract: fm-work-identity.v1 sha256=$first" "$home/data/$task/brief.md" \
    "generated instructions did not bind the canonical digest"
  assert_grep '"id":"wu-exact-intake"' "$home/data/$task/brief.md" \
    "generated instructions lost the first exact work unit"
  assert_grep '"id":"wu-fleet-projection"' "$home/data/$task/brief.md" \
    "generated instructions lost the second exact work unit"

  fm_git_worktree "$project" "$wt" exact-worker-copy
  fakebin=$(make_fakebin "$home/fakes")
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" PATH="$fakebin:$PATH" \
    "$SPAWN" "$task" "$project" --mode no-mistakes --yolo off 2>&1)
  assert_contains "$out" "spawned $task" "linked task did not spawn"
  assert_grep 'work_identity_schema=fm-work-identity.v1' "$home/state/$task.meta" \
    "spawn metadata lost the identity schema"
  assert_grep 'work_identity_status=linked' "$home/state/$task.meta" \
    "spawn metadata lost linked status"
  assert_grep "work_identity_sha256=$first" "$home/state/$task.meta" \
    "spawn metadata lost the exact sidecar digest"

  projection=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z \
    "$SNAPSHOT" --json)
  printf '%s' "$projection" | jq -e '
    ([.tasks[] | select(.id == "exact-worker")] | length) == 1
      and (.tasks[] | select(.id == "exact-worker")
        | .work_identity.status == "linked"
          and .work_identity.initiative == {namespace:"work-aligner",kind:"project",id:"wa-project-42",label:"Roadmap Accuracy"}
          and .work_identity.plan_id.id == "wa-plan-2026-q3"
          and .work_identity.stage.id == "implementation"
          and (.work_identity.work_units | map(.id)) == ["wu-exact-intake","wu-fleet-projection"]
          and (.work_identity.sources | map([.namespace,.kind,.id])) == [
            ["dtm","project","dtm-project-17"],
            ["dtm","issue","DTM-431"],
            ["data-team-ticket","ticket","DTT-88"]])
  ' >/dev/null || fail "canonical snapshot changed or multiplied exact task identity: $projection"
  first=$(printf '%s' "$projection" | jq -S -c .)
  second=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z \
    "$SNAPSHOT" --json | jq -S -c .)
  [ "$first" = "$second" ] || fail "same exact state produced unstable canonical snapshot output"

  projection=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-08-14T12:00:00Z \
    "$BEARINGS" --json)
  printf '%s' "$projection" | jq -e '
    ([.in_flight[] | select(.id == "exact-worker")] | length) == 1
      and (.in_flight[] | select(.id == "exact-worker")
        | .work_identity == "linked"
          and (.initiative | contains("work-aligner:project:wa-project-42 [Roadmap Accuracy]"))
          and (.plan | contains("work-aligner:plan:wa-plan-2026-q3 [Identity Plan]"))
          and (.stage | contains("work-aligner:stage:implementation [Implementation]"))
          and (.work_units | contains("work-aligner:work-unit:wu-exact-intake [Exact Intake]"))
          and (.work_units | contains("work-aligner:work-unit:wu-fleet-projection [Fleet Projection]"))
          and (.sources | contains("dtm:issue:DTM-431 [Worker Relation Gap]")))
  ' >/dev/null || fail "Bearings lost exact ids paired with display labels: $projection"
  pass "exact multi-work-unit intake survives instructions, metadata, snapshot, and Bearings once per worker"
}

test_spawn_delivers_validated_brief_snapshot() {
  local home task manifest project wt fakebin out delivered snapshot delivered_body delivered_hash
  home=$(make_home immutable-delivery)
  task=immutable-delivery-worker
  manifest="$home/manifest.json"
  project="$home/project"
  wt="$home/worker-copy"
  delivered="$home/delivered.txt"
  make_manifest "$home" "$task" "$manifest" multi
  record_and_brief "$home" "$task" "$manifest"
  fm_git_worktree "$project" "$wt" immutable-delivery-copy
  fakebin=$(make_fakebin "$home/fakes")
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_WORKTREE="$wt" FM_TEST_MUTATE_BRIEF="$home/data/$task/brief.md" \
    FM_TEST_MUTATE_LAUNCH_BRIEF="$home/state/$task.launch-brief.md" \
    FM_TEST_LAUNCH_COMMAND="$home/launch.command" FM_TEST_DELIVERED_BRIEF="$delivered" \
    PATH="$fakebin:$PATH" "$SPAWN" "$task" "$project" \
    --mode no-mistakes --yolo off --harness codex 2>&1)
  assert_contains "$out" "spawned $task" "spawn with a concurrently replaced source brief failed"
  assert_present "$home/launch.command" "spawn emitted no worker launch command"
  (cd "$wt" && FM_TEST_DELIVERED_BRIEF="$delivered" PATH="$fakebin:$PATH" \
    /bin/bash -c "$(cat "$home/launch.command")") \
    || fail "emitted worker launch command could not consume its brief snapshot"
  assert_grep 'MUTATED_SOURCE_BRIEF' "$home/data/$task/brief.md" \
    "delivery fixture did not replace the source brief after validation"
  assert_present "$delivered" "fake worker received no launch instructions"
  assert_grep 'Work identity contract: fm-work-identity.v1 sha256=' "$delivered" \
    "worker did not receive the identity contract from the validated snapshot"
  assert_grep '"id":"wu-fleet-projection"' "$delivered" \
    "worker received changed instructions instead of the validated identity payload"
  assert_no_grep 'MUTATED_SOURCE_BRIEF' "$delivered" \
    "worker reread the replaced source brief after validation"
  snapshot="$home/state/$task.launch-brief.md"
  assert_grep "launch_brief=$snapshot" "$home/state/$task.meta" \
    "task metadata did not bind the launch snapshot"
  assert_grep 'MUTATED_LAUNCH_BRIEF' "$snapshot" \
    "delivery fixture did not replace the validated launch snapshot"
  delivered_body="$home/delivered-body.md"
  "$ROOT/bin/fm-operational-input.sh" body < "$delivered" > "$delivered_body" \
    || fail "worker delivery was not a typed launch-brief input"
  delivered_hash=$(sha256_file_for_test "$delivered_body")
  assert_grep "launch_brief_sha256=$delivered_hash" "$home/state/$task.meta" \
    "task metadata did not bind the exact delivered instruction bytes"
  pass "spawn delivers validated bytes despite source and snapshot replacement"
}

sha256_file_for_test() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

test_sidecar_validation_hashes_captured_bytes() {
  local home task manifest sidecar replacement fakebin real_shasum projection observed observed_hash
  home=$(make_home captured-sidecar)
  task=captured-sidecar-worker
  manifest="$home/manifest.json"
  sidecar="$home/data/$task/work-identity.json"
  replacement="$home/replacement.json"
  make_manifest "$home" "$task" "$manifest"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  jq -S -c '.work_units[0].id = "wu-other-intake"' "$sidecar" > "$replacement"
  [ "$(LC_ALL=C wc -c < "$sidecar" | tr -d ' ')" = \
    "$(LC_ALL=C wc -c < "$replacement" | tr -d ' ')" ] \
    || fail "same-size sidecar rewrite fixture changed record size"
  fakebin=$(fm_fakebin "$home/hash-fake")
  real_shasum=$(command -v shasum || true)
  cat > "$fakebin/shasum" <<'SH'
#!/usr/bin/env bash
set -eu
last=${!#}
if [ "$last" = "$FM_TEST_SIDECAR" ]; then
  /bin/cp "$FM_TEST_REPLACEMENT" "$FM_TEST_SIDECAR"
fi
if [ -n "$FM_TEST_REAL_SHASUM" ]; then
  exec "$FM_TEST_REAL_SHASUM" "$@"
fi
exec sha256sum "$last"
SH
  chmod +x "$fakebin/shasum"
  projection=$(PATH="$fakebin:$PATH" FM_TEST_SIDECAR="$sidecar" \
    FM_TEST_REPLACEMENT="$replacement" FM_TEST_REAL_SHASUM="$real_shasum" \
    FM_HOME="$home" "$WORK_IDENTITY" verify "$task") \
    || fail "captured sidecar validation failed"
  observed="$home/observed.json"
  printf '%s' "$projection" | jq -S -c \
    '{schema,binding,initiative,plan_id,stage,work_units,sources}' > "$observed"
  observed_hash=$(sha256_file_for_test "$observed")
  [ "$(printf '%s' "$projection" | jq -r '.sha256')" = "$observed_hash" ] \
    || fail "sidecar projection combined canonical bytes with another version digest"
  pass "sidecar validation hashes one captured byte sequence"
}

test_concurrent_idempotence_and_explicit_unlinked() {
  local home task manifest p1 p2 rc1 rc2 links out
  home=$(make_home idempotent)
  task=concurrent-worker
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" > "$home/record-1.out" 2>&1 &
  p1=$!
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" > "$home/record-2.out" 2>&1 &
  p2=$!
  wait "$p1"; rc1=$?
  wait "$p2"; rc2=$?
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] \
    || fail "concurrent byte-identical intake did not converge idempotently"
  if [ "$(uname)" = Darwin ]; then
    links=$(stat -f '%l' "$home/data/$task/work-identity.json")
  else
    links=$(stat -c '%h' "$home/data/$task/work-identity.json")
  fi
  [ "$links" = 1 ] || fail "concurrent intake left a hardlinked publication"
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" | jq -e '.status == "linked"' >/dev/null \
    || fail "concurrent intake did not leave one valid linked record"

  task=intentionally-unlinked
  FM_HOME="$home" "$BRIEF" "$task" firstmate --mode no-mistakes >/dev/null
  assert_grep 'Work identity contract: fm-work-identity.v1 unlinked' "$home/data/$task/brief.md" \
    "unlinked intake was not explicit in generated instructions"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task")
  printf '%s' "$out" | jq -e '
    .status == "unlinked" and .reason == "explicitly-unlinked"
      and .initiative == null and .plan_id == null and .work_units == [] and .sources == []
  ' >/dev/null || fail "intentional unlinked intake was not explicit: $out"
  pass "concurrent identical records converge and intentional unlinked intake stays explicit"
}

# Namespace is part of identity: identical opaque ids in separate systems stay
# distinct, while duplicate exact tuples and invalid namespace-role pairs refuse.
test_namespace_separation_and_contract_rejections() {
  local home task manifest out rc case_name
  home=$(make_home namespaces)
  task=namespace-worker
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"
  jq '.sources = [
        {namespace:"dtm",kind:"issue",id:"shared-7",label:"DTM Seven"},
        {namespace:"data-team-ticket",kind:"ticket",id:"shared-7",label:"Ticket Seven"}
      ]
      | .plan_id.id = "shared-7"
      | .work_units[0].id = "shared-7"' "$manifest" > "$home/separate.json"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/separate.json" >/dev/null \
    || fail "separate namespaces/kinds with the same opaque id were conflated"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task")
  printf '%s' "$out" | jq -e '
    .plan_id == {namespace:"work-aligner",kind:"plan",id:"shared-7",label:"Identity Plan"}
      and .work_units[0] == {namespace:"work-aligner",kind:"work-unit",id:"shared-7",label:"Exact Intake"}
      and (.sources | map([.namespace,.kind,.id])) == [
        ["dtm","issue","shared-7"],["data-team-ticket","ticket","shared-7"]]
  ' >/dev/null || fail "namespace-separated exact identities did not survive"

  task=local-plan-worker
  make_manifest "$home" "$task" "$manifest"
  jq '.initiative={namespace:"firstmate",kind:"initiative",id:"local-initiative",label:"Local Initiative"}
      | .plan_id={namespace:"firstmate",kind:"plan",id:"local-plan",label:"Local Plan"}
      | .stage={namespace:"firstmate",kind:"stage",id:"local-stage",label:"Local Stage"}
      | .work_units=[{namespace:"firstmate",kind:"work-unit",id:"local-unit",label:"Local Unit"}]
      | .sources=[{namespace:"dtm",kind:"issue",id:"DTM-LOCAL-1",label:"Local Source"}]' \
    "$manifest" > "$home/local.json"
  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/local.json" >/dev/null \
    || fail "local Firstmate plan identity was refused"
  FM_HOME="$home" "$WORK_IDENTITY" verify "$task" | jq -e '
    .initiative.namespace == "firstmate" and .plan_id.id == "local-plan"
      and .stage.id == "local-stage" and .work_units[0].id == "local-unit"
  ' >/dev/null || fail "local Firstmate plan identity did not survive"

  for case_name in version bad-role duplicate unsafe-id no-source contradictory; do
    task="reject-$case_name"
    make_manifest "$home" "$task" "$manifest" multi
    case "$case_name" in
      version) jq '.schema="fm-work-identity.v2"' "$manifest" > "$home/bad.json" ;;
      bad-role) jq '.plan_id.namespace="dtm"' "$manifest" > "$home/bad.json" ;;
      duplicate) jq '.work_units[1]=.work_units[0]' "$manifest" > "$home/bad.json" ;;
      unsafe-id) jq '.work_units[0].id="../fuzzy"' "$manifest" > "$home/bad.json" ;;
      no-source) jq '.sources=[]' "$manifest" > "$home/bad.json" ;;
      contradictory) jq '.sources[0]=.work_units[0]' "$manifest" > "$home/bad.json" ;;
    esac
    out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/bad.json" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "$case_name malformed contract was accepted"
    assert_absent "$home/data/$task/work-identity.json" "$case_name refusal partially published a sidecar"
  done
  pass "namespaces remain distinct and version, role, duplicate, contradiction, and id syntax are closed"
}

# Unsafe inputs and stored records refuse. Labels are display-only but still must
# be safe to embed in generated instructions.
test_unsafe_files_labels_and_exact_binding() {
  local home home_real other other_real task manifest out rc sidecar transfer projection projection_set
  home=$(make_home safety-a)
  home_real=$(cd "$home" && pwd -P)
  other=$(make_home safety-b)
  other_real=$(cd "$other" && pwd -P)
  task=safe-worker
  manifest="$home/manifest.json"
  make_manifest "$home" "$task" "$manifest"

  ln -s "$manifest" "$home/manifest-link.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/manifest-link.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked manifest was accepted"
  ln "$manifest" "$home/manifest-hard.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/manifest-hard.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "hardlinked manifest was accepted"
  rm "$home/manifest-hard.json"

  jq '.work_units[0].label=" Unsafe label"' "$manifest" > "$home/bad-label.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/bad-label.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "leading-space label was accepted"
  jq '.work_units[0].label="Unsafe ` label"' "$manifest" > "$home/bad-label.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/bad-label.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "instruction-breaking label was accepted"
  jq '.work_units[0].label="unsafe\u009b2Kcontrol"' "$manifest" > "$home/bad-label.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/bad-label.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "C1 terminal-control label was accepted"
  jq '.work_units[0].label="safe-id\u202Edi-efas"' "$manifest" > "$home/bad-label.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/bad-label.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "Unicode bidi-format label was accepted"
  assert_absent "$home/data/$task/work-identity.json" "unsafe label refusal partially published a record"

  FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  sidecar="$home/data/$task/work-identity.json"
  mkdir -p "$other/data/$task"
  cp "$sidecar" "$other/data/$task/work-identity.json"
  out=$(FM_HOME="$other" "$WORK_IDENTITY" verify "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "cross-home copied relation was accepted"
  printf 'other\n' > "$other/.fm-secondmate-home"
  jq -S -c --arg home "$other_real" '.binding.home=$home' "$sidecar" \
    > "$other/data/$task/work-identity.json"
  out=$(FM_HOME="$other" "$WORK_IDENTITY" verify "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "path-rebound record with another stable home identity was accepted"
  transfer=$(FM_HOME="$home" "$WORK_IDENTITY" handoff-prepare "$task" \
    --to-home "$home_real" --to-home-id secondmate:same-path)
  printf '%s' "$transfer" | jq -e '
    .source.home == .target.home and .source.home_id == "main"
      and .target.home_id == "secondmate:same-path"
  ' >/dev/null || fail "same-path remote handoff did not bind distinct stable home identities"
  printf '%s\n' "$transfer" | FM_HOME="$home" "$WORK_IDENTITY" \
    handoff-cancel "$task" --file - >/dev/null || fail "same-path handoff preparation did not cancel"
  projection=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task")
  projection_set=$(jq -n -c --arg task "$task" --argjson identity "$projection" \
    '[{task_id:$task,work_identity:$identity}]')
  out=$(printf '%s\n' "$projection_set" | FM_HOME="$home" "$WORK_IDENTITY" \
    validate-projections --home "$home_real" --home-id secondmate:same-path --file - 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "cross-home projection with the same absolute path was accepted"
  mkdir -p "$home/data/other-task"
  cp "$sidecar" "$home/data/other-task/work-identity.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify other-task 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "task-mismatched relation was accepted"

  ln "$sidecar" "$home/data/$task/work-identity-hard.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "hardlinked stored relation was accepted"
  rm "$home/data/$task/work-identity-hard.json"
  mv "$sidecar" "$home/data/$task/work-identity-real.json"
  ln -s work-identity-real.json "$sidecar"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked stored relation was accepted"
  pass "unsafe manifests, labels, stored files, cross-home copies, and task mismatches refuse"
}

# Linked records are frozen by both generated instructions and metadata. Manual
# post-dispatch edits become stale and cannot publish through any read surface.
test_stale_and_changed_relations_refuse() {
  local home task manifest wt sidecar out rc canonical
  home=$(make_home stale)
  task=stale-worker
  manifest="$home/manifest.json"
  wt="$home/worktree"
  mkdir -p "$wt"
  make_manifest "$home" "$task" "$manifest"
  record_and_brief "$home" "$task" "$manifest"
  write_bound_meta "$home" "$task" "$wt"
  jq '.work_units[0].id="wu-manually-changed"' "$manifest" > "$home/changed.json"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" record "$task" --file "$home/changed.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "public intake changed a frozen relation"
  sidecar="$home/data/$task/work-identity.json"
  canonical=$(jq -S -c '.work_units[0].id="wu-manually-changed"' "$sidecar")
  printf '%s\n' "$canonical" > "$sidecar"
  out=$(FM_HOME="$home" "$WORK_IDENTITY" verify "$task" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "stale sidecar digest was accepted against brief/meta bindings"
  out=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "authoritative snapshot partially published a stale linked relation"
  pass "generated instructions and metadata freeze the exact relation against stale edits"
}

# Legacy tasks are explicitly unlinked. Every tempting fuzzy signal remains
# ignored, including title, repository, branch/worktree, pane, worker, time, and
# status prose.
test_legacy_and_fuzzy_fallbacks_are_unlinked() {
  local home task long_task wt fakebin json bearings
  home=$(make_home fuzzy)
  task=wa-plan-2026-q3
  long_task=legacy-task-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-0123456789
  wt="$home/projects/dtm-project-17/wu-exact-intake"
  mkdir -p "$wt" "$home/data/$task"
  printf 'legacy brief names Work Aligner wu-fleet-projection\n' > "$home/data/$task/brief.md"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $task - Work Aligner wu-exact-intake (repo: wa-project-42) (kind: ship) (since 2026-08-14)

## Queued
- [ ] $long_task - path-safe overlong legacy task (repo: legacy)

## Done
EOF
  fm_write_meta "$home/state/$task.meta" \
    "window=firstmate:fm-wu-fleet-projection" \
    "worktree=$wt" \
    "project=wa-project-42" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf 'working: DTM-431 implements Work Aligner plan wa-plan-2026-q3\n' > "$home/state/$task.status"
  fakebin=$(make_fakebin "$home/fakes")
  FM_HOME="$home" "$WORK_IDENTITY" verify "$long_task" | jq -e '
    .status == "unlinked" and .reason == "legacy-no-record"
  ' >/dev/null || fail "path-safe overlong legacy task did not verify as unlinked"
  json=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$json" | jq -e --arg long "$long_task" '
    (.tasks[] | select(.id == "wa-plan-2026-q3")
      | .work_identity.status == "unlinked"
        and .work_identity.reason == "legacy-no-record"
        and .work_identity.initiative == null
        and .work_identity.work_units == []
        and .work_identity.sources == [])
      and (.backlog.records[] | select(.id == "wa-plan-2026-q3")
        | .work_identity.status == "unlinked")
      and (.backlog.records[] | select(.id == $long)
        | .work_identity.status == "unlinked" and .work_identity.reason == "legacy-no-record")
  ' >/dev/null || fail "a fuzzy title/repo/branch/pane/status relation leaked into snapshot: $json"
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-08-14T12:00:00Z "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e '
    .in_flight[] | select(.id == "wa-plan-2026-q3")
    | .work_identity == "unlinked" and .initiative == "-" and .plan == "-"
      and .stage == "-" and .work_units == "-" and .sources == "-"
  ' >/dev/null || fail "Bearings invented a fuzzy relation: $bearings"
  pass "legacy tasks stay explicitly unlinked despite every fuzzy fallback signal"
}

# A secondmate home projects its own linked child through the bounded structured
# summary. The parent consumes that projection and never scans or rebuilds the
# child tree itself; Bearings exposes one delegated child row with all exact ids.
test_delegated_secondmate_projection() {
  local parent mate task long_task manifest wt fakebin hash canonical bearings gen out rc
  parent=$(make_home delegated-parent)
  mate="$TMP_ROOT/delegated-mate"
  task=delegated-child
  long_task=legacy-delegated-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz
  wt="$mate/projects/$task"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin" "$wt"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'roadmap\n' > "$mate/.fm-secondmate-home"
  printf -- '- roadmap - roadmap domain (home: %s; scope: roadmap work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/roadmap.meta" "$mate" "firstmate:fm-roadmap" firstmate codex
  printf 'working [key=delegated]: delegated child active\n' > "$parent/state/roadmap.status"

  manifest="$mate/manifest.json"
  make_manifest "$mate" "$task" "$manifest" multi
  record_and_brief "$mate" "$task" "$manifest"
  hash=$(FM_HOME="$mate" "$WORK_IDENTITY" verify "$task" | jq -r '.sha256')
  fm_write_meta "$mate/state/$task.meta" \
    "window=firstmate:fm-$task" "endpoint_task_id=$task" "worktree=$wt" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=linked" "work_identity_sha256=$hash"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$mate/state" "$task")
  "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" "$task" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  printf 'working: exact delegated work\n' > "$mate/state/$task.status"
  cat > "$mate/data/backlog.md" <<EOF
## In flight
- [ ] $task - Exact delegated child (repo: firstmate) (kind: ship) (since 2026-08-14)

## Queued
- [ ] $long_task - Exact long legacy delegated id (repo: firstmate) (kind: ship)

## Done
EOF
  fakebin=$(make_fakebin "$parent/fakes")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$canonical" | jq -e --arg long "$long_task" '
    .secondmate_current.records[] | select(.id == "roadmap")
    | . as $mate
    | .provenance.selected == "structured-home"
      and ([.active_children[] | select(.id == "delegated-child" and .work_identity_ref == "delegated-child")] | length) == 1
      and ([.endpoints[] | select(.id == "delegated-child" and .work_identity_ref == "delegated-child")] | length) == 1
      and ([.work_identities[] | select(.task_id == "delegated-child")] | length) == 1
      and ([.queued[] | select(.id == $long and .work_identity_ref == $long)] | length) == 1
      and ([.work_identities[] | select(.task_id == $long)
        | .work_identity | select(.status == "unlinked" and .reason == "legacy-no-record")] | length) == 1
      and (.work_identities[] | select(.task_id == "delegated-child") | .work_identity
        | .status == "linked" and .binding.home_id == "secondmate:roadmap"
          and (.work_units | map(.id)) == ["wu-exact-intake","wu-fleet-projection"]
          and (.sources | any(.namespace == "dtm" and .kind == "issue" and .id == "DTM-431")))
      and (all(.active_children[]; has("work_identity") | not))
      and (all(.endpoints[]; has("work_identity") | not))
  ' >/dev/null || fail "authoritative delegated-child projection lost exact identity: $canonical"
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_BEARINGS_NOW=2026-08-14T12:00:00Z "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e --arg long "$long_task" '
    ([.delegated_work[] | select(.owner == "roadmap" and .id == "delegated-child")] | length) == 1
      and (.delegated_work[] | select(.owner == "roadmap" and .id == "delegated-child")
        | .work_identity == "linked"
          and (.work_units | contains("wu-exact-intake"))
          and (.work_units | contains("wu-fleet-projection"))
          and (.sources | contains("dtm:issue:DTM-431")))
      and ([.gates[] | select(.owner == "roadmap" and .id == $long
        and .work_identity == "unlinked")] | length) == 1
  ' >/dev/null || fail "Bearings delegated-work projection lost exact identities: $bearings"
  rm "$mate/.fm-secondmate-home"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z \
    "$SNAPSHOT" --json 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "parent published after a readable delegated home lost its identity marker"
  assert_contains "$out" "work identity home binding mismatch in secondmate roadmap" \
    "missing delegated home identity marker degraded to an untrusted fallback"
  pass "delegated summaries preserve long ids and reject missing home identity markers"
}

test_handoff_rebinds_identity_and_decision_surfaces() {
  local parent mate mate_real task manifest decision main_decision decision_manifest wt fakebin canonical bearings hash gen out rc
  command -v tasks-axi >/dev/null 2>&1 || { pass "linked handoff coverage skipped without tasks-axi"; return; }
  parent=$(make_home handoff-parent)
  mate="$TMP_ROOT/handoff-mate"
  task=linked-captain-hold
  decision=linked-status-decision
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'planning\n' > "$mate/.fm-secondmate-home"
  printf -- '- planning - planning domain (home: %s; scope: planning work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  cat > "$parent/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $task - Choose linked release (repo: firstmate) (kind: captain) (hold: exact release choice pending) (hold-kind: captain)

## Done
EOF
  manifest="$parent/$task.json"
  make_manifest "$parent" "$task" "$manifest" multi
  FM_HOME="$parent" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  FM_HOME="$parent" "$ROOT/bin/fm-backlog-handoff.sh" planning "$task" >/dev/null \
    || fail "linked local backlog handoff failed"
  mate_real=$(cd "$mate" && pwd -P)
  FM_HOME="$mate" "$WORK_IDENTITY" verify "$task" | jq -e \
    --arg home "$mate_real" '.status == "linked" and .binding.home == $home
      and .binding.home_id == "secondmate:planning" and .binding.task_id == "linked-captain-hold"' >/dev/null \
    || fail "linked handoff did not atomically stage a destination-bound identity"
  jq -e '.role == "source" and .state == "completed"
      and .transfer.target.home_id == "secondmate:planning"' \
    "$parent/data/$task/work-identity-handoff-source.json" >/dev/null \
    || fail "successful handoff did not retain an exact source ownership tombstone"
  jq -e '.role == "target" and .state == "completed"
      and .transfer.source.home_id == "main"' \
    "$mate/data/$task/work-identity-handoff-target.json" >/dev/null \
    || fail "successful handoff did not retain an exact destination commit receipt"
  out=$(FM_HOME="$parent" "$WORK_IDENTITY" record "$task" --file "$manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "source intake published again after completed ownership transfer"

  decision_manifest="$mate/$decision.json"
  wt="$mate/projects/$decision"
  mkdir -p "$wt"
  make_manifest "$mate" "$decision" "$decision_manifest"
  record_and_brief "$mate" "$decision" "$decision_manifest"
  hash=$(FM_HOME="$mate" "$WORK_IDENTITY" verify "$decision" | jq -r '.sha256')
  fm_write_meta "$mate/state/$decision.meta" \
    "window=firstmate:fm-$decision" "endpoint_task_id=$decision" "worktree=$wt" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "work_identity_schema=fm-work-identity.v1" "work_identity_status=linked" "work_identity_sha256=$hash"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$mate/state" "$decision")
  "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" "$decision" idle --gen "$gen" \
    --source claude-hook --event stop
  printf 'needs-decision [key=exact-choice]: choose the exact linked option\n' > "$mate/state/$decision.status"

  main_decision=linked-main-status-decision
  decision_manifest="$parent/$main_decision.json"
  wt="$parent/projects/$main_decision"
  mkdir -p "$wt"
  make_manifest "$parent" "$main_decision" "$decision_manifest"
  record_and_brief "$parent" "$main_decision" "$decision_manifest"
  write_bound_meta "$parent" "$main_decision" "$wt"
  sed 's/^harness=codex$/harness=claude/' "$parent/state/$main_decision.meta" \
    > "$parent/state/$main_decision.meta.tmp"
  mv "$parent/state/$main_decision.meta.tmp" "$parent/state/$main_decision.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$parent/state" "$main_decision")
  "$ROOT/bin/fm-busy-event.sh" apply "$parent/state" "$main_decision" idle --gen "$gen" \
    --source claude-hook --event stop
  printf 'needs-decision [key=main-exact-choice]: choose the main linked option\n' \
    > "$parent/state/$main_decision.status"
  cat > "$parent/data/backlog.md" <<EOF
## In flight
- [ ] $main_decision - Main linked worker awaiting a decision (repo: firstmate) (kind: ship) (since 2026-08-14)

## Queued

## Done
EOF
  cat > "$mate/data/backlog.md" <<EOF
## In flight
- [ ] $decision - Linked worker awaiting a decision (repo: firstmate) (kind: ship) (since 2026-08-14)

## Queued
- [ ] $task - Choose linked release (repo: firstmate) (kind: captain) (hold: exact release choice pending) (hold-kind: captain)

## Done
EOF
  fakebin=$(make_fakebin "$parent/fakes")
  canonical=$(PATH="$fakebin:$PATH" FM_FAKE_PANE_COMMAND=claude FM_HOME="$parent" \
    FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "planning")
    | . as $mate
    | ([.decisions_open[] | select(.id == "linked-captain-hold" and .source == "backlog"
        and .work_identity_ref == "linked-captain-hold")] | length) == 1
      and ([.decisions_open[] | select(.id == "linked-status-decision" and .source == "status"
        and .work_identity_ref == "linked-status-decision")] | length) == 1
      and ([.work_identities[] | select(.task_id == "linked-captain-hold" and .work_identity.status == "linked")] | length) == 1
      and ([.work_identities[] | select(.task_id == "linked-status-decision" and .work_identity.status == "linked")] | length) == 1
  ' >/dev/null || fail "delegated decision surfaces lost their source work identities: $canonical"
  bearings=$(PATH="$fakebin:$PATH" FM_FAKE_PANE_COMMAND=claude FM_HOME="$parent" \
    FM_BEARINGS_NOW=2026-08-14T12:00:00Z "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e '
    ([.secondmates[] | select(.id == "planning" and .state == "captain_decision"
        and (.doing | contains("choose the exact linked option")))] | length) == 1
      and ([.decisions_open[] | select(.id == "planning/linked-captain-hold"
        and .work_identity == "linked" and (.work_units | contains("wu-exact-intake"))
        and (.sources | contains("dtm:issue:DTM-431")))] | length) == 1
      and ([.decisions_open[] | select(.id == "planning/linked-status-decision"
        and .verb == "needs-decision" and .work_identity == "linked"
        and (.work_units | contains("wu-exact-intake")))] | length) == 1
      and ([.decisions_open[] | select(.id == "linked-main-status-decision"
        and .owner == "(main)" and .verb == "needs-decision"
        and .work_identity == "linked" and (.sources | contains("DTM-431")))] | length) == 1
  ' >/dev/null || fail "Bearings decision projection lost a canonical linked decision: $bearings"
  hash=$(sha256_file_for_test "$parent/data/$task/work-identity.json")
  [ -n "$hash" ] || fail "source handoff identity was not retained as immutable provenance"
  pass "linked handoff rebinds identity for delegated decision summaries and Bearings"
}

test_handoff_preparation_is_durable_and_rollback_safe() {
  local parent mate task_a task_b race manifest transfer out rc
  command -v tasks-axi >/dev/null 2>&1 || { pass "handoff transaction coverage skipped without tasks-axi"; return; }
  parent=$(make_home handoff-transaction-parent)
  mate="$TMP_ROOT/handoff-transaction-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'transaction\n' > "$mate/.fm-secondmate-home"
  printf -- '- transaction - transaction domain (home: %s; scope: exact work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  task_a=transaction-a
  task_b=transaction-b
  for task in "$task_a" "$task_b"; do
    manifest="$parent/$task.json"
    make_manifest "$parent" "$task" "$manifest"
    FM_HOME="$parent" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
  done
  mkdir -p "$mate/data/$task_b"
  printf 'pre-existing destination instructions\n' > "$mate/data/$task_b/brief.md"
  cat > "$parent/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $task_a - first transactional identity (repo: firstmate)
- [ ] $task_b - second transactional identity (repo: firstmate)

## Done
EOF
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-backlog-handoff.sh" transaction "$task_a" "$task_b" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "multi-item handoff ignored a later destination identity conflict"
  assert_grep "$task_a" "$parent/data/backlog.md" "failed handoff moved the first backlog item"
  assert_grep "$task_b" "$parent/data/backlog.md" "failed handoff moved the second backlog item"
  assert_absent "$mate/data/$task_a/work-identity.json" "failed staging published an immutable first sidecar"
  assert_absent "$mate/data/$task_a/work-identity-handoff-target.json" "failed staging retained the first target prepare"
  assert_absent "$parent/data/$task_a/work-identity-handoff-source.json" "failed staging retained the first source prepare"
  assert_absent "$parent/data/$task_b/work-identity-handoff-source.json" "failed staging retained the second source prepare"
  FM_HOME="$parent" "$WORK_IDENTITY" verify "$task_a" | jq -e '.status == "linked"' >/dev/null \
    || fail "failed multi-item staging damaged the source identity"

  transfer=$(FM_HOME="$parent" "$WORK_IDENTITY" handoff-prepare "$task_a" \
    --to-home "$mate" --to-home-id secondmate:transaction)
  printf '%s\n' "$transfer" | FM_HOME="$mate" "$WORK_IDENTITY" handoff-stage "$task_a" --file - >/dev/null \
    || fail "could not stage the interrupted committed-target fixture"
  printf '%s\n' "$transfer" | FM_HOME="$mate" "$WORK_IDENTITY" handoff-commit "$task_a" --file - >/dev/null \
    || fail "could not commit the interrupted target fixture"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  tasks-axi mv "$task_a" --file "$parent/data/backlog.md" --to "$mate/data/backlog.md" >/dev/null \
    || fail "could not move the interrupted target backlog fixture"
  jq -e '.state == "prepared"' "$parent/data/$task_a/work-identity-handoff-source.json" >/dev/null \
    || fail "interrupted target fixture unexpectedly completed source ownership"
  rc=0
  out=$(FM_HOME="$parent" "$ROOT/bin/fm-backlog-handoff.sh" transaction "$task_a" "$task_b" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "mixed retry ignored the later destination conflict"
  assert_grep "$task_b" "$parent/data/backlog.md" "mixed retry moved the conflicting backlog item"
  jq -e '.role == "target" and .state == "completed"' \
    "$mate/data/$task_a/work-identity-handoff-target.json" >/dev/null \
    || fail "mixed retry lost the committed destination receipt"
  jq -e '.role == "source" and .state == "completed"' \
    "$parent/data/$task_a/work-identity-handoff-source.json" >/dev/null \
    || fail "mixed retry resurrected source ownership after a proven target commit"
  assert_absent "$parent/data/$task_b/work-identity-handoff-source.json" \
    "mixed retry left the conflicting source identity prepared"
  assert_absent "$mate/data/$task_b/work-identity-handoff-target.json" \
    "mixed retry left the conflicting destination identity prepared"
  FM_HOME="$mate" "$WORK_IDENTITY" verify "$task_a" | jq -e '.status == "linked"' >/dev/null \
    || fail "mixed retry blocked the already committed destination identity"
  rc=0
  out=$(FM_HOME="$parent" "$WORK_IDENTITY" verify "$task_a" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "mixed retry made the completed source identity publishable again"

  race=record-during-handoff
  manifest="$parent/$race.json"
  make_manifest "$parent" "$race" "$manifest"
  transfer=$(FM_HOME="$parent" "$WORK_IDENTITY" handoff-prepare "$race" \
    --to-home "$mate" --to-home-id secondmate:transaction)
  printf '%s\n' "$transfer" | FM_HOME="$mate" "$WORK_IDENTITY" handoff-stage "$race" --file - >/dev/null \
    || fail "unlinked handoff preparation did not reach the target"
  out=$(FM_HOME="$parent" "$WORK_IDENTITY" record "$race" --file "$manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "concurrent intake published after handoff preparation froze ownership"
  out=$(FM_HOME="$mate" "$WORK_IDENTITY" verify "$race" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "target projection published while identity handoff was only prepared"
  printf '%s\n' "$transfer" | FM_HOME="$mate" "$WORK_IDENTITY" handoff-abort "$race" --file - >/dev/null \
    || fail "prepared target identity could not abort"
  printf '%s\n' "$transfer" | FM_HOME="$parent" "$WORK_IDENTITY" handoff-cancel "$race" --file - >/dev/null \
    || fail "prepared source identity could not cancel"
  FM_HOME="$parent" "$WORK_IDENTITY" record "$race" --file "$manifest" >/dev/null \
    || fail "intake did not resume after an exact handoff cancellation"
  pass "handoff preparation freezes intake and failed batches leave no immutable target sidecars"
}

test_delegated_integrity_failure_stops_parent_publication() {
  local parent mate task manifest out rc=0 sidecar
  parent=$(make_home integrity-parent)
  mate="$TMP_ROOT/integrity-mate"
  task=stale-delegated
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'integrity\n' > "$mate/.fm-secondmate-home"
  printf -- '- integrity - integrity domain (home: %s; scope: integrity work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  manifest="$mate/manifest.json"
  make_manifest "$mate" "$task" "$manifest"
  record_and_brief "$mate" "$task" "$manifest"
  cat > "$mate/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $task - Stale delegated relation (repo: firstmate) (kind: ship)

## Done
EOF
  sidecar="$mate/data/$task/work-identity.json"
  jq -S -c '.work_units[0].id="stale-delegated-unit"' "$sidecar" > "$mate/changed.json"
  mv "$mate/changed.json" "$sidecar"
  out=$(FM_HOME="$parent" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "parent published a fallback snapshot for stale delegated identity state"
  assert_contains "$out" "work identity integrity failure in secondmate integrity" \
    "parent did not propagate the delegated identity integrity failure"
  pass "delegated linked integrity failures stop parent publication"
}

test_schema_maximum_delegated_identities_are_batched_once() {
  local parent mate fakebin canonical task manifest i
  parent=$(make_home maximum-parent)
  mate="$TMP_ROOT/maximum-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'maximum\n' > "$mate/.fm-secondmate-home"
  printf -- '- maximum - maximum identity domain (home: %s; scope: maximum work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  printf '## In flight\n\n## Queued\n' > "$mate/data/backlog.md"
  i=1
  while [ "$i" -le 20 ]; do
    task=$(printf 'maximum-child-%02d' "$i")
    manifest="$mate/$task.json"
    make_max_manifest "$mate" "$task" "$manifest"
    FM_HOME="$mate" "$WORK_IDENTITY" record "$task" --file "$manifest" >/dev/null
    printf -- '- [ ] %s - Maximum identity decision (repo: firstmate) (kind: captain) (hold: maximum exact choice pending) (hold-kind: captain)\n' "$task" \
      >> "$mate/data/backlog.md"
    i=$((i + 1))
  done
  printf '\n## Done\n' >> "$mate/data/backlog.md"
  fakebin=$(make_fakebin "$parent/fakes")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$canonical" | jq -e '
    .secondmate_current.records[] | select(.id == "maximum")
    | .provenance.selected == "structured-home"
      and (.decisions_open | length) == 20
      and (.holds | length) == 20
      and (.queued | length) == 20
      and (.work_identities | length) == 20
      and ([.work_identities[].task_id] | unique | length) == 20
      and all(.decisions_open[]; has("work_identity") | not)
      and all(.holds[]; has("work_identity") | not)
      and all(.queued[]; has("work_identity") | not)
      and (.work_identities[] | select(.task_id == "maximum-child-20") | .work_identity
        | (.work_units | length) == 20 and (.sources | length) == 20
          and (.work_units[-1].label | length) == 160
          and (.sources[-1].id | length) == 240)
  ' >/dev/null || fail "schema-maximum delegated identities were repeated, truncated, or suppressed: $(printf '%s' "$canonical" | jq -c '.secondmate_current.records[] | select(.id == "maximum") | {current,provenance,decisions:(.decisions_open|length),holds:(.holds|length),queued:(.queued|length),identities:(.work_identities|length),counts,omitted}')"
  pass "schema-maximum delegated identities stream in bounded normalized batches"
}

test_bearings_preserves_complete_identity_references() {
  local home task manifest wt fakebin bearings hash gen last_unit last_source
  home=$(make_home complete-refs)
  task=complete-reference-worker
  manifest="$home/manifest.json"
  wt="$home/worktree"
  mkdir -p "$wt"
  make_max_manifest "$home" "$task" "$manifest"
  record_and_brief "$home" "$task" "$manifest"
  write_bound_meta "$home" "$task" "$wt"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$task")
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$task" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $task - Complete reference worker (repo: firstmate) (kind: ship) (since 2026-08-14)

## Queued

## Done
EOF
  fakebin=$(make_fakebin "$home/fakes")
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-08-14T12:00:00Z "$BEARINGS" --json)
  last_unit=$(jq -r '.work_units[-1].id' "$manifest")
  last_source=$(jq -r '.sources[-1].id' "$manifest")
  printf '%s' "$bearings" | jq -e --arg unit "$last_unit" --arg source "$last_source" '
    .in_flight[] | select(.id == "complete-reference-worker")
    | .work_identity == "linked"
      and (.work_units | contains($unit))
      and (.sources | contains($source))
      and (.work_units | length) > 600
      and (.sources | length) > 600
  ' >/dev/null || fail "Bearings truncated later exact work-unit or source references: $bearings"
  hash=$(sha256_file_for_test "$home/data/$task/work-identity.json")
  [ -n "$hash" ] || fail "complete reference fixture lost its canonical sidecar"
  pass "Bearings preserves complete IDs and labels for every bounded worker row"
}

test_display_labels_cannot_spoof_exact_references() {
  local home task manifest wt fakebin bearings view expected gen
  home=$(make_home escaped-labels)
  task=escaped-label-worker
  manifest="$home/manifest.json"
  wt="$home/worktree"
  mkdir -p "$wt"
  make_manifest "$home" "$task" "$manifest"
  jq '.work_units[0].label="Friendly]; work-aligner:work-unit:fake [Fake"' \
    "$manifest" > "$home/escaped.json"
  record_and_brief "$home" "$task" "$home/escaped.json"
  write_bound_meta "$home" "$task" "$wt"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$task")
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$task" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  printf 'working: escaped label projection\n' > "$home/state/$task.status"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $task - Escaped label worker (repo: firstmate) (kind: ship) (since 2026-08-14)

## Queued

## Done
EOF
  fakebin=$(make_fakebin "$home/fakes")
  expected='work-aligner:work-unit:wu-exact-intake [Friendly\]\; work-aligner:work-unit:fake \[Fake]'
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-08-14T12:00:00Z \
    "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e --arg expected "$expected" '
    .in_flight[] | select(.id == "escaped-label-worker") | .work_units == $expected
  ' >/dev/null || fail "Bearings did not escape identity-reference delimiters in display labels: $bearings"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-14T12:00:00Z "$FLEET_VIEW")
  assert_contains "$view" "$expected" \
    "fleet view did not escape identity-reference delimiters in display labels"
  pass "display labels cannot masquerade as additional exact identities"
}

test_secondmate_parent_decisions_and_nested_caps_are_disclosed() {
  local parent mate fakebin child gen bearings
  parent=$(make_home capped-parent)
  mate="$TMP_ROOT/capped-mate"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'capped\n' > "$mate/.fm-secondmate-home"
  printf -- '- capped - capped domain (home: %s; scope: capped work; projects: firstmate; added 2026-08-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/capped.meta" "$mate" "firstmate:fm-capped" firstmate codex
  printf 'needs-decision [key=stale-parent]: stale parent-only choice\n' > "$parent/state/capped.status"
  printf '## In flight\n' > "$mate/data/backlog.md"
  for child in capped-child-a capped-child-b; do
    mkdir -p "$mate/projects/$child"
    fm_write_meta "$mate/state/$child.meta" \
      "window=firstmate:fm-$child" "worktree=$mate/projects/$child" "project=firstmate" \
      "harness=claude" "kind=ship" "mode=no-mistakes"
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$mate/state" "$child")
    "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" "$child" busy --gen "$gen" \
      --source claude-hook --event user-prompt-submit
    printf 'working: %s\n' "$child" > "$mate/state/$child.status"
    printf -- '- [ ] %s - Capped delegated child (repo: firstmate) (kind: ship) (since 2026-08-14)\n' \
      "$child" >> "$mate/data/backlog.md"
  done
  printf '\n## Queued\n\n## Done\n' >> "$mate/data/backlog.md"
  fakebin=$(make_fakebin "$parent/fakes")
  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$parent" FM_BEARINGS_NOW=2026-08-14T12:00:00Z \
    FM_SNAPSHOT_SECONDMATE_CHILDREN=1 "$BEARINGS" --json --all-in-flight)
  printf '%s' "$bearings" | jq -e '
    ([.decisions_open[] | select(.id == "capped" and .owner == "(main)")] | length) == 0
      and ([.delegated_work[] | select(.owner == "capped")] | length) == 1
      and ([.omitted[] | select(
        .surface == "delegated_work omitted by structured-home cap for capped: 1"
        and .reveal == "raise FM_SNAPSHOT_SECONDMATE_CHILDREN")] | length) == 1
  ' >/dev/null || fail "Bearings trusted a parent secondmate decision or hid a nested delegated cap: $bearings"
  pass "Bearings excludes parent secondmate decisions and discloses nested worker caps"
}

test_intake_through_fleet_projection
test_spawn_delivers_validated_brief_snapshot
test_sidecar_validation_hashes_captured_bytes
test_concurrent_idempotence_and_explicit_unlinked
test_namespace_separation_and_contract_rejections
test_unsafe_files_labels_and_exact_binding
test_stale_and_changed_relations_refuse
test_legacy_and_fuzzy_fallbacks_are_unlinked
test_delegated_secondmate_projection
test_handoff_rebinds_identity_and_decision_surfaces
test_handoff_preparation_is_durable_and_rollback_safe
test_delegated_integrity_failure_stops_parent_publication
test_schema_maximum_delegated_identities_are_batched_once
test_bearings_preserves_complete_identity_references
test_display_labels_cannot_spoof_exact_references
test_secondmate_parent_decisions_and_nested_caps_are_disclosed
