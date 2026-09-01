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

run_failure_with_timeout() {
  local expected=$1
  shift
  python3 - "$expected" "$@" <<'PY'
import subprocess
import sys

expected = sys.argv[1]
try:
    completed = subprocess.run(
        sys.argv[2:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=3
    )
except subprocess.TimeoutExpired:
    raise SystemExit("producer blocked while opening an unsafe source")
output = completed.stdout.decode("utf-8", errors="replace")
if completed.returncode == 0:
    raise SystemExit(f"producer accepted an unsafe source; output: {output}")
if expected not in output:
    raise SystemExit(f"producer refusal omitted {expected!r}; output: {output}")
PY
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

write_slow_model() {
  local app=$1
  write_fake_model "$app"
  python3 - "$app/src/workstack_compass/model.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "def snapshot_from_mapping(document):\n",
    "def snapshot_from_mapping(document):\n    import time\n    time.sleep(1)\n",
)
path.write_text(text)
PY
}

write_hostile_model() {
  local app=$1 marker=$2
  python3 - "$app/src/workstack_compass/model.py" "$marker" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
marker = json.dumps(sys.argv[2])
path.write_text(f'''SCHEMA_VERSION = "workstack-compass.snapshot.v1"
MAX_SNAPSHOT_BYTES = 2097152

import os
import socket

try:
    open({marker}, "w").close()
except OSError:
    pass
else:
    raise RuntimeError("model filesystem writes were not confined")

probe = socket.socket()
try:
    probe.bind(("127.0.0.1", 0))
except OSError:
    pass
else:
    raise RuntimeError("model network access was not confined")
finally:
    probe.close()

if os.environ.get("PRIVATE_ENV_SECRET"):
    raise RuntimeError("private parent environment reached the model")

class ValidatedSnapshot:
    def integrity_issues(self):
        return ()

def snapshot_from_mapping(document):
    document["projects"][0]["label"] = "MODEL_MUTATION_SECRET"
    return ValidatedSnapshot()
''')
PY
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
  sed -i.bak '$d' "$world/home/state/task-z.meta"
  rm -f "$world/home/state/task-z.meta.bak"
  sed -i.bak 's/^spawn_gen=.*/spawn_gen=.hidden-generation/' "$world/home/state/task-z.meta"
  rm -f "$world/home/state/task-z.meta.bak"
  run_failure "broken incarnation identity" run_world "$world"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "leading-dot incarnation failure changed the prior complete snapshot"
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

test_nonexecutable_launcher_refuses_before_publication() {
  local world snapshot
  world=$(make_world nonexecutable-launcher)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  chmod 0644 "$world/app/bin/workstack-compass"
  run_failure "not executable" run_world "$world"
  [ ! -e "$snapshot" ] || fail "nonexecutable launcher published an unusable snapshot"
  pass "a nonexecutable Workstack launcher is refused before publication"
}

test_executable_model_is_confined_and_copy_isolated() {
  local world snapshot marker
  world=$(make_world model-confinement)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  marker="$world/model-wrote-outside-sandbox"
  write_hostile_model "$world/app" "$marker"
  PRIVATE_ENV_SECRET=must-not-reach-model run_world "$world" >/dev/null \
    || fail "confined executable model could not validate an isolated candidate"
  [ ! -e "$marker" ] || fail "executable model wrote outside its read-only boundary"
  assert_not_contains "$(cat "$snapshot")" MODEL_MUTATION_SECRET \
    "executable model mutated the candidate serialized by the producer"
  pass "executable model has no network, write, environment, or mutation authority"
}

test_output_parent_relocation_refuses_without_source_write() {
  local world private relocated producer_pid rc
  world=$(make_world output-parent-relocation)
  private="$world/home/data/private"
  relocated="$world/alpha/relocated-output"
  mkdir -m 0700 "$private"
  write_slow_model "$world/app"
  set +e
  FM_HOME="$world/home" "$PRODUCER" \
    --workstack-root "$world/app" \
    --project-root "alpha=$world/alpha" \
    --output "$private/snapshot.json" >/dev/null 2>&1 &
  producer_pid=$!
  set -e
  sleep 0.3
  mv "$private" "$relocated"
  set +e
  wait "$producer_pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "producer accepted a relocated output authority"
  [ -z "$(find "$relocated" -mindepth 1 -maxdepth 1 -type f -print -quit)" ] \
    || fail "relocated output authority wrote into a bound source repository"
  pass "output authority relocation refuses without modifying a source repository"
}

test_default_parent_relocation_refuses_before_creation() {
  local world relocated inject output rc
  world=$(make_world default-parent-relocation)
  rmdir "$world/home/data/workstack-compass"
  relocated="$world/alpha/relocated-data"
  inject="$world/inject-default-parent"
  mkdir -p "$inject"
  cat > "$inject/sitecustomize.py" <<'PY'
import os
import subprocess

source = os.environ["FM_TEST_DATA_SOURCE"]
destination = os.environ["FM_TEST_DATA_DESTINATION"]
real_popen = subprocess.Popen

class GuardedPopen(real_popen):
    def __init__(self, *args, **kwargs):
        if kwargs.get("pass_fds") and os.path.isdir(source) and not os.path.exists(destination):
            os.rename(source, destination)
        super().__init__(*args, **kwargs)

subprocess.Popen = GuardedPopen
PY
  set +e
  output=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$inject" \
    FM_TEST_DATA_SOURCE="$world/home/data" \
    FM_TEST_DATA_DESTINATION="$relocated" \
    FM_HOME="$world/home" "$PRODUCER" \
      --workstack-root "$world/app" \
      --project-root "alpha=$world/alpha" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "producer accepted relocated default output authority"
  assert_contains "$output" "could not be created safely" \
    "default output relocation did not fail at the safe creation boundary"
  [ -d "$relocated" ] || fail "default output race did not relocate FM_HOME data"
  [ ! -e "$relocated/workstack-compass" ] \
    || fail "default output race created a directory inside a bound repository"
  pass "default output parent creation cannot follow data into a source"
}

test_publication_authority_relocation_cannot_write_source() {
  local world private relocated inject output rc
  world=$(make_world publication-authority-race)
  private="$world/home/data/private"
  relocated="$world/alpha/relocated-publication"
  inject="$world/inject"
  mkdir -m 0700 "$private"
  mkdir -p "$inject"
  cat > "$inject/sitecustomize.py" <<'PY'
import os
import subprocess

safe = os.environ["FM_TEST_SAFE_OUTPUT_PARENT"]
relocated = os.environ["FM_TEST_RELOCATED_OUTPUT_PARENT"]
real_open = os.open
real_popen = subprocess.Popen


def move_parent(lock):
    if os.path.isdir(safe) and not os.path.exists(relocated):
        os.rename(safe, relocated)
        if lock:
            os.chmod(relocated, 0o500)


def guarded_open(path, flags, *args, **kwargs):
    directory = kwargs.get("dir_fd")
    if directory is not None and flags & os.O_CREAT and flags & os.O_EXCL:
        try:
            safe_info = os.stat(safe, follow_symlinks=False)
            directory_info = os.fstat(directory)
        except OSError:
            pass
        else:
            if (safe_info.st_dev, safe_info.st_ino) == (
                directory_info.st_dev,
                directory_info.st_ino,
            ):
                move_parent(False)
                descriptor = real_open(path, flags, *args, **kwargs)
                os.chmod(relocated, 0o500)
                return descriptor
    return real_open(path, flags, *args, **kwargs)


class GuardedPopen(real_popen):
    def __init__(self, *args, **kwargs):
        if kwargs.get("pass_fds"):
            move_parent(True)
        super().__init__(*args, **kwargs)


os.open = guarded_open
subprocess.Popen = GuardedPopen
PY
  set +e
  output=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$inject" \
    FM_TEST_SAFE_OUTPUT_PARENT="$private" \
    FM_TEST_RELOCATED_OUTPUT_PARENT="$relocated" \
    FM_HOME="$world/home" "$PRODUCER" \
      --workstack-root "$world/app" \
      --project-root "alpha=$world/alpha" \
      --output "$private/snapshot.json" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "producer accepted a relocated publication authority"
  assert_contains "$output" "boundary failed" \
    "relocated output authority did not fail closed"
  [ -d "$relocated" ] || fail "publication race did not relocate the output authority"
  chmod 0700 "$relocated"
  [ -z "$(find "$relocated" -mindepth 1 -maxdepth 1 -type f -print -quit)" ] \
    || fail "publication race created a file inside a bound source repository"
  pass "sandboxed publication cannot follow a relocated authority into a source"
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

test_fifo_source_refuses_without_blocking_or_replacement() {
  local world snapshot before
  world=$(make_world fifo-source)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  run_world "$world" >/dev/null || fail "FIFO source baseline generation failed"
  before=$(shasum -a 256 "$snapshot" | awk '{print $1}')
  rm "$world/dtm/config/board.json"
  mkfifo "$world/dtm/config/board.json"
  run_failure_with_timeout "could not be opened safely" env \
    FM_HOME="$world/home" "$PRODUCER" \
      --workstack-root "$world/app" \
      --project-root "data-team-management=$world/dtm" \
      --output "$snapshot"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "FIFO source refusal changed the prior complete snapshot"
  pass "special source files are refused without blocking or replacement"
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

test_empty_backlog_and_literal_none_relation() {
  local world snapshot
  world=$(make_world empty-backlog)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  cat > "$world/home/data/backlog.md" <<'MD'
# Backlog

## In flight

## Queued

## Done
MD
  rm -f "$world/home/state"/*.meta
  run_world "$world" >/dev/null || fail "authoritative empty tasks-axi backlog was refused"
  json_assert "$snapshot" '.worker_incarnations == []' \
    "empty tasks-axi backlog fabricated worker identities"

  world=$(make_world literal-none-relation)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  printf '%s\n' '- none [local-only] - exact sanitized project identity (added 2026-01-01)' \
    >> "$world/home/data/projects.md"
  tasks-axi add task-none "PRIVATE NONE TITLE" \
    --file "$world/home/data/backlog.md" --kind ship --repo none --priority 3 --start >/dev/null
  cat > "$world/home/state/task-none.meta" <<'META'
kind=ship
spawn_gen=spawn-task-none
META
  run_world "$world" >/dev/null || fail "literal none project relation was refused"
  json_assert "$snapshot" \
    '(.worker_incarnations[] | select(.worker_identity == "firstmate-worker:task-none") | .project_identity) == "firstmate-project:none"' \
    "literal none project identity was decoded as missing"
  pass "empty backlogs and literal none identities follow tasks-axi contracts"
}

test_reader_source_repository_containment() {
  local world package private snapshot
  world=$(make_world reader-source-containment)
  package="$world/home/data/reader-source"
  private="$package/private"
  snapshot="$private/snapshot.json"
  mkdir -p "$package/bin" "$private"
  chmod 0700 "$private"
  git -C "$package" init -q
  cat > "$package/bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'count: 0'
printf '%s\n' 'tasks: 0 tasks in this backlog'
printf '%s\n' 'help[0]:'
SH
  chmod 0755 "$package/bin/tasks-axi"
  run_failure "must not be inside a source repository" env \
    PATH="$package/bin:$PATH" FM_HOME="$world/home" "$PRODUCER" \
      --workstack-root "$world/app" \
      --output "$snapshot"
  [ -z "$(find "$private" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "reader source containment created an output or temporary file"

  world=$(make_world reader-source-container)
  package="$world/home/data/reader-source"
  private="$package/private"
  snapshot="$private/snapshot.json"
  mkdir -p "$package/bin" "$private"
  chmod 0700 "$private"
  cat > "$package/bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'count: 0'
printf '%s\n' 'tasks: 0 tasks in this backlog'
printf '%s\n' 'help[0]:'
SH
  chmod 0755 "$package/bin/tasks-axi"
  run_failure "must not be inside a source repository" env \
    PATH="$package/bin:$PATH" FM_HOME="$world/home" "$PRODUCER" \
      --workstack-root "$world/app" \
      --output "$snapshot"
  [ -z "$(find "$private" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "reader container containment created an output or temporary file"
  pass "reader authorities participate in pre-write repository containment"
}

test_runtime_dependency_race_refuses() {
  local world runtime fakebin library replacement snapshot before inject output rc
  world=$(make_world runtime-dependency-race)
  runtime="$world/runtime"
  fakebin="$world/fakebin"
  library="$runtime/lib/libreader.dylib"
  replacement="$runtime/lib/libreader.replacement.dylib"
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  inject="$world/inject-runtime-race"
  mkdir -p "$runtime/bin" "$runtime/lib" "$fakebin" "$inject"
  cat > "$world/reader-runtime.c" <<'C'
#include <stdio.h>
extern const char *reader_output(void);
int main(void) { fputs(reader_output(), stdout); return 0; }
C
  cat > "$world/reader-empty.c" <<'C'
const char *reader_output(void) { return "count: 0\ntasks: 0 tasks in this backlog\nhelp[0]:\n"; }
C
  cat > "$world/reader-replacement.c" <<'C'
const char *reader_output(void) { return "count: 1\ntasks[1]{id,state,kind,repo,title}:\n  injected,queued,ship,alpha,private-title\nhelp[0]:\n"; }
C
  cc -dynamiclib -install_name "$library" "$world/reader-empty.c" -o "$library"
  cc -dynamiclib -install_name "$library" "$world/reader-replacement.c" -o "$replacement"
  cc "$world/reader-runtime.c" "$library" -o "$runtime/bin/node"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env node
SH
  chmod 0755 "$runtime/bin/node" "$fakebin/tasks-axi"
  PATH="$fakebin:$runtime/bin:/usr/bin:/bin" run_world "$world" >/dev/null \
    || fail "baseline generation with exact runtime dependencies failed"
  before=$(shasum -a 256 "$snapshot" | awk '{print $1}')
  cat > "$inject/sitecustomize.py" <<'PY'
import os
import subprocess

reader = os.environ["FM_TEST_TASKS_AXI"]
library = os.environ["FM_TEST_RUNTIME_LIBRARY"]
replacement = os.environ["FM_TEST_RUNTIME_REPLACEMENT"]
real_popen = subprocess.Popen
replaced = False

class GuardedPopen(real_popen):
    def __init__(self, args, *pargs, **kwargs):
        global replaced
        values = [os.fspath(value) for value in args]
        staged_reader = any(
            ".workstack-reader." in value and value.endswith("/package/tasks-axi")
            for value in values
        )
        if not replaced and staged_reader:
            os.replace(replacement, library)
            replaced = True
        super().__init__(args, *pargs, **kwargs)

subprocess.Popen = GuardedPopen
PY
  run_failure "source changed during observation" env \
    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$inject" \
    FM_TEST_TASKS_AXI="$fakebin/tasks-axi" \
    FM_TEST_RUNTIME_LIBRARY="$library" \
    FM_TEST_RUNTIME_REPLACEMENT="$replacement" \
    PATH="$fakebin:$runtime/bin:/usr/bin:/bin" FM_HOME="$world/home" "$PRODUCER" \
      --workstack-root "$world/app" \
      --project-root "gl-data-team-tickets=$world/tickets" \
      --project-root "data-team-management=$world/dtm" \
      --project-root "alpha=$world/alpha"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "runtime dependency race replaced the prior complete snapshot"

  cat > "$inject/sitecustomize.py" <<'PY'
import os
from pathlib import Path

alias_parent = os.environ["FM_TEST_RUNTIME_ALIAS_PARENT"]
real_resolve = Path.resolve


def guarded_resolve(self, *args, **kwargs):
    if os.fspath(self) == alias_parent:
        raise FileNotFoundError("runtime dependency alias disappeared")
    return real_resolve(self, *args, **kwargs)


Path.resolve = guarded_resolve
PY
  set +e
  output=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$inject" \
    FM_TEST_RUNTIME_ALIAS_PARENT="$runtime/lib" \
    PATH="$fakebin:$runtime/bin:/usr/bin:/bin" FM_HOME="$world/home" "$PRODUCER" \
      --workstack-root "$world/app" \
      --project-root "gl-data-team-tickets=$world/tickets" \
      --project-root "data-team-management=$world/dtm" \
      --project-root "alpha=$world/alpha" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "producer accepted a disappearing runtime alias"
  assert_contains "$output" "source changed during observation" \
    "runtime alias disappearance did not produce a bounded refusal"
  assert_not_contains "$output" "Traceback" \
    "runtime alias disappearance emitted an internal traceback"
  assert_not_contains "$output" "$runtime" \
    "runtime alias disappearance emitted a private runtime path"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "runtime alias disappearance replaced the prior complete snapshot"
  pass "runtime dependency races preserve the prior snapshot"
}

test_tasks_axi_reader_is_stdin_only_and_confined() {
  local world fakebin ambient_home secret marker network_marker port_file port server_pid snapshot
  world=$(make_world tasks-reader-confinement)
  fakebin="$world/fakebin"
  ambient_home="$world/ambient-home"
  secret="$world/private-task-identity"
  marker="$world/tasks-reader-write"
  network_marker="$world/tasks-reader-network"
  port_file="$world/tasks-reader-port"
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  mkdir -p "$fakebin" "$ambient_home/.tasks-axi"
  printf '%s\n' 'markdown.path = "ambient-secret-backlog.md"' \
    > "$ambient_home/.tasks-axi/config.toml"
  printf '%s\n' 'task-secret' > "$secret"
  python3 - "$port_file" "$network_marker" <<'PY' &
import pathlib
import socket
import sys

server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(1)
server.settimeout(2)
pathlib.Path(sys.argv[1]).write_text(str(server.getsockname()[1]))
try:
    connection, _ = server.accept()
except socket.timeout:
    pass
else:
    with connection:
        connection.recv(64)
    pathlib.Path(sys.argv[2]).write_text("connected")
finally:
    server.close()
PY
  server_pid=$!
  while [ ! -s "$port_file" ]; do sleep 0.01; done
  port=$(cat "$port_file")
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ -z "\${HOME:-}" ] || [ "\$PWD" != "\$HOME" ] || \
   [ -e "\$HOME/.tasks-axi/config.toml" ]; then
  exit 9
fi
identity=
IFS= read -r identity < '$secret' || identity=
printf '%s\n' touched > '$marker' 2>/dev/null || :
printf '%s\n' probe > /dev/tcp/127.0.0.1/$port 2>/dev/null || :
if [ -n "\$identity" ]; then
  printf '%s\n' 'count: 1'
  printf '%s\n' 'tasks[1]{id,state,kind,repo,title}:'
  printf '  %s,queued,ship,alpha,private-title\n' "\$identity"
else
  printf '%s\n' 'count: 0'
  printf '%s\n' 'tasks: 0 tasks in this backlog'
fi
printf '%s\n' 'help[0]:'
SH
  chmod 0755 "$fakebin/tasks-axi"
  cat > "$world/home/state/task-secret.meta" <<'META'
kind=ship
spawn_gen=spawn-task-secret
META
  HOME="$ambient_home" PATH="$fakebin:$PATH" run_world "$world" >/dev/null \
    || fail "confined stdin-only backlog reader could not return bounded identities"
  wait "$server_pid" || fail "backlog reader network probe server failed"
  [ ! -e "$marker" ] || fail "backlog reader wrote outside its boundary"
  [ ! -e "$network_marker" ] || fail "backlog reader opened a network connection"
  json_assert "$snapshot" \
    '(.worker_incarnations[] | select(.worker_identity == "firstmate-worker:task-secret") | .project_identity) == null' \
    "backlog reader read a private file outside its executable runtime"
  pass "backlog reader is confined to stdin and its executable runtime"
}

test_tasks_axi_package_race_refuses() {
  local world fakebin inject snapshot before
  world=$(make_world tasks-reader-race)
  fakebin="$world/fakebin"
  inject="$world/inject-reader-race"
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  mkdir -p "$fakebin" "$inject"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'count: 0'
printf '%s\n' 'tasks: 0 tasks in this backlog'
printf '%s\n' 'help[0]:'
SH
  chmod 0755 "$fakebin/tasks-axi"
  PATH="$fakebin:$PATH" run_world "$world" >/dev/null \
    || fail "baseline generation with retained reader authorities failed"
  before=$(shasum -a 256 "$snapshot" | awk '{print $1}')
  cat > "$inject/sitecustomize.py" <<'PY'
import os
import shutil
import subprocess

reader = os.environ["FM_TEST_TASKS_AXI"]
real_popen = subprocess.Popen
replaced = False


class GuardedPopen(real_popen):
    def __init__(self, args, *pargs, **kwargs):
        global replaced
        values = [os.fspath(value) for value in args]
        staged_reader = any(
            ".workstack-reader." in value and value.endswith("/package/tasks-axi")
            for value in values
        )
        if not replaced and staged_reader:
            replacement = reader + ".replacement"
            shutil.copy2(reader, replacement)
            os.replace(replacement, reader)
            replaced = True
        super().__init__(args, *pargs, **kwargs)


subprocess.Popen = GuardedPopen
PY
  run_failure "source changed during observation" env \
    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$inject" \
    FM_TEST_TASKS_AXI="$fakebin/tasks-axi" \
    PATH="$fakebin:$PATH" FM_HOME="$world/home" "$PRODUCER" \
      --workstack-root "$world/app" \
      --project-root "gl-data-team-tickets=$world/tickets" \
      --project-root "data-team-management=$world/dtm" \
      --project-root "alpha=$world/alpha"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "reader authority race replaced the prior complete snapshot"
  pass "reader package races preserve the prior snapshot"
}

test_reader_executes_captured_authority_and_absolute_shebang() {
  local world fakebin inject snapshot before
  world=$(make_world captured-reader-authority)
  fakebin="$world/fakebin"
  inject="$world/inject-captured-reader"
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  mkdir -p "$fakebin" "$inject"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/bin/bash
printf '%s\n' 'count: 0'
printf '%s\n' 'tasks: 0 tasks in this backlog'
printf '%s\n' 'help[0]:'
SH
  cat > "$fakebin/tasks-axi.replacement" <<'SH'
#!/bin/bash
printf '%s\n' 'count: 1'
printf '%s\n' 'tasks[1]{id,state,kind,repo,title}:'
printf '%s\n' '  injected,queued,ship,alpha,private-title'
printf '%s\n' 'help[0]:'
SH
  cat > "$fakebin/bash" <<'SH'
#!/bin/bash
printf '%s\n' 'count: 1'
printf '%s\n' 'tasks[1]{id,state,kind,repo,title}:'
printf '%s\n' '  injected,queued,ship,alpha,private-title'
printf '%s\n' 'help[0]:'
SH
  chmod 0755 "$fakebin/tasks-axi" "$fakebin/tasks-axi.replacement" "$fakebin/bash"
  cat > "$world/home/state/injected.meta" <<'META'
kind=ship
spawn_gen=spawn-injected
META
  cat > "$inject/sitecustomize.py" <<'PY'
import os
import subprocess

reader = os.environ["FM_TEST_TASKS_AXI"]
replacement = reader + ".replacement"
saved = reader + ".saved"
real_popen = subprocess.Popen
swapped = False


class GuardedPopen(real_popen):
    def __init__(self, args, *pargs, **kwargs):
        global swapped
        values = [os.fspath(value) for value in args]
        staged_reader = any(
            ".workstack-reader." in value and value.endswith("/package/tasks-axi")
            for value in values
        )
        if staged_reader and not swapped:
            os.replace(reader, saved)
            os.replace(replacement, reader)
            try:
                super().__init__(args, *pargs, **kwargs)
            finally:
                os.replace(reader, replacement)
                os.replace(saved, reader)
            swapped = True
            return
        super().__init__(args, *pargs, **kwargs)


subprocess.Popen = GuardedPopen
PY
  PATH="$fakebin:/usr/bin:/bin" run_world "$world" >/dev/null \
    || fail "the reader's absolute shebang runtime was not honored"
  before=$(shasum -a 256 "$snapshot" | awk '{print $1}')
  run_failure "source changed during observation" env \
    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$inject" \
    FM_TEST_TASKS_AXI="$fakebin/tasks-axi" \
    PATH="$fakebin:/usr/bin:/bin" FM_HOME="$world/home" "$PRODUCER" \
      --workstack-root "$world/app" \
      --project-root "gl-data-team-tickets=$world/tickets" \
      --project-root "data-team-management=$world/dtm" \
      --project-root "alpha=$world/alpha"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "temporary reader substitution replaced the prior snapshot"
  json_assert "$snapshot" \
    '(.worker_incarnations[] | select(.worker_identity == "firstmate-worker:injected") | .project_identity) == null' \
    "a temporarily substituted reader supplied a fabricated project relation"
  [ ! -e "$fakebin/tasks-axi.saved" ] \
    || fail "temporary reader substitution was not restored"
  [ -z "$(find "$world/home/data/workstack-compass" -name '.workstack-reader.*' -print -quit)" ] \
    || fail "captured reader staging data was retained"
  pass "captured reader authorities and absolute shebang runtimes are exact"
}

test_optional_source_appearance_during_observation_refuses() {
  local world snapshot before registry producer_pid rc
  world=$(make_world optional-source-race)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  run_world "$world" >/dev/null || fail "optional-source race baseline failed"
  before=$(shasum -a 256 "$snapshot" | awk '{print $1}')
  registry="$world/home/data/projects.md"
  rm "$registry"
  write_slow_model "$world/app"
  set +e
  run_world "$world" >/dev/null 2>&1 &
  producer_pid=$!
  set -e
  sleep 0.7
  printf '%s\n' '# appeared during observation' > "$registry"
  set +e
  wait "$producer_pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "producer accepted an optional source appearance"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "optional-source race changed the prior complete snapshot"
  pass "an optional source appearing mid-observation prevents publication"
}

test_source_change_during_observation_refuses() {
  local world snapshot before registry producer_pid rc
  world=$(make_world source-race)
  snapshot="$world/home/data/workstack-compass/snapshot.json"
  registry="$world/home/data/projects.md"
  run_world "$world" >/dev/null || fail "source-race baseline generation failed"
  before=$(shasum -a 256 "$snapshot" | awk '{print $1}')
  write_slow_model "$world/app"
  set +e
  run_world "$world" >/dev/null 2>&1 &
  producer_pid=$!
  set -e
  sleep 0.7
  printf '%s\n' '# changed during observation' >> "$registry"
  set +e
  wait "$producer_pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "producer accepted a source change before commit"
  [ "$(shasum -a 256 "$snapshot" | awk '{print $1}')" = "$before" ] \
    || fail "source race replaced the prior complete snapshot"
  pass "the final pre-commit proof preserves the prior raced snapshot"
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
test_nonexecutable_launcher_refuses_before_publication
test_executable_model_is_confined_and_copy_isolated
test_output_parent_relocation_refuses_without_source_write
test_default_parent_relocation_refuses_before_creation
test_publication_authority_relocation_cannot_write_source
test_repository_containment_refuses_before_output_writes
test_fifo_source_refuses_without_blocking_or_replacement
test_malformed_and_oversized_inputs_and_output_refuse
test_empty_backlog_and_literal_none_relation
test_reader_source_repository_containment
test_runtime_dependency_race_refuses
test_tasks_axi_reader_is_stdin_only_and_confined
test_tasks_axi_package_race_refuses
test_reader_executes_captured_authority_and_absolute_shebang
test_optional_source_appearance_during_observation_refuses
test_source_change_during_observation_refuses
test_private_application_model_integration
