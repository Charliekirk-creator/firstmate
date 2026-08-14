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
#   fm-work-identity.sh project <task-id> [--brief <brief.md>] [--meta <task.meta>]
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
#   "binding": {"home": "<physical absolute FM_HOME>", "task_id": "<task-id>"},
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
#   - task ids use Firstmate's canonical creation grammar and are at most 64 bytes;
#   - ids are 1..240 ASCII bytes, begin alphanumeric, and use only
#     A-Z a-z 0-9 . _ : @ / # ~ -; path-like '.', '..', empty, leading, or
#     trailing slash segments are refused;
#   - labels are 1..160 characters, have no leading/trailing whitespace,
#     controls, Unicode line separators, or Markdown table/HTML/backslash
#     metacharacters, and are never paths;
#   - work_units and sources each contain 1..20 identities;
#   - no exact identity tuple may occur twice anywhere in one record;
#   - the manifest and sidecar are bounded regular, non-symlink, single-link
#     files; task directories are direct non-symlink children of the configured
#     data directory;
#   - binding.home and binding.task_id must exactly match the physical active
#     home and command task id, so copied cross-home or task-mismatched records
#     are refused;
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
MAX_BYTES=65536
MAX_ARRAY=20

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
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

safe_regular_file() {  # <path> <label>
  local path=$1 label=$2 links bytes
  [ ! -L "$path" ] || die "$label is symlinked: $path"
  [ -f "$path" ] || die "$label is not a regular file: $path"
  links=$(file_link_count "$path") || die "cannot inspect $label link count: $path"
  [ "$links" = 1 ] || die "$label is hardlinked: $path"
  bytes=$(file_size "$path") || die "cannot inspect $label size: $path"
  case "$bytes" in ''|*[!0-9]*) die "$label has an invalid size: $path" ;; esac
  [ "$bytes" -le "$MAX_BYTES" ] || die "$label exceeds $MAX_BYTES bytes: $path"
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
}

ensure_task_dir() {  # <task-id>
  local id=$1
  ensure_data_dir
  locate_task_dir "$id"
  if [ ! -d "$TASK_DIR" ]; then
    mkdir -- "$TASK_DIR" || die "cannot create task data directory: $TASK_DIR"
    locate_task_dir "$id"
  fi
}

canonicalize_manifest() {  # <path> <task-id>
  local path=$1 task=$2 out
  out=$(jq -e -S -c \
    --arg schema "$SCHEMA" \
    --arg home "$FM_HOME_REAL" \
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
        and (([explode[] | select(
          . < 32 or . == 60 or . == 62 or . == 92 or . == 96 or . == 124
          or . == 127 or . == 8232 or . == 8233)] | length) == 0)
        and . != "." and . != "..";
      def identity:
        type == "object" and exact_keys(["namespace","kind","id","label"])
        and (.namespace | type == "string")
        and (.kind | type == "string")
        and (.id | safe_id)
        and (.label | safe_label);
      def key: [.namespace,.kind,.id] | join("\u001f");
      def allowed($pairs): . as $i | identity and ($pairs | index($i.namespace + ":" + $i.kind) != null);
      exact_keys(["schema","binding","initiative","plan_id","stage","work_units","sources"])
      and .schema == $schema
      and (.binding | type == "object" and exact_keys(["home","task_id"])
        and .home == $home and .task_id == $task)
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
    ' "$path" 2>/dev/null) || die "manifest does not satisfy $SCHEMA"
  [ "$out" = true ] || die "manifest does not satisfy $SCHEMA"
  jq -S -c . "$path" 2>/dev/null || die "manifest is not valid JSON"
}

validate_sidecar() {  # <path> <task-id>; sets WORK_CANONICAL/WORK_HASH
  local path=$1 task=$2 before after canonical
  safe_regular_file "$path" "work identity record"
  before=$(file_identity "$path") || die "cannot inspect work identity record: $path"
  canonical=$(canonicalize_manifest "$path" "$task")
  if ! printf '%s\n' "$canonical" | cmp -s "$path" -; then
    die "work identity record is not canonical or has trailing data: $path"
  fi
  after=$(file_identity "$path") || die "cannot reinspect work identity record: $path"
  [ "$before" = "$after" ] || die "work identity record changed while it was read: $path"
  WORK_HASH=$(sha256_file "$path") || die "SHA-256 is unavailable for work identity record"
  case "$WORK_HASH" in ''|*[!A-Fa-f0-9]*) die "work identity SHA-256 is invalid" ;; esac
  [ "${#WORK_HASH}" -eq 64 ] || die "work identity SHA-256 has the wrong length"
  WORK_HASH=$(printf '%s' "$WORK_HASH" | tr 'A-F' 'a-f')
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

validate_meta_binding() {  # <meta> <linked|unlinked> [hash]
  local meta=$1 expected=$2 hash=${3:-} status schema recorded_hash rc
  [ -e "$meta" ] || [ -L "$meta" ] || return 0
  rc=0; meta_field_exact "$meta" work_identity_status || rc=$?
  if [ "$rc" -eq 1 ]; then
    meta_field_exact "$meta" work_identity_schema >/dev/null 2>&1 && die "task metadata has a work identity schema without status: $meta"
    meta_field_exact "$meta" work_identity_sha256 >/dev/null 2>&1 && die "task metadata has a work identity digest without status: $meta"
    [ "$expected" = unlinked ] || die "linked work identity is not bound by task metadata: $meta"
    META_PROVENANCE=legacy
    return 0
  fi
  safe_regular_file "$meta" "task metadata"
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
  META_PROVENANCE=metadata
}

brief_contract_count() {  # <brief>
  grep -c '^Work identity contract:' "$1" 2>/dev/null || true
}

validate_brief_binding() {  # <brief> <linked|unlinked> [hash] [canonical]
  local brief=$1 expected=$2 hash=${3:-} canonical=${4:-} count marker payload_count expected_marker
  [ -e "$brief" ] || [ -L "$brief" ] || { BRIEF_PROVENANCE=absent; return 0; }
  count=$(brief_contract_count "$brief")
  if [ "$count" = 0 ]; then
    [ "$expected" = unlinked ] || die "linked work identity is missing from generated instructions: $brief"
    BRIEF_PROVENANCE=legacy
    return 0
  fi
  safe_regular_file "$brief" "generated instructions"
  [ "$count" = 1 ] || die "generated instructions contain duplicate work identity contracts: $brief"
  marker=$(grep '^Work identity contract:' "$brief")
  if [ "$expected" = linked ]; then
    expected_marker="Work identity contract: $SCHEMA sha256=$hash"
    [ "$marker" = "$expected_marker" ] || die "stale or mismatched work identity contract in generated instructions: $brief"
    payload_count=$(grep -c '^Work identity payload: ' "$brief" 2>/dev/null || true)
    [ "$payload_count" = 1 ] || die "generated instructions require one exact work identity payload: $brief"
    [ "$(grep '^Work identity payload: ' "$brief")" = "Work identity payload: $canonical" ] \
      || die "stale or mismatched work identity payload in generated instructions: $brief"
  else
    [ "$marker" = "Work identity contract: $SCHEMA unlinked" ] \
      || die "generated instructions claim a linked or unknown work identity without a record: $brief"
    payload_count=$(grep -c '^Work identity payload: ' "$brief" 2>/dev/null || true)
    [ "$payload_count" = 0 ] || die "unlinked generated instructions must not carry a work identity payload: $brief"
  fi
  BRIEF_PROVENANCE=generated-instructions
}

project_identity() {  # <task-id> [brief] [meta]
  local task=$1 brief=${2:-} meta=${3:-} reason
  locate_task_dir "$task"
  META_PROVENANCE=absent
  BRIEF_PROVENANCE=absent
  if [ -e "$SIDECAR" ] || [ -L "$SIDECAR" ]; then
    validate_sidecar "$SIDECAR" "$task"
    [ -z "$brief" ] || validate_brief_binding "$brief" linked "$WORK_HASH" "$WORK_CANONICAL"
    [ -z "$meta" ] || validate_meta_binding "$meta" linked "$WORK_HASH"
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
  [ -z "$meta" ] || validate_meta_binding "$meta" unlinked
  if [ "$META_PROVENANCE" = metadata ] || [ "$BRIEF_PROVENANCE" = generated-instructions ]; then
    reason=explicitly-unlinked
  else
    reason=legacy-no-record
  fi
  jq -n -S -c \
    --arg schema "$SCHEMA" \
    --arg home "$FM_HOME_REAL" \
    --arg task "$task" \
    --arg reason "$reason" \
    --arg brief_provenance "$BRIEF_PROVENANCE" \
    --arg meta_provenance "$META_PROVENANCE" '
      {status:"unlinked",schema:$schema,sha256:null,binding:{home:$home,task_id:$task},
       initiative:null,plan_id:null,stage:null,work_units:[],sources:[],reason:$reason,
       provenance:{record:"absent",instructions:$brief_provenance,metadata:$meta_provenance}}'
}

command -v jq >/dev/null 2>&1 || die "jq not found"
COMMAND=${1:-}
case "$COMMAND" in
  -h|--help|help) usage; exit 0 ;;
  template|record|verify|brief-block|project) ;;
  *) usage >&2; exit 2 ;;
esac
shift
TASK=${1:-}
[ -n "$TASK" ] || die "$COMMAND requires a task id"
shift
fm_task_id_creation_valid "$TASK" || die "invalid task id"

case "$COMMAND" in
  template)
    [ "$#" -eq 0 ] || die "template accepts only a task id"
    jq -n -S \
      --arg schema "$SCHEMA" --arg home "$FM_HOME_REAL" --arg task "$TASK" '
      {schema:$schema,binding:{home:$home,task_id:$task},
       initiative:{namespace:"work-aligner",kind:"project",id:"replace-project-id",label:"Replace project label"},
       plan_id:{namespace:"work-aligner",kind:"plan",id:"replace-plan-id",label:"Replace plan label"},
       stage:{namespace:"work-aligner",kind:"stage",id:"replace-stage-id",label:"Replace stage label"},
       work_units:[{namespace:"work-aligner",kind:"work-unit",id:"replace-work-unit-id",label:"Replace work-unit label"}],
       sources:[{namespace:"dtm",kind:"issue",id:"replace-dtm-issue-id",label:"Replace DTM issue label"}]}'
    ;;
  record)
    [ "$#" -eq 2 ] && [ "$1" = --file ] || die "record usage: fm-work-identity.sh record <task-id> --file <manifest.json>"
    MANIFEST=$2
    safe_regular_file "$MANIFEST" "work identity manifest"
    MANIFEST_BEFORE=$(file_identity "$MANIFEST") || die "cannot inspect work identity manifest"
    CANONICAL=$(canonicalize_manifest "$MANIFEST" "$TASK")
    MANIFEST_AFTER=$(file_identity "$MANIFEST") || die "cannot reinspect work identity manifest"
    [ "$MANIFEST_BEFORE" = "$MANIFEST_AFTER" ] || die "work identity manifest changed while it was read"
    ensure_task_dir "$TASK"
    STATE=$STATE_REAL
    # shellcheck source=bin/fm-wake-lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    RECORD_LOCK="$TASK_DIR/.work-identity.lock"
    fm_lock_acquire_wait "$RECORD_LOCK"
    RECORD_LOCK_HELD=1
    TMP=
    record_cleanup() {
      local status=$?
      [ -z "${TMP:-}" ] || rm -f -- "$TMP"
      if [ "${RECORD_LOCK_HELD:-0}" = 1 ]; then
        RECORD_LOCK_HELD=0
        fm_lock_release "$RECORD_LOCK" || true
      fi
      return "$status"
    }
    trap record_cleanup EXIT
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
  verify)
    [ "$#" -eq 0 ] || die "verify accepts only a task id"
    locate_task_dir "$TASK"
    META="$STATE_REAL/$TASK.meta"
    BRIEF="$BRIEF_DEFAULT"
    [ -e "$META" ] || [ -L "$META" ] || META=
    [ -e "$BRIEF" ] || [ -L "$BRIEF" ] || BRIEF=
    project_identity "$TASK" "$BRIEF" "$META"
    ;;
  brief-block)
    [ "$#" -eq 0 ] || die "brief-block accepts only a task id"
    locate_task_dir "$TASK"
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
  project)
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
        *) die "unknown project argument: $1" ;;
      esac
      shift
    done
    project_identity "$TASK" "$BRIEF" "$META"
    ;;
esac
