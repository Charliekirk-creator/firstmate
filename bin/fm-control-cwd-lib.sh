#!/usr/bin/env bash
# Herdr cwd repair implementation for fm-control.sh, which owns the operator
# contract and transaction. Not a standalone command or a general rebind API.
# Sourced only for relaunch --repair-cwd, after control's helpers are defined.
# Uppercase transaction variables belong to that caller, not the lowercase
# locals in the imported shared libraries.
# shellcheck disable=SC2153

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

REPAIR_META_LOCK=
REPAIR_SESSION_LOCK=
REPAIR_STATE=prepared
REPAIR_SOURCE=
REPAIR_SOURCE_STATUS=unobserved
REPAIR_TARGET=
REPAIR_TARGET_RECORDED=
REPAIR_TARGET_STATUS=unchecked
REPAIR_SESSION=
REPAIR_WORKSPACE=
REPAIR_TAB=
REPAIR_OLD_PANE=
REPAIR_OLD_PID=
REPAIR_OLD_OUTCOME=retained
REPAIR_NEW_PANE=
REPAIR_NEW_OWNED=0
REPAIR_PUBLISHED=0
REPAIR_PUBLICATION_ATTEMPTED=0
REPAIR_PROJECTION=none
REPAIR_SEEN=
REPAIR_SEEN_PANE=
REPAIR_REFUSAL=
REPAIR_BRIEF_OUTCOME=not-attempted
REPAIR_BRIEF_BACKUP_VALID=0
REPAIR_EVIDENCE_ACTIVE=0

repair_release_locks() {
  [ -z "$REPAIR_META_LOCK" ] || fm_lock_release "$REPAIR_META_LOCK"
  [ -z "$REPAIR_SESSION_LOCK" ] || fm_lock_release "$REPAIR_SESSION_LOCK"
}

repair_journal_lines() {
  printf '%s\n' "repair_state=$REPAIR_STATE" "repair_source=$REPAIR_SOURCE" \
    "repair_source_status=$REPAIR_SOURCE_STATUS" \
    "repair_target=$REPAIR_TARGET" "repair_target_status=$REPAIR_TARGET_STATUS" \
    "repair_session=$REPAIR_SESSION" "repair_workspace=$REPAIR_WORKSPACE" \
    "repair_tab=$REPAIR_TAB" "repair_old_pane=$REPAIR_OLD_PANE" \
    "repair_old_shell_pid=$REPAIR_OLD_PID" "repair_old_outcome=$REPAIR_OLD_OUTCOME" \
    "repair_new_pane=$REPAIR_NEW_PANE" \
    "repair_published=$REPAIR_PUBLISHED" "repair_publication_attempted=$REPAIR_PUBLICATION_ATTEMPTED" \
    "repair_projection=$REPAIR_PROJECTION" "repair_observed_pane=$REPAIR_SEEN_PANE" \
    "repair_brief_outcome=$REPAIR_BRIEF_OUTCOME" \
    "repair_brief_backup_valid=$REPAIR_BRIEF_BACKUP_VALID"
  # Live API output is untrusted, including control characters. JSON encoding
  # keeps an exact failed observation without injecting journal fields.
  printf 'repair_recorded_target_json=%s\n' "$(jq -cn --arg path "$REPAIR_TARGET_RECORDED" '$path')"
  printf 'repair_observed_json=%s\n' "$(jq -cn --arg cwd "$REPAIR_SEEN" '$cwd')"
  printf 'repair_refusal_json=%s\n' "$(jq -cn --arg reason "$REPAIR_REFUSAL" '$reason')"
}

repair_refuse() {
  REPAIR_REFUSAL=$1
  if [ "$REPAIR_EVIDENCE_ACTIVE" = 1 ] && [ "$RELAUNCH_ACTIVE" = 0 ]; then
    REPAIR_STATE=refused
    journal_write "failed:preflight" ${CHECKPOINT_LINES[@]+"${CHECKPOINT_LINES[@]}"} "rollback=prior-binding-kept" || true
  fi
  die "cwd repair of $ID refused: $1 (observed foreground_cwd=$(jq -cn --arg cwd "$REPAIR_SEEN" '$cwd'), recorded worktree='$WT', replacement-confirmed=$RELAUNCH_AGENT_CONFIRMED); no further launch authorized"
}

repair_read_path() { # <pane>
  local out
  REPAIR_SEEN=
  REPAIR_SEEN_PANE=$1
  out=$(fm_backend_herdr_cwd_repair_pane "$REPAIR_SESSION" "$REPAIR_WORKSPACE" "$REPAIR_TAB" "$1") \
    || return 1
  REPAIR_SEEN=$(printf '%s' "$out" | jq -er '
    .foreground_cwd
    | select(type == "string" and startswith("/"))
    | select(all(explode[]; . >= 32 and . != 127))
  ') || return 1
}

repair_shell_pid() { # <pane>
  [ "$(fm_backend_herdr_pane_agent_state "$REPAIR_SESSION" "$1")" = no-agent ] || return 1
  fm_backend_herdr_pane_idle_shell_pid "$REPAIR_SESSION" "$1" interactive
}

repair_tab_shape() { # <expected-pane>...
  local out expected
  expected=$(printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1] | sort') || return 1
  out=$(fm_backend_herdr_cli "$REPAIR_SESSION" pane list --workspace "$REPAIR_WORKSPACE") || return 1
  printf '%s' "$out" | jq -e --arg tab "$REPAIR_TAB" --arg ws "$REPAIR_WORKSPACE" --argjson expected "$expected" '
    (.result.panes | type) == "array"
    and ([.result.panes[] | select(.tab_id == $tab) | select(.workspace_id == $ws) | .pane_id] | sort) == $expected
  ' >/dev/null 2>&1
}

repair_project_check() {
  local project primary primary_top common target_common
  project=$(fm_backend_meta_exact_value "$META" project) || repair_refuse "ambiguous project binding"
  case "$project" in
    projects/*) project="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/${project#projects/}" ;;
  esac
  primary=$(CDPATH='' cd -- "$project" 2>/dev/null && pwd -P) || repair_refuse "project path cannot be resolved"
  primary_top=$(git -C "$primary" rev-parse --show-toplevel 2>/dev/null) || repair_refuse "project is not a Git worktree"
  primary_top=$(CDPATH='' cd -- "$primary_top" && pwd -P) || repair_refuse "project root cannot be resolved"
  [ "$primary" = "$primary_top" ] || repair_refuse "project binding is not its Git root"
  REPAIR_TARGET=$(CDPATH='' cd -- "$WT" && pwd -P) || repair_refuse "worktree cannot be resolved"
  if [ "$REPAIR_TARGET" = "$primary" ]; then
    REPAIR_TARGET_STATUS='primary-copy'
    repair_refuse "recorded worktree is the primary project copy"
  fi
  common=$(git -C "$primary" rev-parse --path-format=absolute --git-common-dir) || repair_refuse "project family cannot be read"
  target_common=$(git -C "$REPAIR_TARGET" rev-parse --path-format=absolute --git-common-dir) || repair_refuse "worktree family cannot be read"
  common=$(CDPATH='' cd -- "$common" && pwd -P) || repair_refuse "project family cannot be resolved"
  target_common=$(CDPATH='' cd -- "$target_common" && pwd -P) || repair_refuse "worktree family cannot be resolved"
  if [ "$common" != "$target_common" ]; then
    REPAIR_TARGET_STATUS=conflicting-project-family
    repair_refuse "recorded worktree belongs to a conflicting project family"
  fi
  REPAIR_TARGET_STATUS=validated
}

repair_prior_refusal_retryable() {
  [ "$(fm_meta_get "$JOURNAL" phase)" = failed:preflight ] \
    && [ "$(fm_meta_get "$JOURNAL" rollback)" = prior-binding-kept ] \
    && [ -z "$(fm_meta_get "$JOURNAL" repair_new_pane)" ] \
    && [ "$(fm_meta_get "$JOURNAL" repair_published)" = 0 ] \
    && [ "$(fm_meta_get "$JOURNAL" repair_publication_attempted)" = 0 ] \
    && { [ "$(fm_meta_get "$JOURNAL" repair_brief_outcome)" = not-attempted ] \
         || [ "$(fm_meta_get "$JOURNAL" repair_brief_outcome)" = unchanged ]; } \
    && [ "$(fm_meta_get "$JOURNAL" backend)" = "$BACKEND" ] \
    && [ "$(fm_meta_get "$JOURNAL" endpoint)" = "$T" ] \
    && [ "$(fm_meta_get "$JOURNAL" repair_session)" = "$(fm_meta_get "$META" herdr_session)" ] \
    && [ "$(fm_meta_get "$JOURNAL" repair_workspace)" = "$(fm_meta_get "$META" herdr_workspace_id)" ] \
    && [ "$(fm_meta_get "$JOURNAL" repair_tab)" = "$(fm_meta_get "$META" herdr_tab_id)" ] \
    && [ "$(fm_meta_get "$JOURNAL" repair_old_pane)" = "$(fm_meta_get "$META" herdr_pane_id)" ]
}

repair_projection_check() {
  local journal="$STATE/$ID.herdr-presentation" home
  [ -e "$journal" ] || [ -L "$journal" ] || return 0
  fm_backend_herdr_projection_journal_snapshot "$journal" "$ID" || repair_refuse "invalid presentation binding"
  home=$(CDPATH='' cd -- "$FM_HOME" && pwd -P) || repair_refuse "home cannot be resolved"
  [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_HOME" = "$home" ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" = "$REPAIR_SESSION" ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" = "$REPAIR_WORKSPACE" ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" = "$REPAIR_TAB" ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" = "$REPAIR_OLD_PANE" ] \
    || repair_refuse "presentation binding contradicts the task endpoint"
  fm_backend_herdr_projection_live_binding_matches "$REPAIR_SESSION" \
    "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" "$REPAIR_WORKSPACE" "$REPAIR_TAB" "$REPAIR_OLD_PANE" \
    "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL" \
    "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" \
    || repair_refuse "presentation does not have its exact live binding"
  REPAIR_PROJECTION=pending
}

repair_begin() {
  REPAIR_SESSION=$(fm_meta_get "$META" herdr_session)
  REPAIR_WORKSPACE=$(fm_meta_get "$META" herdr_workspace_id)
  REPAIR_TAB=$(fm_meta_get "$META" herdr_tab_id)
  REPAIR_OLD_PANE=$(fm_meta_get "$META" herdr_pane_id)
  REPAIR_TARGET_RECORDED=$WT
  REPAIR_EVIDENCE_ACTIVE=1
  journal_write preflight || die "could not persist cwd repair preflight evidence"
  [ "$BACKEND" = herdr ] || repair_refuse "--repair-cwd supports Herdr only"
  case "$KIND" in ship|scout) ;; *) repair_refuse "--repair-cwd supports ship/scout tasks only" ;; esac
  if fm_backend_source herdr && repair_read_path "$REPAIR_OLD_PANE"; then
    REPAIR_SOURCE=$REPAIR_SEEN
    REPAIR_SOURCE_STATUS=observed
  else
    REPAIR_SOURCE_STATUS=unconfirmed
  fi
  journal_write preflight || repair_refuse "could not persist cwd repair path evidence"
}

repair_preflight() {
  local focus path
  fm_backend_source herdr || repair_refuse "Herdr adapter unavailable"
  REPAIR_SESSION_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$REPAIR_SESSION") || repair_refuse "session lock unavailable"
  fm_lock_try_acquire "$REPAIR_SESSION_LOCK" || repair_refuse "another session layout operation is active"
  repair_read_path "$REPAIR_OLD_PANE" || repair_refuse "old pane identity or foreground path is ambiguous"
  REPAIR_SOURCE=$REPAIR_SEEN
  REPAIR_SOURCE_STATUS=observed
  repair_project_check
  path=$(CDPATH='' cd -- "$REPAIR_SOURCE" 2>/dev/null && pwd -P) || repair_refuse "old foreground path cannot be resolved"
  [ "$path" != "$REPAIR_TARGET" ] || repair_refuse "there is no foreground directory mismatch to repair"
  REPAIR_OLD_PID=$(repair_shell_pid "$REPAIR_OLD_PANE") || repair_refuse "old endpoint is not a positively agent-free lone idle shell"
  # The focus-safe close owner deliberately refuses the active tab. Detect that
  # before allocation, not after a replacement is already running.
  focus=$(fm_backend_herdr_projection_focus_snapshot "$REPAIR_SESSION") || repair_refuse "focus cannot be captured"
  [ "${focus#*$'\t'}" != "$REPAIR_TAB" ] || repair_refuse "task tab is active; focus another tab before repair"
  repair_tab_shape "$REPAIR_OLD_PANE" || repair_refuse "task tab has ambiguous or additional panes"
  repair_projection_check
}

repair_verify_new() {
  local count=0 path
  for _ in $(seq 1 10); do
    repair_read_path "$REPAIR_NEW_PANE" || repair_refuse "replacement pane identity or foreground path is ambiguous"
    [ "$(fm_backend_herdr_pane_agent_state "$REPAIR_SESSION" "$REPAIR_NEW_PANE")" = no-agent ] \
      || repair_refuse "replacement pane is not positively agent-free"
    path=$(CDPATH='' cd -- "$REPAIR_SEEN" 2>/dev/null && pwd -P) || repair_refuse "replacement foreground path cannot be resolved"
    if [ "$path" = "$REPAIR_TARGET" ]; then
      count=$((count + 1))
    else
      count=0
    fi
    [ "$count" -lt 2 ] || return 0
    sleep "$POLL"
  done
  repair_refuse "replacement did not have two consecutive matching canonical directory reads"
}

repair_close_unadopted() {
  local pid
  [ "$REPAIR_NEW_OWNED" = 1 ] || return 1
  fm_backend_herdr_cwd_repair_pane "$REPAIR_SESSION" "$REPAIR_WORKSPACE" "$REPAIR_TAB" "$REPAIR_NEW_PANE" >/dev/null || return 1
  pid=$(repair_shell_pid "$REPAIR_NEW_PANE") || return 1
  fm_backend_herdr_projection_close_pane_focus_preserving "$REPAIR_SESSION" "$REPAIR_NEW_PANE" no-agent "$pid" interactive
}

# The metadata owner can report failure AFTER rename (for example when its
# post-publication inspection fails). Observe the durable binding before any
# rollback decision so an adopted pane is never removed as an orphan.
repair_observe_publication() {
  if fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null 2>&1; then
    case "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" in
      "herdr:$REPAIR_SESSION:$REPAIR_NEW_PANE")
        REPAIR_PUBLISHED=1
        REPAIR_STATE=published
        T="$REPAIR_SESSION:$REPAIR_NEW_PANE"
        return 0
        ;;
      "herdr:$REPAIR_SESSION:$REPAIR_OLD_PANE") return 0 ;;
    esac
  fi
  REPAIR_STATE=publication-unconfirmed
  return 1
}

repair_observe_projection() {
  local journal="$STATE/$ID.herdr-presentation" home
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    REPAIR_PROJECTION=unconfirmed
    return 1
  }
  if fm_backend_herdr_projection_journal_snapshot "$journal" "$ID" \
      && [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ] \
      && [ "$FM_BACKEND_HERDR_JOURNAL_HOME" = "$home" ] \
      && [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" = "$REPAIR_SESSION" ] \
      && [ "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" = "$REPAIR_WORKSPACE" ] \
      && [ "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" = "$REPAIR_TAB" ]; then
    case "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" in
      "$REPAIR_OLD_PANE") REPAIR_PROJECTION=pending; return 0 ;;
      "$REPAIR_NEW_PANE") REPAIR_PROJECTION=rebound; return 0 ;;
    esac
  fi
  REPAIR_PROJECTION=unconfirmed
  return 1
}

repair_replace() {
  local out focus tmp new_path pid
  REPAIR_META_LOCK=$(fm_meta_lock_path "$META") || repair_refuse "metadata lock unavailable"
  fm_lock_acquire_wait "$REPAIR_META_LOCK"
  # Read-modify-publish starts from the latest bytes under the common metadata
  # lock. Never restore a stale full-file backup over a concurrent writer.
  fm_backend_validate_task_endpoint "$META" "$ID" || repair_refuse "task identity changed"
  [ "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" = "herdr:$T" ] \
    && [ "$(fm_meta_get "$META" worktree)" = "$WT" ] \
    && [ "$(fm_meta_get "$META" project)" = "$(fm_meta_get "$META_PRIOR" project)" ] \
    && [ "$(fm_meta_get "$META" herdr_workspace_id)" = "$REPAIR_WORKSPACE" ] \
    && [ "$(fm_meta_get "$META" herdr_tab_id)" = "$REPAIR_TAB" ] \
    || repair_refuse "task binding changed before replacement"
  repair_read_path "$REPAIR_OLD_PANE" || repair_refuse "old pane changed before replacement"
  [ "$REPAIR_SEEN" = "$REPAIR_SOURCE" ] || repair_refuse "old foreground directory changed before replacement"
  pid=$(repair_shell_pid "$REPAIR_OLD_PANE") || repair_refuse "old shell acquired conflicting ownership"
  [ "$pid" = "$REPAIR_OLD_PID" ] || repair_refuse "old shell process identity changed"
  repair_tab_shape "$REPAIR_OLD_PANE" || repair_refuse "task tab changed before replacement"
  focus=$(fm_backend_herdr_projection_focus_snapshot "$REPAIR_SESSION") || repair_refuse "focus cannot be captured before replacement"
  [ "${focus#*$'\t'}" != "$REPAIR_TAB" ] || repair_refuse "task tab became active"
  REPAIR_STATE=creating
  journal_write repairing "${CHECKPOINT_LINES[@]}"
  # This API operation, not shell input, establishes the replacement cwd.
  # No text, reset, signal, or key is ever sent to the preserved old shell.
  out=$(fm_backend_herdr_cli "$REPAIR_SESSION" pane split --pane "$REPAIR_OLD_PANE" \
    --direction right --cwd "$REPAIR_TARGET" --no-focus) || repair_refuse "pane split failed; creation outcome is unconfirmed"
  REPAIR_NEW_PANE=$(printf '%s' "$out" | jq -er --arg old "$REPAIR_OLD_PANE" \
    --arg ws "$REPAIR_WORKSPACE" --arg tab "$REPAIR_TAB" '
      select(.error == null and .result.type == "pane_info")
      | .result.pane | select(.workspace_id == $ws and .tab_id == $tab)
      | .pane_id | select(type == "string" and . != $old and test("^[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$"))
    ') || repair_refuse "pane split returned no unambiguous sibling identity"
  REPAIR_NEW_OWNED=1
  REPAIR_STATE=created
  journal_write repairing "${CHECKPOINT_LINES[@]}"
  fm_backend_herdr_projection_focus_restore "$REPAIR_SESSION" "$focus" "cwd repair split" \
    || repair_refuse "split focus restoration failed"
  repair_tab_shape "$REPAIR_OLD_PANE" "$REPAIR_NEW_PANE" || repair_refuse "replacement is not the only new sibling"
  repair_verify_new
  # Revalidate filesystem identity after shell startup; a startup hook must not
  # turn a previously valid path into a different or primary project copy.
  new_path=$REPAIR_TARGET
  safe_checkpoint
  repair_project_check
  [ "$REPAIR_TARGET" = "$new_path" ] || repair_refuse "worktree resolution changed during pane creation"
  repair_shell_pid "$REPAIR_NEW_PANE" >/dev/null || repair_refuse "replacement shell has conflicting ownership"
  # Startup and verification take time. Do not publish a second endpoint if
  # the old shell acquired an agent or changed identity while the sibling was
  # being prepared, even though the cooperating lifecycle owners are locked.
  repair_read_path "$REPAIR_OLD_PANE" || repair_refuse "old pane identity changed during replacement"
  [ "$REPAIR_SEEN" = "$REPAIR_SOURCE" ] || repair_refuse "old directory changed during replacement"
  pid=$(repair_shell_pid "$REPAIR_OLD_PANE") || repair_refuse "old shell acquired conflicting ownership during replacement"
  [ "$pid" = "$REPAIR_OLD_PID" ] || repair_refuse "old shell process changed during replacement"
  tmp=$(mktemp "$STATE/.${ID}.cwd-repair.XXXXXX") || repair_refuse "could not stage endpoint binding"
  if ! awk -v endpoint="$REPAIR_SESSION:$REPAIR_NEW_PANE" -v pane="$REPAIR_NEW_PANE" '
      /^window=/ { print "window=" endpoint; next }
      /^herdr_pane_id=/ { print "herdr_pane_id=" pane; next }
      { print }
    ' "$META" > "$tmp" \
    || ! fm_backend_validate_task_endpoint "$tmp" "$ID"; then
    rm -f "$tmp"
    repair_refuse "could not stage an exact replacement binding"
  fi
  REPAIR_PUBLICATION_ATTEMPTED=1
  journal_write repairing "${CHECKPOINT_LINES[@]}"
  if ! fm_backlog_atomic_transition publish "$tmp" "$META" "task record" "$STATE"; then
    rm -f "$tmp"
    repair_observe_publication || true
    repair_refuse "atomic endpoint publication failed"
  fi
  repair_observe_publication || repair_refuse "endpoint publication outcome cannot be confirmed"
  [ "$REPAIR_PUBLISHED" = 1 ] || repair_refuse "endpoint publication did not adopt the replacement"
  journal_write repaired "${CHECKPOINT_LINES[@]}"
  if [ "$REPAIR_PROJECTION" = pending ]; then
    if ! fm_backend_herdr_projection_journal_replace_endpoint "$STATE/$ID.herdr-presentation" "$ID" \
        "$REPAIR_TAB" "$REPAIR_OLD_PANE" "$REPAIR_TAB" "$REPAIR_NEW_PANE"; then
      repair_observe_projection || true
      repair_refuse "new task binding published but presentation binding could not be advanced"
    fi
    REPAIR_PROJECTION=rebound
    journal_write repaired "${CHECKPOINT_LINES[@]}"
  fi
  fm_lock_release "$REPAIR_META_LOCK"
  REPAIR_META_LOCK=
}

repair_finish() {
  local pid
  repair_tab_shape "$REPAIR_OLD_PANE" "$REPAIR_NEW_PANE" || repair_refuse "replacement is running but sibling ownership changed"
  if ! journal_write retiring "${CHECKPOINT_LINES[@]}"; then
    repair_refuse "replacement is running but retirement evidence could not be persisted; old pane retained"
  fi
  repair_read_path "$REPAIR_OLD_PANE" || repair_refuse "replacement is running but old pane identity cannot be confirmed for retirement"
  [ "$REPAIR_SEEN" = "$REPAIR_SOURCE" ] || repair_refuse "replacement is running but old pane directory changed; old pane retained"
  pid=$(repair_shell_pid "$REPAIR_OLD_PANE") || repair_refuse "replacement is running but old pane has conflicting ownership; old pane retained"
  [ "$pid" = "$REPAIR_OLD_PID" ] || repair_refuse "replacement is running but old shell process changed; old pane retained"
  REPAIR_OLD_OUTCOME=retirement-unconfirmed
  if fm_backend_herdr_projection_close_pane_focus_preserving "$REPAIR_SESSION" "$REPAIR_OLD_PANE" no-agent "$REPAIR_OLD_PID" interactive; then
    REPAIR_OLD_OUTCOME=removed
  else
    [ "$(fm_backend_herdr_pane_agent_state "$REPAIR_SESSION" "$REPAIR_OLD_PANE")" != dead ] || REPAIR_OLD_OUTCOME=removed
    repair_refuse "replacement is running but focus-safe old-pane retirement failed"
  fi
  REPAIR_STATE=complete
}

repair_restore_prior_brief() {
  [ "$REPAIR_BRIEF_BACKUP_VALID" = 1 ] \
    && [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ] || return 1
  cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" || true
  if cmp -s "$BRIEF_PRIOR" "$RELAUNCH_BRIEF"; then
    REPAIR_BRIEF_OUTCOME=unchanged
    return 0
  fi
  REPAIR_BRIEF_OUTCOME=mutation-unconfirmed
  return 1
}

repair_rollback() {
  local phase=$RELAUNCH_PHASE rollback pane_rollback=none
  if [ "$REPAIR_PUBLICATION_ATTEMPTED" = 1 ] && [ "$REPAIR_PUBLISHED" = 0 ]; then
    repair_observe_publication || true
  fi
  # shellcheck disable=SC2034 # The caller's EXIT transaction guard reads it.
  RELAUNCH_ACTIVE=0
  if [ "$REPAIR_STATE" = publication-unconfirmed ]; then
    rollback=publication-unconfirmed
    echo "error: cwd repair cannot prove which binding was published; both panes and the progress note are retained for reconciliation" >&2
  elif [ "$REPAIR_PUBLISHED" = 1 ]; then
    rollback=new-binding-kept
    echo "error: cwd repair published $T; its accurate binding and progress note are retained (replacement-confirmed=$RELAUNCH_AGENT_CONFIRMED); old pane $REPAIR_OLD_PANE outcome=$REPAIR_OLD_OUTCOME" >&2
  else
    rollback='prior-binding-kept'
    if [ "$REPAIR_STATE" = creating ]; then
      rollback=creation-unconfirmed
    elif [ "$REPAIR_NEW_OWNED" = 1 ]; then
      if repair_close_unadopted; then
        REPAIR_STATE=rolled-back
        rollback=unadopted-pane-removed
      elif [ "$(fm_backend_herdr_pane_agent_state "$REPAIR_SESSION" "$REPAIR_NEW_PANE")" = dead ]; then
        REPAIR_STATE=cleanup-unconfirmed
        rollback=unadopted-pane-removed-focus-unconfirmed
      else
        rollback=unadopted-pane-kept
      fi
    else
      REPAIR_STATE=rolled-back
    fi
    pane_rollback=$rollback
    if repair_restore_prior_brief; then
      echo "error: cwd repair did not publish a new task binding; $rollback (new-pane=${REPAIR_NEW_PANE:-unconfirmed}); original instructions and work are preserved" >&2
    else
      REPAIR_STATE=brief-mutation-unconfirmed
      rollback=brief-mutation-unconfirmed
      echo "error: cwd repair did not publish a new task binding; pane outcome=$pane_rollback, but instruction restoration is unconfirmed and requires reconciliation" >&2
    fi
  fi
  journal_write "failed:$phase" "${CHECKPOINT_LINES[@]}" "rollback=$rollback" "pane_rollback=$pane_rollback" || true
}
