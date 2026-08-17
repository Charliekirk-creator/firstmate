#!/usr/bin/env bash
# fm-work-identity.sh - exact, versioned project/plan/work-unit intake contract.
#
# This script is the single owner of the `fm-work-identity.v1` data contract,
# its validation rules, private storage, generated-instruction binding, metadata
# binding, and read-only projection shape. Other scripts consume this interface
# and must not parse, infer, or restate the contract.
#
# Public intake interface:
#   fm-work-identity.sh template <task-id>
#   fm-work-identity.sh record <task-id> --file <manifest.json>
#   fm-work-identity.sh verify <task-id>
#
# Internal consumers:
#   fm-work-identity.sh brief-block <task-id>
#   fm-work-identity.sh brief-publish <task-id> --file <draft.md>
#   fm-work-identity.sh project <task-id> [--brief <brief.md>] [--meta <task.meta>]
#   fm-work-identity.sh dispatch-binding <task-id> --brief <brief.md> [--meta <task.meta>]
#   fm-work-identity.sh dispatch-prepare <task-id> --brief <draft.md> --instructions-path <brief.md> --transaction <id> [--meta <task.meta> --prior-brief <brief.md>]
#   fm-work-identity.sh dispatch-commit <task-id> --brief <brief.md> --meta <task.meta> --transaction <id>
#   fm-work-identity.sh dispatch-abort <task-id> --transaction <id>
#   fm-work-identity.sh home-id
#   fm-work-identity.sh handoff-prepare <task-id> --to-home <absolute-home> --to-home-id <home-id> [--result]
#   fm-work-identity.sh handoff-stage <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-commit <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-abort <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-target-state <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-complete <task-id> --file <transfer.json|->
#   fm-work-identity.sh handoff-cancel <task-id> --file <transfer.json|->
#   fm-work-identity.sh validate-index --file <index.json|->
#   fm-work-identity.sh validate-projections --home <absolute-home> --home-id <home-id> --file <records.json|->
#   fm-work-identity.sh publication-run -- <command> [args...]
#   fm-work-identity.sh limits
#   fm-work-identity.sh record-max-bytes
#
# The canonical private sidecar is data/<task-id>/work-identity.json.
# `record` accepts a pretty or compact JSON manifest, validates it, canonicalizes
# it to one sorted compact JSON object plus one newline, and publishes it
# atomically. Repeating the same record is idempotent. Once one canonical
# record wins no-clobber publication, only the byte-identical record is accepted;
# a changed relation requires a new task identity rather than in-place mutation.
#
# Complete schema `fm-work-identity.v1`:
# {
#   "schema": "fm-work-identity.v1",
#   "binding": {"home": "<physical absolute FM_HOME>", "home_id": "<stable-home-id>", "task_id": "<task-id>"},
#   "initiative": {"namespace": "...", "kind": "...", "id": "...", "label": "..."},
#   "plan_id":    {"namespace": "...", "kind": "plan", "id": "...", "label": "..."},
#   "stage":      {"namespace": "...", "kind": "stage", "id": "...", "label": "..."},
#   "work_units": [{"namespace": "...", "kind": "work-unit", "id": "...", "label": "..."}],
#   "sources":    [{"namespace": "...", "kind": "...", "id": "...", "label": "..."}]
# }
#
# Every identity is the exact tuple (namespace, kind, id). `label` is mandatory
# display text paired with that tuple and never establishes identity.
# Closed namespace/kind roles:
#   initiative: work-aligner project|initiative; dtm project;
#               firstmate project|initiative
#   plan_id:    work-aligner plan; firstmate plan
#   stage:      work-aligner stage; firstmate stage
#   work_units: work-aligner work-unit; firstmate work-unit
#   sources:    work-aligner project|initiative|plan|stage|work-unit;
#               dtm project|issue; data-team-ticket ticket;
#               firstmate project|initiative|plan|stage|work-unit
# This keeps Work Aligner plan/work-unit ids, DTM project/issue ids, Data Team
# Ticket ids, and local Firstmate plan/work-unit ids in distinct namespaces.
#
# A task has exactly one initiative/plan/stage context and one or more exact
# work units and source identities. It is projected once as a worker with arrays
# of those units, so several units never multiply the worker count.
#
# Syntax and safety:
#   - new intake task ids use Firstmate's canonical creation grammar and are at most 64 bytes;
#     lifecycle reads retain Firstmate's path-safe legacy task grammar;
#   - ids are 1..240 ASCII bytes, begin alphanumeric, and use only
#     A-Z a-z 0-9 . _ : @ / # ~ -; path-like '.', '..', empty, leading, or
#     trailing slash segments are refused;
#   - labels are 1..160 characters, have no leading/trailing whitespace,
#     Unicode control or format characters, Unicode line separators, or Markdown
#     table/HTML/backslash metacharacters, and are never paths;
#   - work_units and sources each contain 1..20 identities;
#   - no exact identity tuple may occur twice anywhere in one record;
#   - the manifest and sidecar are bounded regular, non-symlink, single-link
#     files; task directories are direct non-symlink children of the configured
#     data directory;
#   - binding.home, binding.home_id, and binding.task_id must exactly match the
#     physical active home, its stable `main` or `secondmate:<id>` identity, and
#     command task id, so same-path remote copies, other cross-home copies, and
#     task-mismatched records are refused;
#   - backlog handoff uses durable source and target prepare records. New intake
#     and projection stop while ownership is prepared; destination publication,
#     source completion, and cancellation are exact-transfer idempotent steps;
#   - linked live tasks require matching schema/status/digest fields in metadata
#     and byte-matching digest and payload markers in generated instructions;
#   - absent records remain compatible and project explicitly as unlinked.
#
# Reads and records are local identity bookkeeping only. They never change task
# lifecycle state, assignments, a DTM item, GitHub, a Data Team Ticket, or a Work
# Aligner plan. No title, repository, branch, endpoint, worker name, timestamp,
# label, or status prose is ever consulted as a fallback relation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME_INPUT="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
SCHEMA=fm-work-identity.v1
HANDOFF_SCHEMA=fm-work-identity-handoff.v1
HANDOFF_STATE_SCHEMA=fm-work-identity-handoff-state.v1
DISPATCH_STATE_SCHEMA=fm-work-identity-dispatch-state.v1
MAX_BYTES=65536
HANDOFF_MAX_BYTES=$((MAX_BYTES + 8192))
MAX_ARRAY=20
MAX_PROJECTION_BYTES=$((MAX_BYTES + 2048))
MAX_PROJECTION_BATCH_BYTES=1048576
DIE_STATUS=1
FM_HOME_ID=
ACTIVE_IDENTITY_LOCK=
ACTIVE_IDENTITY_LOCK_HELD=0
ACTIVE_PUBLICATION_LOCK=
ACTIVE_PUBLICATION_LOCK_HELD=0
CONTRACT_INPUT_TMP=
VALIDATION_TMP=
MANIFEST_CAPTURE_TMP=
MANIFEST_CAPTURE_SOURCE=
MANIFEST_CAPTURE_IDENTITY=
SIDECAR_SNAPSHOT_TMP=
BRIEF_INPUT_TMP=
BRIEF_HASH=
BRIEF_VALIDATED_CAPTURE=
RETAIN_BRIEF_CAPTURE=0
PROJECTION_TMP=
DISPATCH_PRIOR_TMP=
DISPATCH_PRIOR_CLEANUP=0
TMP=

work_identity_cleanup() {
  local status=$?
  [ -z "${TMP:-}" ] || rm -f -- "$TMP" 2>/dev/null || true
  [ -z "${CONTRACT_INPUT_TMP:-}" ] || rm -f -- "$CONTRACT_INPUT_TMP" 2>/dev/null || true
  [ -z "${VALIDATION_TMP:-}" ] || rm -f -- "$VALIDATION_TMP" 2>/dev/null || true
  [ -z "${MANIFEST_CAPTURE_TMP:-}" ] || rm -f -- "$MANIFEST_CAPTURE_TMP" 2>/dev/null || true
  [ -z "${SIDECAR_SNAPSHOT_TMP:-}" ] || rm -f -- "$SIDECAR_SNAPSHOT_TMP" 2>/dev/null || true
  [ -z "${BRIEF_INPUT_TMP:-}" ] || rm -f -- "$BRIEF_INPUT_TMP" 2>/dev/null || true
  [ -z "${BRIEF_VALIDATED_CAPTURE:-}" ] || rm -f -- "$BRIEF_VALIDATED_CAPTURE" 2>/dev/null || true
  [ -z "${PROJECTION_TMP:-}" ] || rm -f -- "$PROJECTION_TMP" 2>/dev/null || true
  [ -z "${DISPATCH_PRIOR_TMP:-}" ] || rm -f -- "$DISPATCH_PRIOR_TMP" 2>/dev/null || true
  if [ "${DISPATCH_PRIOR_CLEANUP:-0}" -eq 1 ]; then
    DISPATCH_PRIOR_CLEANUP=0
    rm -f -- "${DISPATCH_PRIOR:-}" 2>/dev/null || true
  fi
  if [ "${ACTIVE_IDENTITY_LOCK_HELD:-0}" -eq 1 ]; then
    ACTIVE_IDENTITY_LOCK_HELD=0
    fm_lock_release "$ACTIVE_IDENTITY_LOCK" 2>/dev/null || true
  fi
  if [ "${ACTIVE_PUBLICATION_LOCK_HELD:-0}" -eq 1 ]; then
    ACTIVE_PUBLICATION_LOCK_HELD=0
    fm_lock_release "$ACTIVE_PUBLICATION_LOCK" 2>/dev/null || true
  fi
  return "$status"
}
trap work_identity_cleanup EXIT

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit "$DIE_STATUS"
}

resolve_existing_dir() {  # <name> <path>
  local name=$1 path=$2 resolved
  [ -d "$path" ] || die "$name directory is unavailable: $path"
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) \
    || die "$name directory cannot be resolved: $path"
  printf '%s\n' "$resolved"
}

FM_HOME_REAL=$(resolve_existing_dir FM_HOME "$FM_HOME_INPUT")
DATA_INPUT=${FM_DATA_OVERRIDE:-$FM_HOME_REAL/data}
STATE_INPUT=${FM_STATE_OVERRIDE:-$FM_HOME_REAL/state}
if [ -e "$DATA_INPUT" ] || [ -L "$DATA_INPUT" ]; then
  [ ! -L "$DATA_INPUT" ] || die "data directory is symlinked: $DATA_INPUT"
  DATA_REAL=$(resolve_existing_dir data "$DATA_INPUT")
else
  DATA_REAL=$DATA_INPUT
fi
if [ -e "$STATE_INPUT" ] || [ -L "$STATE_INPUT" ]; then
  [ ! -L "$STATE_INPUT" ] || die "state directory is symlinked: $STATE_INPUT"
  STATE_REAL=$(resolve_existing_dir state "$STATE_INPUT")
else
  STATE_REAL=$STATE_INPUT
fi

file_link_count() {  # <path>
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%l' "$1" 2>/dev/null
  else
    stat -c '%h' "$1" 2>/dev/null
  fi
}

file_size() {  # <path>
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%z' "$1" 2>/dev/null
  else
    stat -c '%s' "$1" 2>/dev/null
  fi
}

file_identity() {  # <path>
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%d:%i:%l:%z' "$1" 2>/dev/null
  else
    stat -c '%d:%i:%h:%s' "$1" 2>/dev/null
  fi
}

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

safe_regular_file() {  # <path> <label> [max-bytes]
  local path=$1 label=$2 max=${3:-$MAX_BYTES} links bytes
  [ ! -L "$path" ] || die "$label is symlinked: $path"
  [ -f "$path" ] || die "$label is not a regular file: $path"
  links=$(file_link_count "$path") || die "cannot inspect $label link count: $path"
  [ "$links" = 1 ] || die "$label is hardlinked: $path"
  bytes=$(file_size "$path") || die "cannot inspect $label size: $path"
  case "$bytes" in ''|*[!0-9]*) die "$label has an invalid size: $path" ;; esac
  [ "$bytes" -le "$max" ] || die "$label exceeds $max bytes: $path"
}

home_id_literal_valid() {  # <main|secondmate:id>
  local value=$1 id
  [ "$value" = main ] && return 0
  case "$value" in secondmate:*) id=${value#secondmate:} ;; *) return 1 ;; esac
  [ "${#id}" -le 128 ] || return 1
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

ensure_home_identity() {
  local marker id
  [ -z "$FM_HOME_ID" ] || return 0
  marker="$FM_HOME_REAL/.fm-secondmate-home"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    FM_HOME_ID=main
    return 0
  fi
  safe_regular_file "$marker" "secondmate home identity marker" 256
  id=$(cat "$marker") || die "cannot read secondmate home identity marker: $marker"
  printf '%s\n' "$id" | cmp -s "$marker" - \
    || die "secondmate home identity marker is not one exact line: $marker"
  home_id_literal_valid "secondmate:$id" \
    || die "secondmate home identity marker is malformed: $marker"
  FM_HOME_ID="secondmate:$id"
}

ensure_data_dir() {
  if [ -e "$DATA_INPUT" ] || [ -L "$DATA_INPUT" ]; then
    [ ! -L "$DATA_INPUT" ] || die "data directory is symlinked: $DATA_INPUT"
    [ -d "$DATA_INPUT" ] || die "data path is not a directory: $DATA_INPUT"
  else
    mkdir -p -- "$DATA_INPUT" || die "cannot create data directory: $DATA_INPUT"
  fi
  DATA_REAL=$(resolve_existing_dir data "$DATA_INPUT")
}

locate_task_dir() {  # <task-id>, read-only
  local id=$1 dir real
  if [ -e "$DATA_INPUT" ] || [ -L "$DATA_INPUT" ]; then
    [ ! -L "$DATA_INPUT" ] || die "data directory is symlinked: $DATA_INPUT"
    [ -d "$DATA_INPUT" ] || die "data path is not a directory: $DATA_INPUT"
    DATA_REAL=$(resolve_existing_dir data "$DATA_INPUT")
  fi
  dir="$DATA_REAL/$id"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ ! -L "$dir" ] || die "task data directory is symlinked: $dir"
    [ -d "$dir" ] || die "task data path is not a directory: $dir"
    real=$(resolve_existing_dir task-data "$dir")
    [ "$real" = "$DATA_REAL/$id" ] || die "task data directory escapes the configured data directory: $dir"
    TASK_DIR=$real
  else
    TASK_DIR=$dir
  fi
  SIDECAR="$TASK_DIR/work-identity.json"
  BRIEF_DEFAULT="$TASK_DIR/brief.md"
  SOURCE_HANDOFF="$TASK_DIR/work-identity-handoff-source.json"
  TARGET_HANDOFF="$TASK_DIR/work-identity-handoff-target.json"
  DISPATCH_STATE="$TASK_DIR/work-identity-dispatch.json"
  DISPATCH_PRIOR="$TASK_DIR/work-identity-dispatch-prior.md"
}

ensure_task_dir() {  # <task-id>
  local id=$1
  ensure_data_dir
  locate_task_dir "$id"
  if [ ! -d "$TASK_DIR" ]; then
    if ! mkdir -- "$TASK_DIR" 2>/dev/null; then
      [ -d "$TASK_DIR" ] && [ ! -L "$TASK_DIR" ] \
        || die "cannot create task data directory: $TASK_DIR"
    fi
    locate_task_dir "$id"
  fi
}

canonicalize_manifest() {  # <path> <task-id> [expected-home] [expected-home-id]
  local path=$1 task=$2 expected_home=${3:-$FM_HOME_REAL} expected_home_id=${4:-} out
  if [ -z "$expected_home_id" ]; then
    ensure_home_identity
    expected_home_id=$FM_HOME_ID
  fi
  home_id_literal_valid "$expected_home_id" || die "work identity home id is malformed: $expected_home_id"
  out=$(jq -e -S -c -s \
    --arg schema "$SCHEMA" \
    --arg home "$expected_home" \
    --arg home_id "$expected_home_id" \
    --arg task "$task" \
    --argjson max_array "$MAX_ARRAY" '
      def exact_keys($ks): (keys | sort) == ($ks | sort);
      def safe_id:
        type == "string" and (length >= 1 and length <= 240)
        and test("^[A-Za-z0-9][A-Za-z0-9._:@/#~-]*$")
        and (startswith("/") | not) and (endswith("/") | not)
        and (contains("//") | not)
        and (test("(^|/)\\.\\.?(/|$)") | not);
      def safe_label:
        type == "string" and (length >= 1 and length <= 160)
        and . == (gsub("^[[:space:]]+|[[:space:]]+$"; ""))
        and (test("[\\p{Cc}\\p{Cf}]") | not)
        and (([explode[] | select(
          . == 60 or . == 62 or . == 92 or . == 96 or . == 124
          or . == 8232 or . == 8233)] | length) == 0)
        and . != "." and . != "..";
      def identity:
        type == "object" and exact_keys(["namespace","kind","id","label"])
        and (.namespace | type == "string")
        and (.kind | type == "string")
        and (.id | safe_id)
        and (.label | safe_label);
      def key: [.namespace,.kind,.id] | join("\u001f");
      def allowed($pairs): . as $i | identity and ($pairs | index($i.namespace + ":" + $i.kind) != null);
      select(length == 1) | .[0] | . as $manifest | select(
      exact_keys(["schema","binding","initiative","plan_id","stage","work_units","sources"])
      and .schema == $schema
      and (.binding | type == "object" and exact_keys(["home","home_id","task_id"])
        and .home == $home and .home_id == $home_id and .task_id == $task)
      and (.initiative | allowed([
        "work-aligner:project","work-aligner:initiative","dtm:project",
        "firstmate:project","firstmate:initiative"]))
      and (.plan_id | allowed(["work-aligner:plan","firstmate:plan"]))
      and (.stage | allowed(["work-aligner:stage","firstmate:stage"]))
      and (.work_units | type == "array" and length >= 1 and length <= $max_array
        and all(.[]; allowed(["work-aligner:work-unit","firstmate:work-unit"])))
      and (.sources | type == "array" and length >= 1 and length <= $max_array
        and all(.[]; allowed([
          "work-aligner:project","work-aligner:initiative","work-aligner:plan",
          "work-aligner:stage","work-aligner:work-unit",
          "dtm:project","dtm:issue","data-team-ticket:ticket",
          "firstmate:project","firstmate:initiative","firstmate:plan",
          "firstmate:stage","firstmate:work-unit"])))
      and (([.initiative,.plan_id,.stage] + .work_units + .sources) as $all
        | ($all | map(key) | unique | length) == ($all | length))
      ) | $manifest
    ' "$path" 2>/dev/null) || die "manifest does not satisfy $SCHEMA"
  printf '%s\n' "$out"
}

capture_manifest() {  # <path>
  local path=$1 before after
  safe_regular_file "$path" "work identity manifest"
  before=$(file_identity "$path") || die "cannot inspect work identity manifest"
  MANIFEST_CAPTURE_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-manifest.XXXXXX") \
    || die "cannot capture work identity manifest"
  cp -- "$path" "$MANIFEST_CAPTURE_TMP" || die "cannot capture work identity manifest"
  after=$(file_identity "$path") || die "cannot reinspect work identity manifest"
  [ "$before" = "$after" ] && cmp -s "$path" "$MANIFEST_CAPTURE_TMP" \
    || die "work identity manifest changed while it was captured"
  safe_regular_file "$MANIFEST_CAPTURE_TMP" "captured work identity manifest"
  MANIFEST_CAPTURE_SOURCE=$path
  MANIFEST_CAPTURE_IDENTITY=$before
}

verify_manifest_capture() {
  local after
  safe_regular_file "$MANIFEST_CAPTURE_SOURCE" "work identity manifest"
  after=$(file_identity "$MANIFEST_CAPTURE_SOURCE") || die "cannot reinspect work identity manifest"
  [ "$after" = "$MANIFEST_CAPTURE_IDENTITY" ] \
    && cmp -s "$MANIFEST_CAPTURE_SOURCE" "$MANIFEST_CAPTURE_TMP" \
    || die "work identity manifest changed before publication"
}

validate_sidecar() {  # <path> <task-id> [expected-home] [expected-home-id]; sets WORK_CANONICAL/WORK_HASH
  local path=$1 task=$2 expected_home=${3:-$FM_HOME_REAL} expected_home_id=${4:-} before after canonical
  safe_regular_file "$path" "work identity record"
  before=$(file_identity "$path") || die "cannot inspect work identity record: $path"
  SIDECAR_SNAPSHOT_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-record.XXXXXX") \
    || die "cannot capture work identity record"
  cp -- "$path" "$SIDECAR_SNAPSHOT_TMP" || die "cannot capture work identity record: $path"
  after=$(file_identity "$path") || die "cannot reinspect work identity record: $path"
  [ "$before" = "$after" ] && cmp -s "$path" "$SIDECAR_SNAPSHOT_TMP" \
    || die "work identity record changed while it was captured: $path"
  safe_regular_file "$SIDECAR_SNAPSHOT_TMP" "captured work identity record"
  canonical=$(canonicalize_manifest "$SIDECAR_SNAPSHOT_TMP" "$task" "$expected_home" "$expected_home_id")
  if ! printf '%s\n' "$canonical" | cmp -s "$SIDECAR_SNAPSHOT_TMP" -; then
    die "work identity record is not canonical or has trailing data: $path"
  fi
  WORK_HASH=$(sha256_file "$SIDECAR_SNAPSHOT_TMP") || die "SHA-256 is unavailable for work identity record"
  case "$WORK_HASH" in ''|*[!A-Fa-f0-9]*) die "work identity SHA-256 is invalid" ;; esac
  [ "${#WORK_HASH}" -eq 64 ] || die "work identity SHA-256 has the wrong length"
  WORK_HASH=$(printf '%s' "$WORK_HASH" | tr 'A-F' 'a-f')
  after=$(file_identity "$path") || die "cannot reinspect work identity record: $path"
  [ "$before" = "$after" ] && cmp -s "$path" "$SIDECAR_SNAPSHOT_TMP" \
    || die "work identity record changed while it was validated: $path"
  rm -f -- "$SIDECAR_SNAPSHOT_TMP"
  SIDECAR_SNAPSHOT_TMP=
  WORK_CANONICAL=$canonical
}

meta_field_exact() {  # <meta> <key>; sets META_VALUE, 0 exact, 1 absent, 2 malformed
  local meta=$1 key=$2 count
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  case "$count" in
    0) META_VALUE=; return 1 ;;
    1) META_VALUE=$(grep "^${key}=" "$meta" | cut -d= -f2-); return 0 ;;
    *) META_VALUE=; return 2 ;;
  esac
}

validate_meta_binding() {  # <meta> <linked|unlinked> [hash] [brief-hash] [brief-path]
  local meta=$1 expected=$2 hash=${3:-} brief_hash=${4:-${BRIEF_HASH:-}} brief_path=${5:-} status schema recorded_hash recorded_brief_hash recorded_brief_path rc
  [ -e "$meta" ] || [ -L "$meta" ] || return 0
  safe_regular_file "$meta" "task metadata"
  rc=0; meta_field_exact "$meta" work_identity_status || rc=$?
  if [ "$rc" -eq 1 ]; then
    meta_field_exact "$meta" work_identity_schema >/dev/null 2>&1 && die "task metadata has a work identity schema without status: $meta"
    meta_field_exact "$meta" work_identity_sha256 >/dev/null 2>&1 && die "task metadata has a work identity digest without status: $meta"
    meta_field_exact "$meta" launch_brief_sha256 >/dev/null 2>&1 && die "task metadata has a launch brief digest without work identity status: $meta"
    [ "$expected" = unlinked ] || die "linked work identity is not bound by task metadata: $meta"
    META_PROVENANCE=legacy
    return 0
  fi
  [ "$rc" -eq 0 ] || die "task metadata has duplicate work identity status fields: $meta"
  status=$META_VALUE
  meta_field_exact "$meta" work_identity_schema || die "task metadata has no exact work identity schema: $meta"
  schema=$META_VALUE
  [ "$schema" = "$SCHEMA" ] || die "task metadata work identity schema mismatch: $meta"
  [ "$status" = "$expected" ] || die "task metadata work identity status mismatch: $meta"
  if [ "$expected" = linked ]; then
    meta_field_exact "$meta" work_identity_sha256 || die "linked task metadata has no exact work identity digest: $meta"
    recorded_hash=$META_VALUE
    [ "$recorded_hash" = "$hash" ] || die "stale work identity digest in task metadata: $meta"
  else
    rc=0; meta_field_exact "$meta" work_identity_sha256 || rc=$?
    [ "$rc" -eq 1 ] || die "unlinked task metadata must not carry a work identity digest: $meta"
  fi
  rc=0; meta_field_exact "$meta" launch_brief_sha256 || rc=$?
  case "$rc" in
    0)
      recorded_brief_hash=$META_VALUE
      [ -n "$brief_hash" ] && [ "$recorded_brief_hash" = "$brief_hash" ] \
        || die "stale or mismatched launch brief digest in task metadata: $meta"
      ;;
    1) [ -z "$brief_path" ] || die "task metadata has no launch brief digest: $meta" ;;
    *) die "task metadata has duplicate launch brief digest fields: $meta" ;;
  esac
  if [ -n "$brief_path" ]; then
    meta_field_exact "$meta" launch_brief \
      || die "task metadata has no exact launch brief path: $meta"
    recorded_brief_path=$META_VALUE
    [ "$recorded_brief_path" = "$brief_path" ] \
      || die "task metadata launch brief path mismatch: $meta"
  fi
  META_PROVENANCE=metadata
}

brief_contract_count() {  # <brief>
  grep -c '^Work identity contract:' "$1" 2>/dev/null || true
}

finish_brief_capture() {  # <source> <source-identity>
  local source=$1 before=$2 after
  BRIEF_HASH=$(sha256_file "$BRIEF_INPUT_TMP") || die "SHA-256 is unavailable for generated instructions"
  case "$BRIEF_HASH" in ''|*[!A-Fa-f0-9]*) die "generated instructions SHA-256 is invalid" ;; esac
  [ "${#BRIEF_HASH}" -eq 64 ] || die "generated instructions SHA-256 has the wrong length"
  BRIEF_HASH=$(printf '%s' "$BRIEF_HASH" | tr 'A-F' 'a-f')
  after=$(file_identity "$source") || die "cannot reinspect generated instructions: $source"
  [ "$before" = "$after" ] && cmp -s "$source" "$BRIEF_INPUT_TMP" \
    || die "generated instructions changed while they were validated: $source"
  if [ "$RETAIN_BRIEF_CAPTURE" -eq 1 ]; then
    BRIEF_VALIDATED_CAPTURE=$BRIEF_INPUT_TMP
    BRIEF_INPUT_TMP=
  else
    rm -f -- "$BRIEF_INPUT_TMP"
    BRIEF_INPUT_TMP=
  fi
}

validate_brief_binding() {  # <brief> <linked|unlinked> [hash] [canonical]
  local brief=$1 expected=$2 hash=${3:-} canonical=${4:-} count marker payload_count expected_marker before after
  BRIEF_HASH=
  [ -e "$brief" ] || [ -L "$brief" ] || { BRIEF_PROVENANCE=absent; return 0; }
  safe_regular_file "$brief" "generated instructions"
  before=$(file_identity "$brief") || die "cannot inspect generated instructions: $brief"
  BRIEF_INPUT_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-brief.XXXXXX") \
    || die "cannot capture generated instructions"
  cp -- "$brief" "$BRIEF_INPUT_TMP" || die "cannot capture generated instructions: $brief"
  after=$(file_identity "$brief") || die "cannot reinspect generated instructions: $brief"
  [ "$before" = "$after" ] && cmp -s "$brief" "$BRIEF_INPUT_TMP" \
    || die "generated instructions changed while they were captured: $brief"
  safe_regular_file "$BRIEF_INPUT_TMP" "captured generated instructions"
  count=$(brief_contract_count "$BRIEF_INPUT_TMP")
  if [ "$count" = 0 ]; then
    [ "$expected" = unlinked ] || die "linked work identity is missing from generated instructions: $brief"
    BRIEF_PROVENANCE=legacy
    finish_brief_capture "$brief" "$before"
    return 0
  fi
  [ "$count" = 1 ] || die "generated instructions contain duplicate work identity contracts: $brief"
  marker=$(grep '^Work identity contract:' "$BRIEF_INPUT_TMP")
  if [ "$expected" = linked ]; then
    expected_marker="Work identity contract: $SCHEMA sha256=$hash"
    [ "$marker" = "$expected_marker" ] || die "stale or mismatched work identity contract in generated instructions: $brief"
    payload_count=$(grep -c '^Work identity payload: ' "$BRIEF_INPUT_TMP" 2>/dev/null || true)
    [ "$payload_count" = 1 ] || die "generated instructions require one exact work identity payload: $brief"
    [ "$(grep '^Work identity payload: ' "$BRIEF_INPUT_TMP")" = "Work identity payload: $canonical" ] \
      || die "stale or mismatched work identity payload in generated instructions: $brief"
  else
    [ "$marker" = "Work identity contract: $SCHEMA unlinked" ] \
      || die "generated instructions claim a linked or unknown work identity without a record: $brief"
    payload_count=$(grep -c '^Work identity payload: ' "$BRIEF_INPUT_TMP" 2>/dev/null || true)
    [ "$payload_count" = 0 ] || die "unlinked generated instructions must not carry a work identity payload: $brief"
  fi
  BRIEF_PROVENANCE=generated-instructions
  finish_brief_capture "$brief" "$before"
}

validate_home_literal() {  # <absolute-home>
  local home=$1
  case "$home" in /*) ;; *) die "work identity home must be absolute: $home" ;; esac
  case "/$home/" in */../*|*/./*) die "work identity home contains traversal: $home" ;; esac
  case "$home" in *'//'*) die "work identity home contains an empty path component: $home" ;; esac
  case "$home" in *$'\n'*|*$'\r'*|*$'\t'*) die "work identity home contains control characters" ;; esac
}

capture_contract_input() {  # <path|-> <label> <max-bytes>; sets CONTRACT_INPUT/CONTRACT_INPUT_TMP
  local path=$1 label=$2 max=$3 bytes
  CONTRACT_INPUT_TMP=
  if [ "$path" = - ]; then
    CONTRACT_INPUT_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-input.XXXXXX") \
      || die "cannot create $label temporary file"
    head -c "$((max + 1))" > "$CONTRACT_INPUT_TMP" \
      || { rm -f -- "$CONTRACT_INPUT_TMP"; CONTRACT_INPUT_TMP=; die "cannot read $label"; }
    bytes=$(file_size "$CONTRACT_INPUT_TMP") || die "cannot inspect $label size"
    [ "$bytes" -le "$max" ] || die "$label exceeds $max bytes"
    CONTRACT_INPUT=$CONTRACT_INPUT_TMP
  else
    safe_regular_file "$path" "$label" "$max"
    CONTRACT_INPUT=$path
  fi
}

validate_projection_index() {  # <path>
  local path=$1 row task
  safe_regular_file "$path" "work identity projection index" "$MAX_PROJECTION_BATCH_BYTES"
  jq -e --arg schema "$SCHEMA" '
    . as $entries
    | ($entries | type) == "array"
    and (($entries | map(.task_id) | unique | length) == ($entries | length))
    and all($entries[];
      type == "object"
      and (keys | sort) == (["schema","sha256","status","task_id"] | sort)
      and (.task_id | type) == "string"
      and .schema == $schema
      and ((.status == "linked" and (.sha256 | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$")))
        or (.status == "unlinked" and .sha256 == null)))
  ' "$path" >/dev/null 2>&1 || die "projection index does not satisfy $SCHEMA"
  while IFS= read -r row; do
    task=$(printf '%s' "$row" | jq -er '.task_id') || die "projection index task id is malformed"
    fm_pr_task_id_valid "$task" || die "projection index has an invalid task id"
    printf '%s\n' "$task"
  done < <(jq -c '.[]' "$path")
}

validate_projection_set() {  # <path> <expected-home> <expected-home-id>
  local path=$1 expected_home=$2 expected_home_id=$3 row task status recorded_hash canonical tmp
  validate_home_literal "$expected_home"
  home_id_literal_valid "$expected_home_id" || die "projection home id is malformed"
  safe_regular_file "$path" "work identity projection set" "$MAX_PROJECTION_BATCH_BYTES"
  jq -e '
    . as $entries
    | ($entries | type) == "array"
    and (($entries | map(.task_id) | unique | length) == ($entries | length))
    and all($entries[];
      type == "object"
      and (keys | sort) == (["task_id","work_identity"] | sort)
      and (.task_id | type) == "string"
      and (.work_identity | type) == "object")
  ' "$path" >/dev/null 2>&1 || die "projection set does not satisfy $SCHEMA"
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-projection.XXXXXX") \
    || die "cannot create projection validation file"
  while IFS= read -r row; do
    task=$(printf '%s' "$row" | jq -er '.task_id') \
      || { rm -f -- "$tmp"; die "projection task id is malformed"; }
    fm_pr_task_id_valid "$task" \
      || { rm -f -- "$tmp"; die "projection has an invalid task id"; }
    status=$(printf '%s' "$row" | jq -er '.work_identity.status') \
      || { rm -f -- "$tmp"; die "projection status is malformed"; }
    case "$status" in
      linked)
        printf '%s' "$row" | jq -e -S -c \
          --arg schema "$SCHEMA" --arg home "$expected_home" --arg home_id "$expected_home_id" --arg task "$task" '
          .work_identity as $w
          | select(($w | keys | sort) == (["binding","initiative","plan_id","provenance","schema","sha256","sources","stage","status","work_units"] | sort))
          | select($w.status == "linked" and $w.schema == $schema)
          | select($w.binding == {home:$home,home_id:$home_id,task_id:$task})
          | select(($w.sha256 | type) == "string" and ($w.sha256 | test("^[0-9a-f]{64}$")))
          | select(($w.provenance | type) == "object"
              and ($w.provenance | keys | sort) == (["instructions","metadata","record"] | sort)
              and $w.provenance.record == "intake-sidecar"
              and (["absent","legacy","generated-instructions"] | index($w.provenance.instructions)) != null
              and (["absent","legacy","metadata"] | index($w.provenance.metadata)) != null)
          | {schema:$w.schema,binding:$w.binding,initiative:$w.initiative,plan_id:$w.plan_id,
             stage:$w.stage,work_units:$w.work_units,sources:$w.sources}
        ' > "$tmp" 2>/dev/null \
          || { rm -f -- "$tmp"; die "linked projection does not satisfy $SCHEMA"; }
        canonical=$(canonicalize_manifest "$tmp" "$task" "$expected_home" "$expected_home_id")
        printf '%s\n' "$canonical" | cmp -s "$tmp" - \
          || { rm -f -- "$tmp"; die "linked projection is not canonical"; }
        WORK_HASH=$(sha256_file "$tmp") || { rm -f -- "$tmp"; die "SHA-256 is unavailable for linked projection"; }
        recorded_hash=$(printf '%s' "$row" | jq -er '.work_identity.sha256') \
          || { rm -f -- "$tmp"; die "linked projection digest is malformed"; }
        [ "$WORK_HASH" = "$recorded_hash" ] \
          || { rm -f -- "$tmp"; die "linked projection digest is stale or mismatched"; }
        ;;
      unlinked)
        printf '%s' "$row" | jq -e \
          --arg schema "$SCHEMA" --arg home "$expected_home" --arg home_id "$expected_home_id" --arg task "$task" '
          .work_identity as $w
          | ($w | keys | sort) == (["binding","initiative","plan_id","provenance","reason","schema","sha256","sources","stage","status","work_units"] | sort)
          and $w.status == "unlinked" and $w.schema == $schema and $w.sha256 == null
          and $w.binding == {home:$home,home_id:$home_id,task_id:$task}
          and $w.initiative == null and $w.plan_id == null and $w.stage == null
          and $w.work_units == [] and $w.sources == []
          and (["explicitly-unlinked","legacy-no-record"] | index($w.reason)) != null
          and ($w.provenance | type) == "object"
          and ($w.provenance | keys | sort) == (["instructions","metadata","record"] | sort)
          and $w.provenance.record == "absent"
          and (["absent","legacy","generated-instructions"] | index($w.provenance.instructions)) != null
          and (["absent","legacy","metadata"] | index($w.provenance.metadata)) != null
        ' >/dev/null 2>&1 || { rm -f -- "$tmp"; die "unlinked projection does not satisfy $SCHEMA"; }
        ;;
      *) rm -f -- "$tmp"; die "projection status does not satisfy $SCHEMA" ;;
    esac
  done < <(jq -c '.[]' "$path")
  rm -f -- "$tmp"
}

ensure_lock_lib() {
  if ! type fm_lock_acquire_wait >/dev/null 2>&1; then
    STATE=$STATE_REAL
    # shellcheck source=bin/fm-wake-lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-wake-lib.sh"
  fi
}

publication_lock_acquire() {
  [ "$ACTIVE_PUBLICATION_LOCK_HELD" -eq 0 ] || return 0
  ensure_data_dir
  ensure_lock_lib
  ACTIVE_PUBLICATION_LOCK="$DATA_REAL/.work-identity-publication.lock"
  fm_lock_acquire_wait "$ACTIVE_PUBLICATION_LOCK"
  ACTIVE_PUBLICATION_LOCK_HELD=1
}

identity_lock_acquire() {  # <task-id>
  local task=$1
  ensure_task_dir "$task"
  ensure_lock_lib
  ACTIVE_IDENTITY_LOCK="$TASK_DIR/.work-identity.lock"
  fm_lock_acquire_wait "$ACTIVE_IDENTITY_LOCK"
  ACTIVE_IDENTITY_LOCK_HELD=1
}

identity_lock_release() {
  [ "$ACTIVE_IDENTITY_LOCK_HELD" -eq 1 ] || return 0
  ACTIVE_IDENTITY_LOCK_HELD=0
  fm_lock_release "$ACTIVE_IDENTITY_LOCK"
  ACTIVE_IDENTITY_LOCK=
}

identity_mutation_lock_acquire() {  # <task-id>
  publication_lock_acquire
  identity_lock_acquire "$1"
}

validate_handoff_envelope() {  # <path> <task-id>; sets HANDOFF_*
  local path=$1 task=$2 canonical source_task target_task material computed record validated_record record_hash
  canonical=$(jq -e -S -c -s --arg schema "$HANDOFF_SCHEMA" '
    def exact_keys($ks): (keys | sort) == ($ks | sort);
    select(length == 1) | .[0] | . as $transfer | select(
    type == "object" and exact_keys(["schema","transfer_id","source","target","identity"])
    and .schema == $schema
    and (.transfer_id | type == "string" and test("^[0-9a-f]{64}$"))
    and (.source | type == "object" and exact_keys(["home","home_id","task_id"])
      and (.home | type) == "string" and (.home_id | type) == "string" and (.task_id | type) == "string")
    and (.target | type == "object" and exact_keys(["home","home_id","task_id"])
      and (.home | type) == "string" and (.home_id | type) == "string" and (.task_id | type) == "string")
    and (.identity | type == "object" and exact_keys(["status","source_sha256","target_sha256","record"])
      and ((.status == "linked"
            and (.source_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
            and (.target_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
            and (.record | type) == "object")
        or (.status == "unlinked" and .source_sha256 == null
            and .target_sha256 == null and .record == null)))
    ) | $transfer
  ' "$path" 2>/dev/null) || die "handoff transfer does not satisfy $HANDOFF_SCHEMA"
  printf '%s\n' "$canonical" | cmp -s "$path" - \
    || die "handoff transfer is not canonical or has trailing data"
  HANDOFF_TRANSFER_ID=$(printf '%s' "$canonical" | jq -r '.transfer_id')
  HANDOFF_SOURCE_HOME=$(printf '%s' "$canonical" | jq -r '.source.home')
  HANDOFF_SOURCE_HOME_ID=$(printf '%s' "$canonical" | jq -r '.source.home_id')
  HANDOFF_TARGET_HOME=$(printf '%s' "$canonical" | jq -r '.target.home')
  HANDOFF_TARGET_HOME_ID=$(printf '%s' "$canonical" | jq -r '.target.home_id')
  source_task=$(printf '%s' "$canonical" | jq -r '.source.task_id')
  target_task=$(printf '%s' "$canonical" | jq -r '.target.task_id')
  [ "$source_task" = "$task" ] && [ "$target_task" = "$task" ] \
    || die "handoff transfer task binding is mismatched"
  fm_pr_task_id_valid "$task" || die "handoff transfer task id is invalid"
  validate_home_literal "$HANDOFF_SOURCE_HOME"
  validate_home_literal "$HANDOFF_TARGET_HOME"
  home_id_literal_valid "$HANDOFF_SOURCE_HOME_ID" || die "handoff source home id is malformed"
  home_id_literal_valid "$HANDOFF_TARGET_HOME_ID" || die "handoff target home id is malformed"
  [ "$HANDOFF_SOURCE_HOME" != "$HANDOFF_TARGET_HOME" ] \
    || [ "$HANDOFF_SOURCE_HOME_ID" != "$HANDOFF_TARGET_HOME_ID" ] \
    || die "handoff source and target identities match"
  HANDOFF_STATUS=$(printf '%s' "$canonical" | jq -r '.identity.status')
  HANDOFF_SOURCE_SHA=$(printf '%s' "$canonical" | jq -r '.identity.source_sha256 // ""')
  HANDOFF_TARGET_SHA=$(printf '%s' "$canonical" | jq -r '.identity.target_sha256 // ""')
  HANDOFF_RECORD=
  if [ "$HANDOFF_STATUS" = linked ]; then
    record=$(printf '%s' "$canonical" | jq -S -c '.identity.record') \
      || die "handoff linked record is malformed"
    validated_record=$(canonicalize_manifest <(printf '%s\n' "$record") "$task" \
      "$HANDOFF_TARGET_HOME" "$HANDOFF_TARGET_HOME_ID")
    [ "$validated_record" = "$record" ] || die "handoff linked record is not canonical"
    record_hash=$(printf '%s\n' "$record" | sha256_stream) \
      || die "SHA-256 is unavailable for handoff linked record"
    [ "$record_hash" = "$HANDOFF_TARGET_SHA" ] \
      || die "handoff target digest is stale or mismatched"
    HANDOFF_RECORD=$record
  fi
  material=$(printf '%s' "$canonical" | jq -S -c 'del(.transfer_id)') \
    || die "cannot canonicalize handoff transfer commitment"
  computed=$(printf '%s\n' "$material" | sha256_stream) \
    || die "SHA-256 is unavailable for handoff transfer"
  [ "$computed" = "$HANDOFF_TRANSFER_ID" ] || die "handoff transfer commitment is mismatched"
  HANDOFF_CANONICAL=$canonical
}

validate_handoff_text() {  # <canonical-transfer> <task-id>
  local text=$1 task=$2
  VALIDATION_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-transfer.XXXXXX") \
    || die "cannot create handoff transfer validation file"
  printf '%s\n' "$text" > "$VALIDATION_TMP" || die "cannot write handoff transfer validation file"
  validate_handoff_envelope "$VALIDATION_TMP" "$task"
  rm -f -- "$VALIDATION_TMP"
  VALIDATION_TMP=
}

handoff_state_json() {  # <source|target> <prepared|completed> <transfer>
  jq -n -S -c --arg schema "$HANDOFF_STATE_SCHEMA" --arg role "$1" --arg state "$2" \
    --argjson transfer "$3" '{schema:$schema,role:$role,state:$state,transfer:$transfer}'
}

read_handoff_state() {  # <path> <source|target>; sets HANDOFF_STATE/HANDOFF_TRANSFER
  local path=$1 role=$2 wrapper transfer task
  safe_regular_file "$path" "work identity handoff state" "$HANDOFF_MAX_BYTES"
  wrapper=$(jq -e -S -c -s --arg schema "$HANDOFF_STATE_SCHEMA" --arg role "$role" '
    def exact_keys($ks): (keys | sort) == ($ks | sort);
    select(length == 1) | .[0] | . as $wrapper | select(
    type == "object" and exact_keys(["schema","role","state","transfer"])
    and .schema == $schema and .role == $role
    and (if $role == "source" then (.state == "prepared" or .state == "completed")
         else (.state == "prepared" or .state == "completed") end)
    and (.transfer | type) == "object"
    ) | $wrapper
  ' "$path" 2>/dev/null) || die "work identity handoff state is malformed: $path"
  printf '%s\n' "$wrapper" | cmp -s "$path" - \
    || die "work identity handoff state is not canonical: $path"
  transfer=$(printf '%s' "$wrapper" | jq -S -c '.transfer')
  task=$(printf '%s' "$transfer" | jq -r '.source.task_id')
  validate_handoff_text "$transfer" "$task"
  HANDOFF_STATE=$(printf '%s' "$wrapper" | jq -r '.state')
  HANDOFF_TRANSFER=$HANDOFF_CANONICAL
}

write_handoff_state() {  # <path> <source|target> <prepared|completed> <transfer>
  local path=$1 role=$2 state=$3 transfer=$4 payload
  payload=$(handoff_state_json "$role" "$state" "$transfer") \
    || die "cannot build work identity handoff state"
  TMP=$(umask 077; mktemp "$TASK_DIR/.work-identity-handoff.XXXXXX") \
    || die "cannot create work identity handoff state"
  printf '%s\n' "$payload" > "$TMP" || die "cannot write work identity handoff state"
  chmod 600 "$TMP" || die "cannot protect work identity handoff state"
  mv -f -- "$TMP" "$path" || die "cannot publish work identity handoff state"
  TMP=
}

dispatch_transaction_valid() {
  case "$1" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

dispatch_instructions_path_valid() {
  local path=$1 parent
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  parent=$(CDPATH='' cd -- "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  [ "$parent" = "$STATE_REAL" ]
}

read_dispatch_state() {  # <task-id>
  local task=$1 wrapper
  safe_regular_file "$DISPATCH_STATE" "work identity dispatch state" "$HANDOFF_MAX_BYTES"
  wrapper=$(jq -e -S -c -s --arg schema "$DISPATCH_STATE_SCHEMA" --arg contract "$SCHEMA" --arg task "$task" '
    def exact_keys($ks): (keys | sort) == ($ks | sort);
    select(length == 1) | .[0] | . as $wrapper | select(
      type == "object"
      and exact_keys(["schema","state","transaction_id","binding","instructions","identity","replacement","previous_instructions_sha256"])
      and .schema == $schema and (.state == "prepared" or .state == "completed")
      and (.transaction_id | type) == "string"
      and (.binding | type == "object" and exact_keys(["home","home_id","task_id"])
        and (.home | type) == "string" and (.home_id | type) == "string" and .task_id == $task)
      and (.instructions | type == "object" and exact_keys(["path","sha256"])
        and (.path | type) == "string" and (.sha256 | type) == "string"
        and (.sha256 | test("^[0-9a-f]{64}$")))
      and (.identity | type == "object" and exact_keys(["schema","status","sha256"])
        and .schema == $contract
        and ((.status == "linked" and (.sha256 | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$")))
          or (.status == "unlinked" and .sha256 == null)))
      and (.replacement | type) == "boolean"
      and ((.replacement == true and (.previous_instructions_sha256 | type) == "string"
            and (.previous_instructions_sha256 | test("^[0-9a-f]{64}$")))
        or (.replacement == false and .previous_instructions_sha256 == null))
    ) | $wrapper
  ' "$DISPATCH_STATE" 2>/dev/null) || die "work identity dispatch state is malformed: $DISPATCH_STATE"
  printf '%s\n' "$wrapper" | cmp -s "$DISPATCH_STATE" - \
    || die "work identity dispatch state is not canonical: $DISPATCH_STATE"
  DISPATCH_STATUS=$(printf '%s' "$wrapper" | jq -r '.state')
  DISPATCH_TRANSACTION=$(printf '%s' "$wrapper" | jq -r '.transaction_id')
  DISPATCH_HOME=$(printf '%s' "$wrapper" | jq -r '.binding.home')
  DISPATCH_HOME_ID=$(printf '%s' "$wrapper" | jq -r '.binding.home_id')
  DISPATCH_INSTRUCTIONS=$(printf '%s' "$wrapper" | jq -r '.instructions.path')
  DISPATCH_INSTRUCTIONS_SHA=$(printf '%s' "$wrapper" | jq -r '.instructions.sha256')
  DISPATCH_IDENTITY_STATUS=$(printf '%s' "$wrapper" | jq -r '.identity.status')
  DISPATCH_IDENTITY_SHA=$(printf '%s' "$wrapper" | jq -r '.identity.sha256 // ""')
  DISPATCH_REPLACEMENT=$(printf '%s' "$wrapper" | jq -r '.replacement')
  DISPATCH_PREVIOUS_SHA=$(printf '%s' "$wrapper" | jq -r '.previous_instructions_sha256 // ""')
  ensure_home_identity
  [ "$DISPATCH_HOME" = "$FM_HOME_REAL" ] && [ "$DISPATCH_HOME_ID" = "$FM_HOME_ID" ] \
    || die "work identity dispatch home binding is mismatched"
  dispatch_transaction_valid "$DISPATCH_TRANSACTION" \
    || die "work identity dispatch transaction is malformed"
  dispatch_instructions_path_valid "$DISPATCH_INSTRUCTIONS" \
    || die "work identity dispatch instructions path is unsafe"
  DISPATCH_CANONICAL=$wrapper
}

write_dispatch_state() {  # <prepared|completed> <task> <transaction> <path> <brief-sha> <linked|unlinked> <identity-sha> <replacement> <previous-sha>
  local state=$1 task=$2 transaction=$3 path=$4 brief_sha=$5 identity_status=$6 identity_sha=$7 replacement=$8 previous_sha=$9 payload
  ensure_home_identity
  payload=$(jq -n -S -c \
    --arg schema "$DISPATCH_STATE_SCHEMA" --arg state "$state" --arg transaction "$transaction" \
    --arg home "$FM_HOME_REAL" --arg home_id "$FM_HOME_ID" --arg task "$task" \
    --arg path "$path" --arg brief_sha "$brief_sha" --arg contract "$SCHEMA" \
    --arg identity_status "$identity_status" --arg identity_sha "$identity_sha" \
    --argjson replacement "$replacement" --arg previous_sha "$previous_sha" '
      {schema:$schema,state:$state,transaction_id:$transaction,
       binding:{home:$home,home_id:$home_id,task_id:$task},
       instructions:{path:$path,sha256:$brief_sha},
       identity:{schema:$contract,status:$identity_status,
         sha256:(if $identity_status == "linked" then $identity_sha else null end)},
       replacement:$replacement,
       previous_instructions_sha256:(if $replacement then $previous_sha else null end)}') \
    || die "cannot build work identity dispatch state"
  TMP=$(umask 077; mktemp "$TASK_DIR/.work-identity-dispatch.XXXXXX") \
    || die "cannot create work identity dispatch state"
  printf '%s\n' "$payload" > "$TMP" || die "cannot write work identity dispatch state"
  chmod 600 "$TMP" || die "cannot protect work identity dispatch state"
  mv -f -- "$TMP" "$DISPATCH_STATE" || die "cannot publish work identity dispatch state"
  TMP=
}

validate_completed_dispatch() {  # <task-id>
  local task=$1 meta projection meta_arg=
  [ "$DISPATCH_STATUS" = completed ] || die "work identity dispatch is incomplete for task $task"
  meta="$STATE_REAL/$task.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then meta_arg=$meta; fi
  if [ -e "$DISPATCH_INSTRUCTIONS" ] || [ -L "$DISPATCH_INSTRUCTIONS" ]; then
    capture_identity_projection_locked "$task" "$DISPATCH_INSTRUCTIONS" \
      "$meta_arg" "$DISPATCH_INSTRUCTIONS"
    projection=$IDENTITY_PROJECTION
    [ "$BRIEF_HASH" = "$DISPATCH_INSTRUCTIONS_SHA" ] \
      || die "completed dispatch instructions digest is stale or mismatched"
    [ "$(printf '%s' "$projection" | jq -r '.status')" = "$DISPATCH_IDENTITY_STATUS" ] \
      || die "completed dispatch identity status is stale or mismatched"
    [ "$(printf '%s' "$projection" | jq -r '.sha256 // ""')" = "$DISPATCH_IDENTITY_SHA" ] \
      || die "completed dispatch identity digest is stale or mismatched"
  elif [ -e "$meta" ] || [ -L "$meta" ]; then
    die "completed dispatch instructions are absent for task $task"
  fi
}

reject_handoff_guard() {  # <task-id>
  local task=$1
  if [ -e "$SOURCE_HANDOFF" ] || [ -L "$SOURCE_HANDOFF" ]; then
    read_handoff_state "$SOURCE_HANDOFF" source
    die "work identity ownership was handed off for task $task"
  fi
  if [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ]; then
    read_handoff_state "$TARGET_HANDOFF" target
    [ "$HANDOFF_STATE" = completed ] \
      || die "work identity ownership handoff is incomplete for task $task"
    handoff_target_matches_current
    validate_committed_target "$task"
  fi
}

reject_dispatch_guard() {  # <task-id>
  local task=$1
  if [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ]; then
    read_dispatch_state "$task"
    [ "$DISPATCH_STATUS" = completed ] \
      || die "work identity dispatch is incomplete for task $task"
    validate_completed_dispatch "$task"
  fi
}

reject_ownership_guard() {  # <task-id>
  reject_handoff_guard "$1"
  reject_dispatch_guard "$1"
}

reject_dispatch_for_handoff() {  # <task-id>
  local task=$1 meta="$STATE_REAL/$1.meta"
  if [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ]; then
    read_dispatch_state "$task"
    [ "$DISPATCH_STATUS" = completed ] \
      || die "task $task has an in-progress work identity dispatch"
  fi
  [ ! -e "$meta" ] && [ ! -L "$meta" ] \
    || die "task $task has dispatch metadata and cannot be handed off as backlog"
}

validate_source_transfer() {  # <task-id>; HANDOFF_* already loaded
  local task=$1 meta rebound rebound_hash
  ensure_home_identity
  [ "$HANDOFF_SOURCE_HOME" = "$FM_HOME_REAL" ] && [ "$HANDOFF_SOURCE_HOME_ID" = "$FM_HOME_ID" ] \
    || die "handoff source binding does not match the active home"
  meta="$STATE_REAL/$task.meta"
  if [ "$HANDOFF_STATUS" = linked ]; then
    [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ] || die "linked handoff source record is absent"
    validate_sidecar "$SIDECAR" "$task"
    [ "$WORK_HASH" = "$HANDOFF_SOURCE_SHA" ] || die "handoff source digest is stale or mismatched"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" linked "$WORK_HASH" "$WORK_CANONICAL"
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" linked "$WORK_HASH"
    rebound=$(printf '%s' "$WORK_CANONICAL" | jq -S -c \
      --arg home "$HANDOFF_TARGET_HOME" --arg home_id "$HANDOFF_TARGET_HOME_ID" \
      '.binding.home = $home | .binding.home_id = $home_id') \
      || die "cannot rebind work identity for handoff"
    [ "$rebound" = "$HANDOFF_RECORD" ] || die "handoff target record no longer matches its source"
    rebound_hash=$(printf '%s\n' "$rebound" | sha256_stream) \
      || die "SHA-256 is unavailable for rebound work identity"
    [ "$rebound_hash" = "$HANDOFF_TARGET_SHA" ] || die "handoff target digest is mismatched"
  else
    [ ! -e "$SIDECAR" ] && [ ! -L "$SIDECAR" ] || die "unlinked handoff source gained a linked record"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" unlinked
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" unlinked
  fi
}

build_handoff_transfer() {  # <task-id> <target-home> <target-home-id>; sets HANDOFF_CANONICAL
  local task=$1 target_home=$2 target_home_id=$3 meta status source_hash target_hash record material transfer_id
  ensure_home_identity
  meta="$STATE_REAL/$task.meta"
  if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    validate_sidecar "$SIDECAR" "$task"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" linked "$WORK_HASH" "$WORK_CANONICAL"
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" linked "$WORK_HASH"
    status=linked
    source_hash=$WORK_HASH
    record=$(printf '%s' "$WORK_CANONICAL" | jq -S -c \
      --arg home "$target_home" --arg home_id "$target_home_id" \
      '.binding.home = $home | .binding.home_id = $home_id') \
      || die "cannot rebind work identity for handoff"
    canonicalize_manifest <(printf '%s\n' "$record") "$task" "$target_home" "$target_home_id" >/dev/null
    target_hash=$(printf '%s\n' "$record" | sha256_stream) \
      || die "SHA-256 is unavailable for handoff target record"
  else
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" unlinked
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" unlinked
    status=unlinked
    source_hash=
    target_hash=
    record=null
  fi
  material=$(jq -n -S -c \
    --arg schema "$HANDOFF_SCHEMA" --arg source_home "$FM_HOME_REAL" --arg source_home_id "$FM_HOME_ID" \
    --arg target_home "$target_home" --arg target_home_id "$target_home_id" --arg task "$task" \
    --arg status "$status" --arg source_hash "$source_hash" --arg target_hash "$target_hash" \
    --argjson record "$record" '
      {schema:$schema,
       source:{home:$source_home,home_id:$source_home_id,task_id:$task},
       target:{home:$target_home,home_id:$target_home_id,task_id:$task},
       identity:{status:$status,
         source_sha256:(if $status == "linked" then $source_hash else null end),
         target_sha256:(if $status == "linked" then $target_hash else null end),
         record:(if $status == "linked" then $record else null end)}}') \
    || die "cannot build work identity handoff transfer"
  transfer_id=$(printf '%s\n' "$material" | sha256_stream) \
    || die "SHA-256 is unavailable for work identity handoff"
  HANDOFF_CANONICAL=$(printf '%s' "$material" | jq -S -c --arg transfer_id "$transfer_id" '. + {transfer_id:$transfer_id}') \
    || die "cannot finalize work identity handoff transfer"
  validate_handoff_text "$HANDOFF_CANONICAL" "$task"
}

emit_handoff_prepare() {
  local mode=$1 created=$2 transfer=$3
  if [ "$mode" = result ]; then
    jq -n -S -c --argjson created "$created" --argjson transfer "$transfer" \
      '{created:$created,transfer:$transfer}'
  else
    printf '%s\n' "$transfer"
  fi
}

handoff_prepare() {  # <task-id> <target-home> <target-home-id> [transfer|result]
  local task=$1 target_home=$2 target_home_id=$3 mode=${4:-transfer}
  validate_home_literal "$target_home"
  home_id_literal_valid "$target_home_id" || die "work identity handoff target home id is malformed"
  ensure_home_identity
  [ "$target_home" != "$FM_HOME_REAL" ] || [ "$target_home_id" != "$FM_HOME_ID" ] \
    || die "work identity handoff target matches the active home"
  identity_mutation_lock_acquire "$task"
  reject_dispatch_for_handoff "$task"
  if [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ]; then
    read_handoff_state "$TARGET_HANDOFF" target
    [ "$HANDOFF_STATE" = completed ] \
      || die "task $task has an incomplete incoming work identity handoff"
    handoff_target_matches_current
    validate_committed_target "$task"
  fi
  if [ -e "$SOURCE_HANDOFF" ] || [ -L "$SOURCE_HANDOFF" ]; then
    read_handoff_state "$SOURCE_HANDOFF" source
    [ "$HANDOFF_TARGET_HOME" = "$target_home" ] && [ "$HANDOFF_TARGET_HOME_ID" = "$target_home_id" ] \
      || die "task $task is already prepared for a different handoff target"
    validate_source_transfer "$task"
    emit_handoff_prepare "$mode" false "$HANDOFF_TRANSFER"
    return 0
  fi
  build_handoff_transfer "$task" "$target_home" "$target_home_id"
  write_handoff_state "$SOURCE_HANDOFF" source prepared "$HANDOFF_CANONICAL"
  emit_handoff_prepare "$mode" true "$HANDOFF_CANONICAL"
}

handoff_target_matches_current() {
  ensure_home_identity
  [ "$HANDOFF_TARGET_HOME" = "$FM_HOME_REAL" ] && [ "$HANDOFF_TARGET_HOME_ID" = "$FM_HOME_ID" ] \
    || die "handoff target binding does not match the active home"
}

handoff_stage() {  # <task-id> <transfer-path>
  local task=$1 path=$2 requested meta
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  handoff_target_matches_current
  identity_mutation_lock_acquire "$task"
  reject_dispatch_for_handoff "$task"
  if [ -e "$SOURCE_HANDOFF" ] || [ -L "$SOURCE_HANDOFF" ]; then
    read_handoff_state "$SOURCE_HANDOFF" source
    die "handoff target task $task is already owned by an outgoing transfer"
  fi
  if [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ]; then
    read_handoff_state "$TARGET_HANDOFF" target
    [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task has a different prepared incoming handoff"
    return 0
  fi
  validate_handoff_text "$requested" "$task"
  meta="$STATE_REAL/$task.meta"
  if [ "$HANDOFF_STATUS" = linked ]; then
    if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
      validate_sidecar "$SIDECAR" "$task"
      [ "$WORK_HASH" = "$HANDOFF_TARGET_SHA" ] && [ "$WORK_CANONICAL" = "$HANDOFF_RECORD" ] \
        || die "handoff target already has a different linked record"
      [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
        || validate_brief_binding "$BRIEF_DEFAULT" linked "$WORK_HASH" "$WORK_CANONICAL"
      [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" linked "$WORK_HASH"
    elif [ -e "$BRIEF_DEFAULT" ] || [ -L "$BRIEF_DEFAULT" ] || [ -e "$meta" ] || [ -L "$meta" ]; then
      die "linked handoff identity must arrive before destination instructions and metadata"
    fi
  else
    [ ! -e "$SIDECAR" ] && [ ! -L "$SIDECAR" ] || die "unlinked handoff target already has a linked record"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" unlinked
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" unlinked
  fi
  write_handoff_state "$TARGET_HANDOFF" target prepared "$requested"
}

validate_committed_target() {  # <task-id>; HANDOFF_* loaded
  local task=$1 meta
  meta="$STATE_REAL/$task.meta"
  BRIEF_HASH=
  if [ "$HANDOFF_STATUS" = linked ]; then
    [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ] || die "committed handoff target linked record is absent"
    validate_sidecar "$SIDECAR" "$task"
    [ "$WORK_HASH" = "$HANDOFF_TARGET_SHA" ] && [ "$WORK_CANONICAL" = "$HANDOFF_RECORD" ] \
      || die "committed handoff target linked record is conflicting"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" linked "$WORK_HASH" "$WORK_CANONICAL"
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" linked "$WORK_HASH"
  else
    [ ! -e "$SIDECAR" ] && [ ! -L "$SIDECAR" ] || die "committed unlinked handoff target gained a linked record"
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || validate_brief_binding "$BRIEF_DEFAULT" unlinked
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || validate_meta_binding "$meta" unlinked
  fi
}

publish_handoff_sidecar() {  # <task-id>; HANDOFF_RECORD/HANDOFF_TARGET_SHA loaded, lock held
  local task=$1
  if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    validate_sidecar "$SIDECAR" "$task"
    [ "$WORK_HASH" = "$HANDOFF_TARGET_SHA" ] && [ "$WORK_CANONICAL" = "$HANDOFF_RECORD" ] \
      || die "handoff target linked record is conflicting"
    return 0
  fi
  TMP=$(umask 077; mktemp "$TASK_DIR/.work-identity.XXXXXX") \
    || die "cannot create handoff work identity record"
  printf '%s\n' "$HANDOFF_RECORD" > "$TMP" || die "cannot write handoff work identity record"
  validate_sidecar "$TMP" "$task"
  if ln "$TMP" "$SIDECAR" 2>/dev/null; then
    rm -f -- "$TMP"
    TMP=
  else
    rm -f -- "$TMP"
    TMP=
    [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ] || die "cannot publish handoff work identity record"
  fi
  validate_sidecar "$SIDECAR" "$task"
  [ "$WORK_HASH" = "$HANDOFF_TARGET_SHA" ] && [ "$WORK_CANONICAL" = "$HANDOFF_RECORD" ] \
    || die "published handoff work identity record is conflicting"
}

handoff_commit() {  # <task-id> <transfer-path>
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  handoff_target_matches_current
  identity_mutation_lock_acquire "$task"
  [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ] \
    || die "task $task has no prepared incoming handoff"
  read_handoff_state "$TARGET_HANDOFF" target
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different incoming handoff"
  if [ "$HANDOFF_STATE" = completed ]; then
    validate_committed_target "$task"
    return 0
  fi
  if [ "$HANDOFF_STATUS" = linked ]; then
    publish_handoff_sidecar "$task"
  fi
  validate_committed_target "$task"
  write_handoff_state "$TARGET_HANDOFF" target completed "$requested"
}

handoff_abort() {  # <task-id> <transfer-path>; 4 means target is already committed
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  handoff_target_matches_current
  identity_mutation_lock_acquire "$task"
  if [ ! -e "$TARGET_HANDOFF" ] && [ ! -L "$TARGET_HANDOFF" ]; then
    if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
      [ "$HANDOFF_STATUS" = linked ] || die "unlinked handoff target has a linked record"
      validate_sidecar "$SIDECAR" "$task"
      [ "$WORK_HASH" = "$HANDOFF_TARGET_SHA" ] && [ "$WORK_CANONICAL" = "$HANDOFF_RECORD" ] \
        || die "committed handoff target linked record is conflicting"
      return 4
    fi
    return 0
  fi
  read_handoff_state "$TARGET_HANDOFF" target
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different incoming handoff"
  if [ "$HANDOFF_STATE" = completed ]; then
    validate_committed_target "$task"
    return 4
  fi
  if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    [ "$HANDOFF_STATUS" = linked ] || die "unlinked handoff target gained a linked record"
    validate_sidecar "$SIDECAR" "$task"
    [ "$WORK_HASH" = "$HANDOFF_TARGET_SHA" ] && [ "$WORK_CANONICAL" = "$HANDOFF_RECORD" ] \
      || die "committed handoff target linked record is conflicting"
    write_handoff_state "$TARGET_HANDOFF" target completed "$requested"
    return 4
  fi
  rm -f -- "$TARGET_HANDOFF" || die "cannot abort handoff target state"
}

handoff_target_state() {  # <task-id> <transfer-path>
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  handoff_target_matches_current
  identity_mutation_lock_acquire "$task"
  if [ ! -e "$TARGET_HANDOFF" ] && [ ! -L "$TARGET_HANDOFF" ]; then
    if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
      [ "$HANDOFF_STATUS" = linked ] || die "unlinked handoff target has a linked record"
      validate_sidecar "$SIDECAR" "$task"
      [ "$WORK_HASH" = "$HANDOFF_TARGET_SHA" ] && [ "$WORK_CANONICAL" = "$HANDOFF_RECORD" ] \
        || die "committed handoff target linked record is conflicting"
      validate_committed_target "$task"
      write_handoff_state "$TARGET_HANDOFF" target completed "$requested"
      printf 'completed\n'
    else
      printf 'absent\n'
    fi
    return 0
  fi
  read_handoff_state "$TARGET_HANDOFF" target
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different incoming handoff"
  if [ "$HANDOFF_STATE" = completed ]; then
    validate_committed_target "$task"
    printf 'completed\n'
    return 0
  fi
  if [ "$HANDOFF_STATUS" = linked ] && { [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; }; then
    validate_committed_target "$task"
    write_handoff_state "$TARGET_HANDOFF" target completed "$requested"
    printf 'completed\n'
    return 0
  fi
  printf 'prepared\n'
}

handoff_complete() {  # <task-id> <transfer-path>
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  ensure_home_identity
  [ "$HANDOFF_SOURCE_HOME" = "$FM_HOME_REAL" ] && [ "$HANDOFF_SOURCE_HOME_ID" = "$FM_HOME_ID" ] \
    || die "handoff completion source does not match the active home"
  identity_mutation_lock_acquire "$task"
  [ -e "$SOURCE_HANDOFF" ] || [ -L "$SOURCE_HANDOFF" ] || die "task $task has no prepared source handoff"
  read_handoff_state "$SOURCE_HANDOFF" source
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different source handoff"
  validate_source_transfer "$task"
  [ "$HANDOFF_STATE" = completed ] || write_handoff_state "$SOURCE_HANDOFF" source completed "$requested"
}

handoff_cancel() {  # <task-id> <transfer-path>; 4 means source is already completed
  local task=$1 path=$2 requested
  validate_handoff_envelope "$path" "$task"
  requested=$HANDOFF_CANONICAL
  ensure_home_identity
  [ "$HANDOFF_SOURCE_HOME" = "$FM_HOME_REAL" ] && [ "$HANDOFF_SOURCE_HOME_ID" = "$FM_HOME_ID" ] \
    || die "handoff cancellation source does not match the active home"
  identity_mutation_lock_acquire "$task"
  if [ ! -e "$SOURCE_HANDOFF" ] && [ ! -L "$SOURCE_HANDOFF" ]; then return 0; fi
  read_handoff_state "$SOURCE_HANDOFF" source
  [ "$HANDOFF_TRANSFER" = "$requested" ] || die "task $task prepared a different source handoff"
  [ "$HANDOFF_STATE" != completed ] || return 4
  rm -f -- "$SOURCE_HANDOFF" || die "cannot cancel handoff source state"
}

render_identity_projection_locked() {  # <task-id> [brief] [meta] [meta-brief-path]
  local task=$1 brief=${2:-} meta=${3:-} meta_brief_path=${4:-} reason
  ensure_home_identity
  META_PROVENANCE=absent
  BRIEF_PROVENANCE=absent
  if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    validate_sidecar "$SIDECAR" "$task"
    [ -z "$brief" ] || validate_brief_binding "$brief" linked "$WORK_HASH" "$WORK_CANONICAL"
    [ -z "$meta" ] || validate_meta_binding "$meta" linked "$WORK_HASH" "$BRIEF_HASH" "$meta_brief_path"
    jq -n -S -c \
      --argjson record "$WORK_CANONICAL" \
      --arg schema "$SCHEMA" \
      --arg hash "$WORK_HASH" \
      --arg brief_provenance "$BRIEF_PROVENANCE" \
      --arg meta_provenance "$META_PROVENANCE" '
        {status:"linked",schema:$schema,sha256:$hash,
         provenance:{record:"intake-sidecar",instructions:$brief_provenance,metadata:$meta_provenance}}
        + ($record | del(.schema))'
    return 0
  fi
  [ -z "$brief" ] || validate_brief_binding "$brief" unlinked
  [ -z "$meta" ] || validate_meta_binding "$meta" unlinked "" "$BRIEF_HASH" "$meta_brief_path"
  if [ "$META_PROVENANCE" = metadata ] || [ "$BRIEF_PROVENANCE" = generated-instructions ]; then
    reason=explicitly-unlinked
  else
    reason=legacy-no-record
  fi
  jq -n -S -c \
    --arg schema "$SCHEMA" \
    --arg home "$FM_HOME_REAL" \
    --arg home_id "$FM_HOME_ID" \
    --arg task "$task" \
    --arg reason "$reason" \
    --arg brief_provenance "$BRIEF_PROVENANCE" \
    --arg meta_provenance "$META_PROVENANCE" '
      {status:"unlinked",schema:$schema,sha256:null,binding:{home:$home,home_id:$home_id,task_id:$task},
       initiative:null,plan_id:null,stage:null,work_units:[],sources:[],reason:$reason,
       provenance:{record:"absent",instructions:$brief_provenance,metadata:$meta_provenance}}'
}

capture_identity_projection_locked() {  # <task-id> [brief] [meta] [meta-brief-path]
  PROJECTION_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-projection.XXXXXX") \
    || die "cannot capture work identity projection"
  render_identity_projection_locked "$@" > "$PROJECTION_TMP"
  IDENTITY_PROJECTION=$(cat "$PROJECTION_TMP") || die "cannot read work identity projection"
  rm -f -- "$PROJECTION_TMP"
  PROJECTION_TMP=
}

project_identity() {  # <task-id> [brief] [meta]
  local task=$1 brief=${2:-} meta=${3:-} meta_brief_path= recorded_brief= rc=0
  identity_lock_acquire "$task"
  reject_ownership_guard "$task"
  if [ -n "$meta" ]; then
    safe_regular_file "$meta" "task metadata"
    meta_field_exact "$meta" launch_brief || rc=$?
    case "$rc" in
      0)
        recorded_brief=$META_VALUE
        [ -z "$brief" ] || [ "$brief" = "$recorded_brief" ] \
          || die "explicit generated instructions do not match task metadata: $meta"
        brief=$recorded_brief
        meta_brief_path=$recorded_brief
        ;;
      1) ;;
      *) die "task metadata has duplicate launch brief paths: $meta" ;;
    esac
  fi
  if [ -z "$brief" ] && { [ -e "$BRIEF_DEFAULT" ] || [ -L "$BRIEF_DEFAULT" ]; }; then
    brief=$BRIEF_DEFAULT
  fi
  render_identity_projection_locked "$task" "$brief" "$meta" "$meta_brief_path"
}

brief_publish() {  # <task-id> <draft>
  local task=$1 draft=$2
  safe_regular_file "$draft" "generated instruction draft"
  identity_mutation_lock_acquire "$task"
  reject_ownership_guard "$task"
  [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
    || die "generated instructions already exist: $BRIEF_DEFAULT"
  RETAIN_BRIEF_CAPTURE=1
  if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    validate_sidecar "$SIDECAR" "$task"
    validate_brief_binding "$draft" linked "$WORK_HASH" "$WORK_CANONICAL"
  else
    validate_brief_binding "$draft" unlinked
  fi
  RETAIN_BRIEF_CAPTURE=0
  [ -n "$BRIEF_VALIDATED_CAPTURE" ] || die "cannot retain validated generated instructions"
  TMP=$(umask 077; mktemp "$TASK_DIR/.brief.XXXXXX") \
    || die "cannot create generated instructions"
  cp -- "$BRIEF_VALIDATED_CAPTURE" "$TMP" || die "cannot capture generated instructions"
  rm -f -- "$BRIEF_VALIDATED_CAPTURE"
  BRIEF_VALIDATED_CAPTURE=
  chmod 600 "$TMP" || die "cannot protect generated instructions"
  if ln "$TMP" "$BRIEF_DEFAULT" 2>/dev/null; then
    rm -f -- "$TMP"
    TMP=
  else
    rm -f -- "$TMP"
    TMP=
    [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
      || die "generated instructions already exist: $BRIEF_DEFAULT"
    die "cannot publish generated instructions: $BRIEF_DEFAULT"
  fi
}

dispatch_projection_matches_state() {  # <projection-json> <brief-sha>
  local projection=$1 brief_sha=$2
  [ "$brief_sha" = "$DISPATCH_INSTRUCTIONS_SHA" ] \
    || die "dispatch instructions digest is stale or mismatched"
  [ "$(printf '%s' "$projection" | jq -r '.status')" = "$DISPATCH_IDENTITY_STATUS" ] \
    || die "dispatch identity status is stale or mismatched"
  [ "$(printf '%s' "$projection" | jq -r '.sha256 // ""')" = "$DISPATCH_IDENTITY_SHA" ] \
    || die "dispatch identity digest is stale or mismatched"
}

dispatch_prepare() {  # <task-id> <brief-draft> <instructions-path> <transaction> [meta] [prior-brief]
  local task=$1 brief=$2 instructions_path=$3 transaction=$4 meta=${5:-} prior_brief=${6:-}
  local projection previous_hash= identity_status identity_sha existing_status= existing_path= existing_sha= recovery_meta
  dispatch_transaction_valid "$transaction" || die "dispatch transaction is malformed"
  safe_regular_file "$brief" "dispatch instruction draft"
  dispatch_instructions_path_valid "$instructions_path" || die "dispatch instructions path is unsafe"
  identity_mutation_lock_acquire "$task"
  reject_handoff_guard "$task"
  if [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ]; then
    read_dispatch_state "$task"
    existing_status=$DISPATCH_STATUS
    existing_path=$DISPATCH_INSTRUCTIONS
    existing_sha=$DISPATCH_INSTRUCTIONS_SHA
    if [ "$existing_status" = prepared ]; then
      if [ "$DISPATCH_TRANSACTION" = "$transaction" ]; then
        capture_identity_projection_locked "$task" "$brief"
        projection=$IDENTITY_PROJECTION
        dispatch_projection_matches_state "$projection" "$BRIEF_HASH"
        jq -n -S -c --arg transaction "$transaction" --arg hash "$BRIEF_HASH" \
          --argjson identity "$projection" \
          '{transaction_id:$transaction,instructions_sha256:$hash,work_identity:$identity}'
        return 0
      fi
      recovery_meta="$STATE_REAL/$task.meta"
      [ -e "$recovery_meta" ] || [ -L "$recovery_meta" ] \
        || die "task $task has a different in-progress work identity dispatch"
      complete_prepared_dispatch_locked "$task" "$DISPATCH_INSTRUCTIONS" "$recovery_meta"
      read_dispatch_state "$task"
      existing_status=$DISPATCH_STATUS
      existing_path=$DISPATCH_INSTRUCTIONS
      existing_sha=$DISPATCH_INSTRUCTIONS_SHA
    fi
    validate_completed_dispatch "$task"
  fi
  if [ -n "$meta" ] || [ -n "$prior_brief" ]; then
    [ -n "$meta" ] && [ -n "$prior_brief" ] \
      || die "replacement dispatch requires prior metadata and instructions"
    [ -e "$meta" ] || [ -L "$meta" ] || die "replacement dispatch metadata is absent: $meta"
    [ -e "$prior_brief" ] || [ -L "$prior_brief" ] || die "replacement dispatch instructions are absent: $prior_brief"
    capture_identity_projection_locked "$task" "$prior_brief" "$meta" "$instructions_path"
    projection=$IDENTITY_PROJECTION
    previous_hash=$BRIEF_HASH
    if [ "$existing_status" = completed ]; then
      [ "$existing_path" = "$instructions_path" ] && [ "$existing_sha" = "$previous_hash" ] \
        || die "replacement dispatch does not match the completed instruction binding"
    fi
    [ ! -e "$DISPATCH_PRIOR" ] && [ ! -L "$DISPATCH_PRIOR" ] \
      || die "replacement dispatch already has retained prior instructions"
    DISPATCH_PRIOR_TMP=$(umask 077; mktemp "$TASK_DIR/.work-identity-dispatch-prior.XXXXXX") \
      || die "cannot retain prior dispatch instructions"
    cp -- "$prior_brief" "$DISPATCH_PRIOR_TMP" || die "cannot retain prior dispatch instructions"
    chmod 400 "$DISPATCH_PRIOR_TMP" || die "cannot protect retained prior dispatch instructions"
    mv -- "$DISPATCH_PRIOR_TMP" "$DISPATCH_PRIOR" || die "cannot publish retained prior dispatch instructions"
    DISPATCH_PRIOR_TMP=
    DISPATCH_PRIOR_CLEANUP=1
  else
    [ -z "$existing_status" ] \
      || die "task $task was already dispatched; replacement requires prior metadata and instructions"
    [ ! -e "$STATE_REAL/$task.meta" ] && [ ! -L "$STATE_REAL/$task.meta" ] \
      || die "fresh dispatch found existing task metadata"
    [ ! -e "$instructions_path" ] && [ ! -L "$instructions_path" ] \
      || die "fresh dispatch found existing launch instructions"
  fi
  capture_identity_projection_locked "$task" "$brief"
  projection=$IDENTITY_PROJECTION
  identity_status=$(printf '%s' "$projection" | jq -er '.status') \
    || die "dispatch identity status is malformed"
  identity_sha=$(printf '%s' "$projection" | jq -r '.sha256 // ""')
  write_dispatch_state prepared "$task" "$transaction" "$instructions_path" "$BRIEF_HASH" \
    "$identity_status" "$identity_sha" "$([ -n "$previous_hash" ] && printf true || printf false)" "$previous_hash"
  DISPATCH_PRIOR_CLEANUP=0
  jq -n -S -c --arg transaction "$transaction" --arg hash "$BRIEF_HASH" \
    --argjson identity "$projection" \
    '{transaction_id:$transaction,instructions_sha256:$hash,work_identity:$identity}'
}

validate_dispatch_metadata_receipt() {  # <meta>
  local meta=$1 rc=0
  safe_regular_file "$meta" "task metadata"
  meta_field_exact "$meta" work_identity_dispatch_transaction || rc=$?
  [ "$rc" -eq 0 ] || {
    [ "$rc" -eq 1 ] \
      && die "task metadata has no work identity dispatch transaction: $meta"
    die "task metadata has duplicate work identity dispatch transactions: $meta"
  }
  [ "$META_VALUE" = "$DISPATCH_TRANSACTION" ] \
    || die "task metadata work identity dispatch transaction is stale or mismatched: $meta"
}

complete_prepared_dispatch_locked() {  # <task-id> <brief> <meta>
  local task=$1 brief=$2 meta=$3 projection
  [ "$DISPATCH_STATUS" = prepared ] || die "task $task has no prepared work identity dispatch"
  [ "$brief" = "$DISPATCH_INSTRUCTIONS" ] \
    || die "dispatch commit instructions path is mismatched"
  validate_dispatch_metadata_receipt "$meta"
  capture_identity_projection_locked "$task" "$brief" "$meta" "$brief"
  projection=$IDENTITY_PROJECTION
  dispatch_projection_matches_state "$projection" "$BRIEF_HASH"
  write_dispatch_state completed "$task" "$DISPATCH_TRANSACTION" "$DISPATCH_INSTRUCTIONS" \
    "$DISPATCH_INSTRUCTIONS_SHA" "$DISPATCH_IDENTITY_STATUS" "$DISPATCH_IDENTITY_SHA" \
    "$DISPATCH_REPLACEMENT" "$DISPATCH_PREVIOUS_SHA"
  if [ "$DISPATCH_REPLACEMENT" = true ]; then
    rm -f -- "$DISPATCH_PRIOR" || die "cannot retire retained prior dispatch instructions"
  fi
}

dispatch_commit() {  # <task-id> <brief> <meta> <transaction>
  local task=$1 brief=$2 meta=$3 transaction=$4
  identity_mutation_lock_acquire "$task"
  reject_handoff_guard "$task"
  [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ] \
    || die "task $task has no prepared work identity dispatch"
  read_dispatch_state "$task"
  [ "$DISPATCH_TRANSACTION" = "$transaction" ] \
    || die "task $task prepared a different work identity dispatch"
  if [ "$DISPATCH_STATUS" = completed ]; then
    validate_completed_dispatch "$task"
    return 0
  fi
  complete_prepared_dispatch_locked "$task" "$brief" "$meta"
}

dispatch_abort() {  # <task-id> <transaction>; 4 means committed, 5 means published metadata requires reconciliation
  local task=$1 transaction=$2 meta="$STATE_REAL/$1.meta" recorded_hash= rc=0 current_hash
  identity_mutation_lock_acquire "$task"
  if [ ! -e "$DISPATCH_STATE" ] && [ ! -L "$DISPATCH_STATE" ]; then return 0; fi
  read_dispatch_state "$task"
  [ "$DISPATCH_TRANSACTION" = "$transaction" ] \
    || die "task $task prepared a different work identity dispatch"
  [ "$DISPATCH_STATUS" != completed ] || return 4
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    safe_regular_file "$meta" "task metadata"
    meta_field_exact "$meta" launch_brief_sha256 || rc=$?
    [ "$rc" -le 1 ] || die "task metadata has duplicate launch brief digest fields: $meta"
    if [ "$rc" -eq 0 ]; then recorded_hash=$META_VALUE; fi
    if [ "$recorded_hash" = "$DISPATCH_INSTRUCTIONS_SHA" ]; then return 5; fi
    [ "$DISPATCH_REPLACEMENT" = true ] || return 5
  fi
  if [ "$DISPATCH_REPLACEMENT" = true ]; then
    safe_regular_file "$DISPATCH_PRIOR" "retained prior dispatch instructions"
    current_hash=$(sha256_file "$DISPATCH_PRIOR") || die "SHA-256 is unavailable for retained prior instructions"
    [ "$current_hash" = "$DISPATCH_PREVIOUS_SHA" ] \
      || die "retained prior dispatch instructions are stale or mismatched"
    TMP=$(umask 077; mktemp "$STATE_REAL/.$task.launch-brief-restore.XXXXXX") \
      || die "cannot restore prior dispatch instructions"
    cp -- "$DISPATCH_PRIOR" "$TMP" || die "cannot restore prior dispatch instructions"
    chmod 400 "$TMP" || die "cannot protect restored dispatch instructions"
    mv -f -- "$TMP" "$DISPATCH_INSTRUCTIONS" || die "cannot publish restored dispatch instructions"
    TMP=
    rm -f -- "$DISPATCH_PRIOR" || die "cannot retire retained prior dispatch instructions"
  elif [ -e "$DISPATCH_INSTRUCTIONS" ] || [ -L "$DISPATCH_INSTRUCTIONS" ]; then
    safe_regular_file "$DISPATCH_INSTRUCTIONS" "prepared dispatch instructions"
    current_hash=$(sha256_file "$DISPATCH_INSTRUCTIONS") \
      || die "SHA-256 is unavailable for prepared dispatch instructions"
    [ "$current_hash" = "$DISPATCH_INSTRUCTIONS_SHA" ] \
      || die "prepared dispatch instructions changed before abort"
    rm -f -- "$DISPATCH_INSTRUCTIONS" || die "cannot remove prepared dispatch instructions"
  fi
  rm -f -- "$DISPATCH_STATE" || die "cannot abort work identity dispatch"
}

publication_preflight_locked() {
  local task_dir task guarded guarded_path
  ensure_data_dir
  ensure_home_identity
  for task_dir in "$DATA_REAL"/*; do
    [ -e "$task_dir" ] || [ -L "$task_dir" ] || continue
    guarded=0
    for guarded_path in \
      "$task_dir/work-identity-handoff-source.json" \
      "$task_dir/work-identity-handoff-target.json" \
      "$task_dir/work-identity-dispatch.json"
    do
      if [ -e "$guarded_path" ] || [ -L "$guarded_path" ]; then guarded=1; fi
    done
    [ "$guarded" -eq 1 ] || continue
    task=$(basename "$task_dir")
    fm_pr_task_id_valid "$task" || die "work identity ownership guard has an invalid task id: $task"
    locate_task_dir "$task"
    identity_lock_acquire "$task"
    if [ -e "$SOURCE_HANDOFF" ] || [ -L "$SOURCE_HANDOFF" ]; then
      read_handoff_state "$SOURCE_HANDOFF" source
      [ "$HANDOFF_STATE" = completed ] \
        || die "work identity ownership handoff is incomplete for task $task"
      validate_source_transfer "$task"
    fi
    if [ -e "$TARGET_HANDOFF" ] || [ -L "$TARGET_HANDOFF" ]; then
      read_handoff_state "$TARGET_HANDOFF" target
      [ "$HANDOFF_STATE" = completed ] \
        || die "work identity ownership handoff is incomplete for task $task"
      handoff_target_matches_current
      validate_committed_target "$task"
    fi
    if [ -e "$DISPATCH_STATE" ] || [ -L "$DISPATCH_STATE" ]; then
      read_dispatch_state "$task"
      if [ "$DISPATCH_STATUS" = prepared ]; then
        complete_prepared_dispatch_locked "$task" "$DISPATCH_INSTRUCTIONS" "$STATE_REAL/$task.meta"
      else
        validate_completed_dispatch "$task"
      fi
    fi
    identity_lock_release
  done
}

publication_run() {
  local rc
  [ "$#" -gt 1 ] && [ "$1" = -- ] || die "publication-run requires -- and a command"
  shift
  DIE_STATUS=42
  publication_lock_acquire
  publication_preflight_locked
  set +e
  "$@"
  rc=$?
  set -e
  return "$rc"
}

command -v jq >/dev/null 2>&1 || die "jq not found"
COMMAND=${1:-}
case "$COMMAND" in
  -h|--help|help) usage; exit 0 ;;
  home-id|limits|record-max-bytes|validate-index|validate-projections|publication-run) ;;
  template|record|verify|brief-block|brief-publish|project|dispatch-binding|dispatch-prepare|dispatch-commit|dispatch-abort|handoff-prepare|handoff-stage|handoff-commit|handoff-abort|handoff-target-state|handoff-complete|handoff-cancel) ;;
  *) usage >&2; exit 2 ;;
esac
shift

case "$COMMAND" in
  publication-run)
    publication_run "$@"
    exit $?
    ;;
  home-id)
    [ "$#" -eq 0 ] || die "home-id accepts no arguments"
    ensure_home_identity
    printf '%s\n' "$FM_HOME_ID"
    exit 0
    ;;
  limits)
    [ "$#" -eq 0 ] || die "limits accepts no arguments"
    jq -n -c --argjson record "$MAX_BYTES" --argjson projection "$MAX_PROJECTION_BYTES" \
      '{record_max_bytes:$record,projection_max_bytes:$projection}'
    exit 0
    ;;
  record-max-bytes)
    [ "$#" -eq 0 ] || die "record-max-bytes accepts no arguments"
    printf '%s\n' "$MAX_BYTES"
    exit 0
    ;;
  validate-index)
    [ "$#" -eq 2 ] && [ "$1" = --file ] || die "validate-index usage: fm-work-identity.sh validate-index --file <index.json|->"
    DIE_STATUS=42
    capture_contract_input "$2" "work identity projection index" "$MAX_PROJECTION_BATCH_BYTES"
    validate_projection_index "$CONTRACT_INPUT"
    [ -z "$CONTRACT_INPUT_TMP" ] || rm -f -- "$CONTRACT_INPUT_TMP"
    exit 0
    ;;
  validate-projections)
    EXPECTED_HOME=
    EXPECTED_HOME_ID=
    INPUT_PATH=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --home) shift; [ "$#" -gt 0 ] || die "--home requires a path"; EXPECTED_HOME=$1 ;;
        --home-id) shift; [ "$#" -gt 0 ] || die "--home-id requires an id"; EXPECTED_HOME_ID=$1 ;;
        --file) shift; [ "$#" -gt 0 ] || die "--file requires a path"; INPUT_PATH=$1 ;;
        *) die "unknown validate-projections argument: $1" ;;
      esac
      shift
    done
    [ -n "$EXPECTED_HOME" ] && [ -n "$EXPECTED_HOME_ID" ] && [ -n "$INPUT_PATH" ] \
      || die "validate-projections requires --home, --home-id, and --file"
    DIE_STATUS=42
    capture_contract_input "$INPUT_PATH" "work identity projection set" "$MAX_PROJECTION_BATCH_BYTES"
    validate_projection_set "$CONTRACT_INPUT" "$EXPECTED_HOME" "$EXPECTED_HOME_ID"
    [ -z "$CONTRACT_INPUT_TMP" ] || rm -f -- "$CONTRACT_INPUT_TMP"
    exit 0
    ;;
esac

TASK=${1:-}
[ -n "$TASK" ] || die "$COMMAND requires a task id"
shift
case "$COMMAND" in
  template|record) fm_task_id_creation_valid "$TASK" || die "invalid task id" ;;
  *) fm_pr_task_id_valid "$TASK" || die "invalid task id" ;;
esac

case "$COMMAND" in
  template)
    [ "$#" -eq 0 ] || die "template accepts only a task id"
    ensure_home_identity
    jq -n -S \
      --arg schema "$SCHEMA" --arg home "$FM_HOME_REAL" --arg home_id "$FM_HOME_ID" --arg task "$TASK" '
      {schema:$schema,binding:{home:$home,home_id:$home_id,task_id:$task},
       initiative:{namespace:"work-aligner",kind:"project",id:"replace-project-id",label:"Replace project label"},
       plan_id:{namespace:"work-aligner",kind:"plan",id:"replace-plan-id",label:"Replace plan label"},
       stage:{namespace:"work-aligner",kind:"stage",id:"replace-stage-id",label:"Replace stage label"},
       work_units:[{namespace:"work-aligner",kind:"work-unit",id:"replace-work-unit-id",label:"Replace work-unit label"}],
       sources:[{namespace:"dtm",kind:"issue",id:"replace-dtm-issue-id",label:"Replace DTM issue label"}]}'
    ;;
  record)
    [ "$#" -eq 2 ] && [ "$1" = --file ] || die "record usage: fm-work-identity.sh record <task-id> --file <manifest.json>"
    MANIFEST=$2
    capture_manifest "$MANIFEST"
    CANONICAL=$(canonicalize_manifest "$MANIFEST_CAPTURE_TMP" "$TASK")
    identity_mutation_lock_acquire "$TASK"
    reject_ownership_guard "$TASK"
    verify_manifest_capture
    rm -f -- "$MANIFEST_CAPTURE_TMP"
    MANIFEST_CAPTURE_TMP=
    MANIFEST_CAPTURE_SOURCE=
    MANIFEST_CAPTURE_IDENTITY=
    META="$STATE_REAL/$TASK.meta"
    if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
      validate_sidecar "$SIDECAR" "$TASK"
      if [ "$WORK_CANONICAL" = "$CANONICAL" ]; then
        [ ! -e "$BRIEF_DEFAULT" ] && [ ! -L "$BRIEF_DEFAULT" ] \
          || validate_brief_binding "$BRIEF_DEFAULT" linked "$WORK_HASH" "$WORK_CANONICAL"
        [ ! -e "$META" ] && [ ! -L "$META" ] \
          || validate_meta_binding "$META" linked "$WORK_HASH"
        printf 'recorded %s task=%s sha256=%s (unchanged)\n' "$SCHEMA" "$TASK" "$WORK_HASH"
        exit 0
      fi
      die "work identity is immutable once recorded; changed relation requires a new task id"
    elif [ -e "$BRIEF_DEFAULT" ] || [ -L "$BRIEF_DEFAULT" ] || [ -e "$META" ] || [ -L "$META" ]; then
      die "work identity must be recorded before generated instructions and dispatch"
    fi
    TMP=$(umask 077; mktemp "$TASK_DIR/.work-identity.XXXXXX") || die "cannot create work identity temporary file"
    printf '%s\n' "$CANONICAL" > "$TMP" || die "cannot write work identity temporary file"
    validate_sidecar "$TMP" "$TASK"
    if ln "$TMP" "$SIDECAR" 2>/dev/null; then
      rm -f -- "$TMP"
      TMP=
      validate_sidecar "$SIDECAR" "$TASK"
      printf 'recorded %s task=%s sha256=%s\n' "$SCHEMA" "$TASK" "$WORK_HASH"
    else
      rm -f -- "$TMP"
      TMP=
      [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ] || die "cannot publish work identity record"
      validate_sidecar "$SIDECAR" "$TASK"
      [ "$WORK_CANONICAL" = "$CANONICAL" ] \
        || die "work identity is immutable once recorded; changed relation requires a new task id"
      printf 'recorded %s task=%s sha256=%s (unchanged)\n' "$SCHEMA" "$TASK" "$WORK_HASH"
    fi
    ;;
  brief-publish)
    [ "$#" -eq 2 ] && [ "$1" = --file ] \
      || die "brief-publish usage: fm-work-identity.sh brief-publish <task-id> --file <draft.md>"
    brief_publish "$TASK" "$2"
    ;;
  dispatch-prepare)
    DISPATCH_BRIEF=
    DISPATCH_INSTRUCTIONS_PATH=
    DISPATCH_TRANSACTION_ARG=
    DISPATCH_META=
    DISPATCH_PRIOR_BRIEF=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --brief) shift; [ "$#" -gt 0 ] || die "--brief requires a path"; DISPATCH_BRIEF=$1 ;;
        --instructions-path) shift; [ "$#" -gt 0 ] || die "--instructions-path requires a path"; DISPATCH_INSTRUCTIONS_PATH=$1 ;;
        --transaction) shift; [ "$#" -gt 0 ] || die "--transaction requires an id"; DISPATCH_TRANSACTION_ARG=$1 ;;
        --meta) shift; [ "$#" -gt 0 ] || die "--meta requires a path"; DISPATCH_META=$1 ;;
        --prior-brief) shift; [ "$#" -gt 0 ] || die "--prior-brief requires a path"; DISPATCH_PRIOR_BRIEF=$1 ;;
        *) die "unknown dispatch-prepare argument: $1" ;;
      esac
      shift
    done
    [ -n "$DISPATCH_BRIEF" ] && [ -n "$DISPATCH_INSTRUCTIONS_PATH" ] && [ -n "$DISPATCH_TRANSACTION_ARG" ] \
      || die "dispatch-prepare requires --brief, --instructions-path, and --transaction"
    dispatch_prepare "$TASK" "$DISPATCH_BRIEF" "$DISPATCH_INSTRUCTIONS_PATH" \
      "$DISPATCH_TRANSACTION_ARG" "$DISPATCH_META" "$DISPATCH_PRIOR_BRIEF"
    ;;
  dispatch-commit)
    DISPATCH_BRIEF=
    DISPATCH_META=
    DISPATCH_TRANSACTION_ARG=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --brief) shift; [ "$#" -gt 0 ] || die "--brief requires a path"; DISPATCH_BRIEF=$1 ;;
        --meta) shift; [ "$#" -gt 0 ] || die "--meta requires a path"; DISPATCH_META=$1 ;;
        --transaction) shift; [ "$#" -gt 0 ] || die "--transaction requires an id"; DISPATCH_TRANSACTION_ARG=$1 ;;
        *) die "unknown dispatch-commit argument: $1" ;;
      esac
      shift
    done
    [ -n "$DISPATCH_BRIEF" ] && [ -n "$DISPATCH_META" ] && [ -n "$DISPATCH_TRANSACTION_ARG" ] \
      || die "dispatch-commit requires --brief, --meta, and --transaction"
    dispatch_commit "$TASK" "$DISPATCH_BRIEF" "$DISPATCH_META" "$DISPATCH_TRANSACTION_ARG"
    ;;
  dispatch-abort)
    [ "$#" -eq 2 ] && [ "$1" = --transaction ] \
      || die "dispatch-abort usage: fm-work-identity.sh dispatch-abort <task-id> --transaction <id>"
    dispatch_abort "$TASK" "$2"
    ;;
  handoff-prepare)
    [ "$#" -eq 4 ] || [ "$#" -eq 5 ] \
      || die "handoff-prepare usage: fm-work-identity.sh handoff-prepare <task-id> --to-home <absolute-home> --to-home-id <home-id> [--result]"
    [ "$1" = --to-home ] && [ "$3" = --to-home-id ] \
      || die "handoff-prepare usage: fm-work-identity.sh handoff-prepare <task-id> --to-home <absolute-home> --to-home-id <home-id> [--result]"
    HANDOFF_PREPARE_MODE=transfer
    if [ "$#" -eq 5 ]; then
      [ "$5" = --result ] \
        || die "handoff-prepare usage: fm-work-identity.sh handoff-prepare <task-id> --to-home <absolute-home> --to-home-id <home-id> [--result]"
      HANDOFF_PREPARE_MODE=result
    fi
    handoff_prepare "$TASK" "$2" "$4" "$HANDOFF_PREPARE_MODE"
    ;;
  handoff-stage|handoff-commit|handoff-abort|handoff-target-state|handoff-complete|handoff-cancel)
    [ "$#" -eq 2 ] && [ "$1" = --file ] \
      || die "$COMMAND usage: fm-work-identity.sh $COMMAND <task-id> --file <transfer.json|->"
    capture_contract_input "$2" "work identity handoff transfer" "$HANDOFF_MAX_BYTES"
    case "$COMMAND" in
      handoff-stage) handoff_stage "$TASK" "$CONTRACT_INPUT" ;;
      handoff-commit) handoff_commit "$TASK" "$CONTRACT_INPUT" ;;
      handoff-abort) handoff_abort "$TASK" "$CONTRACT_INPUT" ;;
      handoff-target-state) handoff_target_state "$TASK" "$CONTRACT_INPUT" ;;
      handoff-complete) handoff_complete "$TASK" "$CONTRACT_INPUT" ;;
      handoff-cancel) handoff_cancel "$TASK" "$CONTRACT_INPUT" ;;
    esac
    [ -z "$CONTRACT_INPUT_TMP" ] || rm -f -- "$CONTRACT_INPUT_TMP"
    CONTRACT_INPUT_TMP=
    ;;
  verify)
    [ "$#" -eq 0 ] || die "verify accepts only a task id"
    locate_task_dir "$TASK"
    META="$STATE_REAL/$TASK.meta"
    [ -e "$META" ] || [ -L "$META" ] || META=
    project_identity "$TASK" "" "$META"
    ;;
  brief-block)
    [ "$#" -eq 0 ] || die "brief-block accepts only a task id"
    identity_lock_acquire "$TASK"
    reject_ownership_guard "$TASK"
    ensure_home_identity
    if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
      validate_sidecar "$SIDECAR" "$TASK"
      cat <<EOF
# Exact work identity
Work identity contract: $SCHEMA sha256=$WORK_HASH
The namespace, kind, and id tuples below are exact identities; labels are display-only.
Work identity payload: $WORK_CANONICAL
Do not infer or replace these identities from the task title, repository, branch, worker, timing, endpoint, or status prose.
EOF
    else
      cat <<EOF
# Exact work identity
Work identity contract: $SCHEMA unlinked
No exact project, plan, stage, work-unit, or source identity was recorded at intake.
Do not infer one from the task title, repository, branch, worker, timing, endpoint, label, or status prose.
EOF
    fi
    ;;
  project|dispatch-binding)
    BRIEF=
    META=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --brief)
          shift; [ "$#" -gt 0 ] || die "--brief requires a path"
          BRIEF=$1
          ;;
        --meta)
          shift; [ "$#" -gt 0 ] || die "--meta requires a path"
          META=$1
          ;;
        *) die "unknown $COMMAND argument: $1" ;;
      esac
      shift
    done
    if [ "$COMMAND" = project ]; then
      project_identity "$TASK" "$BRIEF" "$META"
    else
      [ -n "$BRIEF" ] || die "dispatch-binding requires --brief"
      TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-work-identity-dispatch.XXXXXX") \
        || die "cannot create dispatch binding projection"
      project_identity "$TASK" "$BRIEF" "$META" > "$TMP"
      [ -n "$BRIEF_HASH" ] || die "dispatch instructions have no validated digest"
      jq -n -S -c --arg hash "$BRIEF_HASH" --slurpfile identity "$TMP" \
        '{instructions_sha256:$hash,work_identity:$identity[0]}'
      rm -f -- "$TMP"
      TMP=
    fi
    ;;
esac
