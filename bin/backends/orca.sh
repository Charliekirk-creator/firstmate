#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape key support
# remains unsupported until Orca exposes a terminal-send primitive for it.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

fm_backend_orca_tool_check() {
  command -v orca >/dev/null 2>&1 || { echo "error: backend=orca selected but the 'orca' CLI is not installed" >&2; return 1; }
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(orca status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_json_error_code() {
  node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (_) {
  process.exit(1);
}
const code = data && data.error && data.error.code;
if (typeof code !== "string" || !code) process.exit(1);
process.stdout.write(code);
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(orca repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(orca repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

fm_backend_orca_file_link_count() {
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%l' "$1" 2>/dev/null
  else
    stat -c '%h' "$1" 2>/dev/null
  fi
}

fm_backend_orca_worktree_response_parse() {  # <response-path> <name>
  local response=$1 name=$2 out wt_id wt_path terminal links bytes
  [ -f "$response" ] && [ ! -L "$response" ] || return 1
  links=$(fm_backend_orca_file_link_count "$response") || return 1
  [ "$links" = 1 ] || return 1
  bytes=$(LC_ALL=C wc -c < "$response" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le 65536 ] || return 1
  out=$(cat "$response") || return 1
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" --absent-ok >/dev/null; then
      return 3
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

fm_backend_orca_worktree_response_complete() {  # <response-path>
  local response=$1 out links bytes
  [ -f "$response" ] && [ ! -L "$response" ] || return 1
  links=$(fm_backend_orca_file_link_count "$response") || return 1
  [ "$links" = 1 ] || return 1
  bytes=$(LC_ALL=C wc -c < "$response" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le 65536 ] || return 1
  out=$(cat "$response") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok >/dev/null 2>&1 \
    && printf '%s' "$out" | fm_backend_orca_json_get worktree-id >/dev/null 2>&1
}

fm_backend_orca_worktree_response_ready() {  # <response-path>
  local response=$1 out
  fm_backend_orca_worktree_response_complete "$response" || return 1
  out=$(cat "$response") || return 1
  printf '%s' "$out" | fm_backend_orca_json_get worktree-path >/dev/null 2>&1
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id response rc
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  response=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-orca-worktree.XXXXXX") || return 1
  if orca worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json > "$response"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    fm_backend_orca_worktree_response_parse "$response" "$name"
    rc=$?
  fi
  rm -f -- "$response"
  return "$rc"
}

fm_backend_orca_worktree_create_durable() {  # <project-path> <name> <response-path>
  local project=$1 name=$2 response=$3 repo_id creator rc
  [ ! -e "$response" ] && [ ! -L "$response" ] || return 1
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  (
    umask 077
    set -C
    exec orca worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip --json > "$response"
  ) &
  creator=$!
  if wait "$creator"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 0 ] || return "$rc"
  fm_backend_orca_worktree_response_parse "$response" "$name"
}

fm_backend_orca_terminal_response_parse() {  # <response-path> <title>
  local response=$1 title=$2 out terminal links bytes
  [ -f "$response" ] && [ ! -L "$response" ] || return 1
  links=$(fm_backend_orca_file_link_count "$response") || return 1
  [ "$links" = 1 ] || return 1
  bytes=$(LC_ALL=C wc -c < "$response" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le 65536 ] || return 1
  out=$(cat "$response") || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

fm_backend_orca_terminal_create() {  # <worktree-id> <title>
  local worktree_id=$1 title=$2 out terminal
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

fm_backend_orca_operation_scalar_read() {  # <path>
  local path=$1 links value
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  links=$(fm_backend_orca_file_link_count "$path") || return 1
  [ "$links" = 1 ] || return 1
  value=$(tr -d '\n' < "$path") || return 1
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value" | cmp -s "$path" - || return 1
  printf '%s' "$value"
}

fm_backend_orca_operation_scalar_publish() {  # <path> <value>
  local path=$1 value=$2 tmp
  tmp=$(umask 077; mktemp "${path}.XXXXXX") || return 1
  printf '%s\n' "$value" > "$tmp" && chmod 600 "$tmp" \
    && ln "$tmp" "$path" 2>/dev/null
  local rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

fm_backend_orca_terminal_create_durable() {  # <worktree-id> <title> <response-path> <operation-prefix>
  local worktree_id=$1 title=$2 response=$3 operation=$4
  local pid_file="${operation}.pid" start_file="${operation}.start" status_file="${operation}.status"
  local creator pid status tmp rc i=0 max=${FM_ORCA_TERMINAL_POLLS:-3000} interval=${FM_ORCA_TERMINAL_INTERVAL:-0.02}
  fm_backend_orca_tool_check || return 1
  while :; do
    if [ -e "$status_file" ] || [ -L "$status_file" ]; then
      status=$(fm_backend_orca_operation_scalar_read "$status_file") || return 1
      if [ "$status" -eq 0 ]; then
        fm_backend_orca_terminal_response_parse "$response" "$title"
        return $?
      fi
      [ "$status" -le 125 ] || return 1
      return "$status"
    fi

    if [ -e "$pid_file" ] || [ -L "$pid_file" ]; then
      pid=$(fm_backend_orca_operation_scalar_read "$pid_file") || return 1
      if kill -0 "$pid" 2>/dev/null; then
        if [ ! -e "$start_file" ] && [ ! -L "$start_file" ]; then
          fm_backend_orca_operation_scalar_publish "$start_file" 1 || return 1
        else
          fm_backend_orca_operation_scalar_read "$start_file" >/dev/null || return 1
        fi
      elif [ -e "$response" ] || [ -L "$response" ]; then
        fm_backend_orca_terminal_response_parse "$response" "$title"
        return $?
      elif [ ! -e "$start_file" ] && [ ! -L "$start_file" ]; then
        rm -f -- "$pid_file" || return 1
        continue
      else
        echo "error: Orca terminal creation stopped without a recoverable outcome for $title" >&2
        return 1
      fi
    elif [ -e "$response" ] || [ -L "$response" ] \
      || [ -e "$start_file" ] || [ -L "$start_file" ]; then
      echo "error: Orca terminal creation journal is incomplete for $title" >&2
      return 1
    else
      (
        trap '' HUP INT
        i=0
        while [ ! -e "$start_file" ] && [ ! -L "$start_file" ]; do
          i=$((i + 1))
          [ "$i" -lt 1500 ] || exit 124
          sleep 0.02
        done
        fm_backend_orca_operation_scalar_read "$start_file" >/dev/null || exit 1
        tmp=$(umask 077; mktemp "${response}.XXXXXX") || exit 1
        if orca terminal create --worktree "id:$worktree_id" --title "$title" --json > "$tmp"; then
          rc=0
          chmod 600 "$tmp" || rc=1
          if [ "$rc" -eq 0 ]; then
            ln "$tmp" "$response" 2>/dev/null || rc=1
          fi
        else
          rc=$?
        fi
        rm -f -- "$tmp"
        fm_backend_orca_operation_scalar_publish "$status_file" "$rc" || exit 1
        exit "$rc"
      ) &
      creator=$!
      if ! fm_backend_orca_operation_scalar_publish "$pid_file" "$creator"; then
        kill "$creator" 2>/dev/null || true
        wait "$creator" 2>/dev/null || true
        return 1
      fi
      fm_backend_orca_operation_scalar_publish "$start_file" 1 || {
        kill "$creator" 2>/dev/null || true
        wait "$creator" 2>/dev/null || true
        return 1
      }
    fi

    i=$((i + 1))
    [ "$i" -lt "$max" ] || {
      echo "error: Orca terminal creation is still in progress for $title" >&2
      return 1
    }
    sleep "$interval"
  done
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id> [--absent-ok]
  local worktree_id=${1:-} absent_ok=${2:-} out rc code
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  case "$absent_ok" in ''|--absent-ok) ;; *) return 1 ;; esac
  fm_backend_orca_tool_check || return 1
  if out=$(orca worktree rm --worktree "id:$worktree_id" --force --json); then
    rc=0
  else
    rc=$?
  fi
  code=$(printf '%s' "$out" | fm_backend_orca_json_error_code 2>/dev/null || true)
  if [ "$absent_ok" = --absent-ok ]; then
    case "$code" in worktree_not_found|not_found) return 0 ;; esac
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(orca worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

# fm_backend_orca_composer_capture: the orca composer screen - one bounded
# tail read of the live terminal. Deliberately NOT the old 200-line
# backward-paged read: the composer is bottom-anchored, and paging back into
# scrollback is what let a stale startup banner (codex's bordered
# "permissions" box) compete with - and once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's `terminal read` returns
# plain text; whether it can emit ANSI is unverified (orca is not installed
# on the verification machine), so styled stays 0 - the conservative
# degradation - until a live capture proves otherwise.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter without
# duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$terminal" "$retries" "$sleep_s"
}

fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 0
  orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}
