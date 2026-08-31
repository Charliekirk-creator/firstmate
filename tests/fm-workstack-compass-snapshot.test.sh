#!/usr/bin/env bash
# Read-only Workstack Compass producer security, truthfulness, and integration tests.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRODUCER="$ROOT/bin/fm-workstack-compass-snapshot.py"
TMP_ROOT=$(fm_test_tmproot fm-workstack-compass)

run_failure() {
  local expected=$1
  shift
  local output rc
  set +e
  output=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected producer refusal containing: $expected"
  assert_contains "$output" "$expected" "producer refusal did not explain the safe failure"
}

write_fake_model() {
  local app=$1 max_bytes=${2:-2097152} behavior=${3:-accept}
  local schema_version=${4:-workstack-compass.snapshot.v1}
  mkdir -p "$app/src/workstack_compass" "$app/bin"
  git -C "$app" init -q
  cat > "$app/src/workstack_compass/model.py" <<PY
SCHEMA_VERSION = "$schema_version"
MAX_SNAPSHOT_BYTES = $max_bytes

class ValidatedSnapshot:
    def integrity_issues(self):
        return ()

def snapshot_from_mapping(document):
    if document.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("test model version mismatch")
    if "$behavior" == "reject":
        raise ValueError("test model rejection")
    return ValidatedSnapshot()
PY
  cat > "$app/bin/workstack-compass" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 0755 "$app/bin/workstack-compass"
}

init_project() {
  local root=$1
  mkdir -p "$root"
  git -C "$root" init -q
}

make_world() {
  local world="$TMP_ROOT/$1"
  mkdir -p "$world/home/bin" "$world/home/data/workstack-compass" "$world/home/state"
  world=$(cd "$world" && pwd -P)
  chmod 0700 "$world/home/data/workstack-compass"
  cat > "$world/home/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' invoked > "${FM_HOME:?}/state/crew-state-invoked"
printf '%s\n' 'state: working · source: pane · STATUS_READER_DETAIL_SECRET'
exit 9
SH
  chmod 0755 "$world/home/bin/fm-crew-state.sh"
  write_fake_model "$world/app"
  init_project "$world/dtm"
  init_project "$world/tickets"
  init_project "$world/alpha"
  mkdir -p "$world/dtm/config"
  cat > "$world/dtm/config/board.json" <<'JSON'
{
  "project": {"id": "PVT_TEST_BOARD", "number": 1},
  "issue_repo": "example/data-team-management",
  "ignored_private_value": "SOURCE_ROW_SECRET"
}
JSON
  cat > "$world/tickets/README.md" <<'MD'
# Sanitized Data Team Tickets

SOURCE_ROW_SECRET belongs only to this sanitized source fixture.
MD
  cat > "$world/home/data/projects.md" <<'MD'
# Projects

- zeta [no-mistakes] - REGISTRY_SECRET must not be projected (added 2026-01-01)
- gl-data-team-tickets [no-mistakes] - sanitized artifact repository (added 2026-01-01)
- data-team-management [no-mistakes] - sanitized board repository (added 2026-01-01)
- alpha [local-only] - sanitized local project (added 2026-01-01)
MD
  cat > "$world/home/data/backlog.md" <<'MD'
# Backlog

## In flight

## Queued

## Done
MD
  tasks-axi add task-z "BACKLOG_TITLE_SECRET" \
    --file "$world/home/data/backlog.md" --kind ship --repo zeta --priority 1 --start >/dev/null
  tasks-axi add task-a "SECOND_PRIVATE_TITLE" \
    --file "$world/home/data/backlog.md" --kind scout --repo alpha --priority 2 --start >/dev/null
  cat > "$world/home/state/task-z.meta" <<'META'
project=/PRIVATE/PATH/SECRET
kind=ship
busy_gen=transient-busy-z
spawn_gen=spawn-task-z
model=PRIVATE_MODEL_SECRET
harness=PRIVATE_HARNESS_SECRET
META
  cat > "$world/home/state/task-a.meta" <<'META'
project=/ANOTHER/PRIVATE/PATH
kind=scout
busy_gen=transient-busy-a
spawn_gen=spawn-task-a
model=PRIVATE_MODEL_SECRET
META
  printf '%s\n' 'working: STATUS_PROSE_SECRET' > "$world/home/state/task-a.status"
  printf '%s\n' "$world"
}

run_world() {
  local world=$1
  shift
  FM_HOME="$world/home" "$PRODUCER" \
    --workstack-root "$world/app" \
    --project-root "gl-data-team-tickets=$world/tickets" \
    --project-root "data-team-management=$world/dtm" \
    --project-root "alpha=$world/alpha" \
    "$@"
}

json_assert() {
  local file=$1 expression=$2 message=$3
  jq -e "$expression" "$file" >/dev/null || fail "$message"
}

file_mode() {
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"
}

file_inode() {
  stat -f %i "$1" 2>/dev/null || stat -c %i "$1"
}

test_successful_truthful_projection() {
  local world snapshot output
  world=$(make_world success)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  rmdir "$world/home/data/workstack-compass"
  output=$(umask 0777; PRIVATE_ENV_SECRET=should-not-project run_world "$world") \
    || fail "sanitized Firstmate, DTM, and Data Team Tickets generation failed"
  assert_contains "$output" "Snapshot: $snapshot" "success did not print the exact private path"
  assert_contains "$output" \
    "Launch: cd $world/app && ./bin/workstack-compass --snapshot $snapshot --color --reduced-motion" \
    "success did not print the exact local launch command"
  [ "$(file_mode "$snapshot")" = 600 ] || fail "snapshot mode is not 0600"
  [ "$(find "$world/home/data/workstack-compass" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" = 1 ] \
    || fail "generation left a partial temporary file beside the snapshot"
  json_assert "$snapshot" '.schema_version == "workstack-compass.snapshot.v1"' \
    "producer did not require the authoritative schema version"
  json_assert "$snapshot" \
    '(.observation_identity | startswith("observation:sha256:")) and (.observed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and all(.sources[]; (.detail | type) == "string" and (.detail | length) > 0)' \
    "observation time, identity, or source provenance is missing"
  json_assert "$snapshot" \
    '[.projects[].label] == ["alpha","data-team-management","gl-data-team-tickets","zeta"]' \
    "registered project ordering is not deterministic"
  json_assert "$snapshot" \
    '[.worker_incarnations[].worker_identity] == ["firstmate-worker:task-a","firstmate-worker:task-z"]' \
    "worker ordering is not deterministic"
  json_assert "$snapshot" \
    '[.worker_incarnations[].worker_incarnation_identity] == ["firstmate-worker-incarnation:task-a:spawn-task-a","firstmate-worker-incarnation:task-z:spawn-task-z"]' \
    "durable spawn generations did not define worker incarnations"
  json_assert "$snapshot" \
    '(.worker_incarnations[] | select(.worker_identity == "firstmate-worker:task-a") | .project_identity) == "firstmate-project:alpha"' \
    "exact task-to-registry project relation was not preserved"
  json_assert "$snapshot" \
    'all(.worker_incarnations[]; .status == "unavailable")' \
    "unbounded worker current states were not kept unavailable"
  json_assert "$snapshot" \
    '(.sources[] | select(.source_identity == "source:firstmate-task-identities") | .completeness) == "partial"' \
    "unavailable current-state evidence was reported as complete"
  [ ! -e "$world/home/state/crew-state-invoked" ] \
    || fail "producer invoked the general live-state reader"
  json_assert "$snapshot" \
    'all(.worker_incarnations[]; .liveness == "unavailable" and .context_percent == null and .duration_seconds == null)' \
    "missing worker telemetry was fabricated"
  json_assert "$snapshot" \
    '.plans == [] and .stages == [] and .work_units == [] and .commands == [] and .next_actions == [] and .deliveries == [] and .acceptances == [] and .decisions == []' \
    "missing typed work or lifecycle relations were fabricated"
  json_assert "$snapshot" \
    'any(.sources[]; .source_identity == "source:data-team-management-board:PVT_TEST_BOARD") and (.projects[] | select(.label == "data-team-management") | .source_identity) == "source:data-team-management-board:PVT_TEST_BOARD"' \
    "exact Data Team Management source identity was not preserved"
  json_assert "$snapshot" \
    'any(.sources[]; .completeness == "complete") and any(.sources[]; .completeness == "partial") and any(.sources[]; .completeness == "unavailable")' \
    "complete, partial, and unavailable source evidence was not preserved"
  json_assert "$snapshot" \
    '(.interfaces[] | select(.name == "exact-work-identity") | .status) == "partial" and (.interfaces[] | select(.name == "worker-context-duration") | .status) == "partial" and (.interfaces[] | select(.name == "decision-history") | .status) == "unavailable"' \
    "interface seams overclaimed upstream availability"
  for forbidden in REGISTRY_SECRET BACKLOG_TITLE_SECRET SECOND_PRIVATE_TITLE \
    SOURCE_ROW_SECRET STATUS_PROSE_SECRET STATUS_READER_DETAIL_SECRET PRIVATE_MODEL_SECRET \
    PRIVATE_HARNESS_SECRET PRIVATE_ENV_SECRET /PRIVATE/PATH "$world"; do
    assert_not_contains "$(cat "$snapshot")" "$forbidden" \
      "snapshot leaked a private source value: $forbidden"
  done
  pass "sanitized local sources produce a validated, private, truthful snapshot"
}

test_missing_relations_stay_missing() {
  local world snapshot
  world=$(make_world missing-relations)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  cat > "$world/home/state/orphan.meta" <<'META'
kind=ship
spawn_gen=spawn-orphan
project=/path/must/not/be/a/join
META
  run_world "$world" >/dev/null || fail "missing-relation projection failed"
  json_assert "$snapshot" \
    '(.worker_incarnations[] | select(.worker_identity == "firstmate-worker:orphan") | .project_identity) == null' \
    "producer inferred an orphan worker project from a path"
  json_assert "$snapshot" \
    '(.worker_incarnations[] | select(.worker_identity == "firstmate-worker:orphan") | .work_unit_identities) == []' \
    "producer inferred an orphan worker work relation"
  pass "missing exact relations remain explicitly absent"
}

test_duplicate_and_broken_identities_refuse() {
  local world snapshot before
  world=$(make_world broken-identities)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  run_world "$world" >/dev/null || fail "baseline generation failed"
  before=$(shasum -a 256 "$snapshot" | awk '{print $1}')
  printf '%s\n' '- alpha [local-only] - duplicate sanitized identity (added 2026-01-02)' \
    >> "$world/home/data/projects.md"
  run_failure "duplicate exact identity" run_world "$world"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "duplicate registry failure changed the prior complete snapshot"
  sed -i.bak '$d' "$world/home/data/projects.md"
  rm -f "$world/home/data/projects.md.bak"
  printf '%s\n' 'spawn_gen=duplicate-generation' >> "$world/home/state/task-z.meta"
  run_failure "exactly one incarnation identity" run_world "$world"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "broken task identity failure changed the prior complete snapshot"
  pass "duplicate and broken source identities refuse without partial replacement"
}

test_atomic_replacement_and_model_rejection() {
  local world snapshot inode_before hash_before inode_after hash_after
  world=$(make_world atomic)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  run_world "$world" >/dev/null || fail "baseline atomic generation failed"
  inode_before=$(file_inode "$snapshot")
  hash_before=$(shasum -a 256 "$snapshot" | awk '{print $1}')
  printf '%s\n' '- beta [local-only] - sanitized new project (added 2026-01-02)' \
    >> "$world/home/data/projects.md"
  run_world "$world" >/dev/null || fail "atomic replacement generation failed"
  inode_after=$(file_inode "$snapshot")
  hash_after=$(shasum -a 256 "$snapshot" | awk '{print $1}')
  [ "$inode_after" != "$inode_before" ] || fail "snapshot replacement reused the published inode"
  [ "$hash_after" != "$hash_before" ] || fail "source change did not replace the observation"
  jq -e . "$snapshot" >/dev/null || fail "atomically replaced snapshot is not complete JSON"
  write_fake_model "$world/app" 2097152 accept test.snapshot.v1
  run_failure "model contract is unsupported" run_world "$world"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$hash_after" ] \
    || fail "wrong model schema replaced the last complete snapshot"
  write_fake_model "$world/app" 2097152 reject
  run_failure "executable model rejected" run_world "$world"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$hash_after" ] \
    || fail "model rejection replaced the last complete snapshot"
  pass "complete snapshots replace atomically and model rejection preserves the prior file"
}

test_unsafe_outputs_and_sources_refuse() {
  local world parent_link outside_parent
  world=$(make_world unsafe)
  mkdir -p "$world/outside"
  run_failure "must stay below" env FM_HOME="$world/home" "$PRODUCER" \
    --workstack-root "$world/app" --output "$world/outside/snapshot.json"

  ln -s "$world/outside/snapshot.json" \
    "$world/home/data/workstack-compass/snapshot.json"
  run_failure "not one private ordinary file" run_world "$world"
  rm "$world/home/data/workstack-compass/snapshot.json"
  mkfifo "$world/home/data/workstack-compass/snapshot.json"
  run_failure "not one private ordinary file" run_world "$world"
  rm "$world/home/data/workstack-compass/snapshot.json"

  outside_parent="$world/private-parent"
  mkdir -p "$outside_parent"
  parent_link="$world/home/data/linked-parent"
  ln -s "$outside_parent" "$parent_link"
  run_failure "must stay below" env FM_HOME="$world/home" "$PRODUCER" \
    --workstack-root "$world/app" --output "$parent_link/snapshot.json"

  rm "$world/dtm/config/board.json"
  printf '%s\n' '{"project":{"id":"PVT_ESCAPE","number":1},"issue_repo":"example/repo"}' \
    > "$world/outside-board.json"
  ln -s "$world/outside-board.json" "$world/dtm/config/board.json"
  run_failure "symlink" run_world "$world"
  pass "path escapes, symlinks, and unsafe output files are refused"
}

test_repository_containment_refuses_before_output_writes() {
  local world project alias
  world=$(make_world repository-containment)
  rmdir "$world/home/data/workstack-compass"
  write_fake_model "$world/home"
  run_failure "must not be inside a source repository" env \
    FM_HOME="$world/home" "$PRODUCER" --workstack-root "$world/home"
  [ ! -e "$world/home/data/workstack-compass" ] \
    || fail "Workstack-root containment refusal created an output directory"

  world=$(make_world project-containment)
  rmdir "$world/home/data/workstack-compass"
  project="$world/home/data/source-project"
  init_project "$project"
  mkdir -m 0700 "$project/private"
  mkdir -p "$world/aliases"
  ln -s "$world/home/data" "$world/aliases/data-link"
  alias="$world/aliases/data-link/source-project"
  run_failure "must not be inside a source repository" env \
    FM_HOME="$world/home" "$PRODUCER" \
    --workstack-root "$world/app" \
    --project-root "alpha=$alias" \
    --output "$project/private/snapshot.json"
  [ -z "$(find "$project/private" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "project-root containment refusal created an output or temporary file"
  pass "canonical repository containment is refused before output writes"
}

test_malformed_and_oversized_inputs_and_output_refuse() {
  local world snapshot before
  world=$(make_world bounds)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  run_world "$world" >/dev/null || fail "bounds baseline generation failed"
  before=$(shasum -a 256 "$snapshot" | awk '{print $1}')
  printf '%s\n' '{malformed' > "$world/dtm/config/board.json"
  run_failure "malformed JSON" run_world "$world"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "malformed source changed the prior complete snapshot"

  python3 - "$world/home/data/projects.md" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b"#" * (128 * 1024 + 1))
PY
  run_failure "bounded size" run_world "$world"

  world=$(make_world output-bound)
  write_fake_model "$world/app" 128 accept
  run_failure "model size bound" run_world "$world"
  [ ! -e "$world/home/data/workstack-compass/snapshot.json" ] \
    || fail "oversized model output left a published snapshot"
  pass "malformed and oversized source or output data are bounded safely"
}

test_optional_source_appearance_during_observation_refuses() {
  local world snapshot before fakebin registry
  world=$(make_world optional-source-race)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  run_world "$world" >/dev/null || fail "optional-source race baseline failed"
  before=$(shasum -a 256 "$snapshot" | awk '{print $1}')
  registry="$world/home/data/projects.md"
  rm "$registry"
  fakebin="$world/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' '# appeared during observation' > '$registry'
printf '%s\n' 'count: 0'
printf '%s\n' 'tasks[0]{id,state,kind,repo,title}:'
printf '%s\n' 'help[0]:'
SH
  chmod 0755 "$fakebin/tasks-axi"
  run_failure "source changed during observation" env \
    PATH="$fakebin:$PATH" FM_HOME="$world/home" "$PRODUCER" \
    --workstack-root "$world/app" \
    --output "$snapshot"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "optional-source race changed the prior complete snapshot"
  pass "an optional source appearing mid-observation prevents publication"
}

test_source_change_during_observation_refuses() {
  local world fakebin registry
  world=$(make_world source-race)
  registry="$world/home/data/projects.md"
  fakebin="$world/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' '# changed during observation' >> '$registry'
printf '%s\n' 'count: 0'
printf '%s\n' 'tasks[0]{id,state,kind,repo,title}:'
printf '%s\n' 'help[0]:'
SH
  chmod 0755 "$fakebin/tasks-axi"
  run_failure "source changed during observation" env \
    PATH="$fakebin:$PATH" FM_HOME="$world/home" "$PRODUCER" \
    --workstack-root "$world/app" \
    --project-root "data-team-management=$world/dtm" \
    --project-root "gl-data-team-tickets=$world/tickets" \
    --output "$world/home/data/workstack-compass/snapshot.json"
  [ ! -e "$world/home/data/workstack-compass/snapshot.json" ] \
    || fail "source-race refusal published a mixed observation"
  pass "a source change during observation prevents mixed publication"
}

test_private_application_model_integration() {
  local app=${FM_WORKSTACK_COMPASS_TEST_APP:-} world snapshot
  if [ -z "$app" ]; then
    printf '%s\n' 'ok - private Workstack executable-model integration skipped (set FM_WORKSTACK_COMPASS_TEST_APP)'
    return 0
  fi
  world=$(make_world private-model)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  FM_HOME="$world/home" "$PRODUCER" \
    --workstack-root "$app" \
    --project-root "data-team-management=$world/dtm" \
    --project-root "gl-data-team-tickets=$world/tickets" \
    --project-root "alpha=$world/alpha" \
    --output "$snapshot" >/dev/null \
    || fail "private Workstack executable model rejected sanitized live-source fixtures"
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$app/src" python3 -B - "$snapshot" <<'PY'
from pathlib import Path
import sys
from workstack_compass.model import JsonFileSnapshotProvider
snapshot = JsonFileSnapshotProvider(Path(sys.argv[1])).load()
if snapshot.integrity_issues():
    raise SystemExit("private executable model reported integrity issues")
PY
  pass "private Workstack executable model validates the sanitized generated snapshot"
}

test_successful_truthful_projection
test_missing_relations_stay_missing
test_duplicate_and_broken_identities_refuse
test_atomic_replacement_and_model_rejection
test_unsafe_outputs_and_sources_refuse
test_repository_containment_refuses_before_output_writes
test_malformed_and_oversized_inputs_and_output_refuse
test_optional_source_appearance_during_observation_refuses
test_source_change_during_observation_refuses
test_private_application_model_integration
