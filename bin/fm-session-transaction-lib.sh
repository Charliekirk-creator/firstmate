#!/usr/bin/env bash
# Evidence preflight for the shared Main/planning .lock.acquire transaction.
# Sourcing callers must load fm-wake-lib.sh first; it alone owns acquisition,
# recursive orphan recovery, freshness, bounded caller retries, and release.
# This preflight refuses malformed evidence, including symlinked owner files.
fm_session_transaction_evidence_valid() {
  local lock=$1 depth=${2:-0} owner pid absolute invalid=0 current
  [ "$depth" -lt 16 ] || return 1
  if [ -e "$lock" ] || [ -L "$lock" ]; then
    owner=$(fm_lock_link_owner "$lock" 2>/dev/null) || owner=
    absolute=$(fm_lock_abs_path "$lock") || return 1
    case "$owner" in "$absolute".owner.*) ;; *) invalid=1 ;; esac
    if [ "$invalid" -eq 0 ]; then
      [ -d "$owner" ] && [ ! -L "$owner" ] || invalid=1
      [ -f "$owner/pid" ] && [ ! -L "$owner/pid" ] || invalid=1
      pid=$(cat "$owner/pid" 2>/dev/null) || invalid=1
      case "$pid" in ''|*[!0-9]*) invalid=1 ;; *) [ "$pid" -gt 1 ] || invalid=1 ;; esac
    fi
    if [ "$invalid" -eq 1 ]; then
      # An exact-owner release removes the link before its owner directory.
      # Recheck a changing snapshot instead of reporting that normal race as
      # corruption; stable malformed evidence is still refused, never deleted.
      [ -e "$lock" ] || [ -L "$lock" ] || return 0
      current=$(fm_lock_link_owner "$lock" 2>/dev/null) || current=
      if [ "$current" != "$owner" ]; then
        fm_session_transaction_evidence_valid "$lock" "$((depth + 1))"
        return $?
      fi
      return 1
    fi
  fi
  if [ -e "$lock.steal" ] || [ -L "$lock.steal" ]; then
    fm_session_transaction_evidence_valid "$lock.steal" "$((depth + 1))" || return 1
  fi
}
