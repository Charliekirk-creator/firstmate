#!/usr/bin/env bash

fm_backend_worktree_request_file_links() {
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%l' "$1" 2>/dev/null
  else
    stat -c '%h' "$1" 2>/dev/null
  fi
}

fm_backend_worktree_request_file_inode() {
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%d:%i' "$1" 2>/dev/null
  else
    stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

fm_backend_worktree_request_file_content_valid() {
  local path=$1 value=$2 bytes expected
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  bytes=$(LC_ALL=C wc -c < "$path" | tr -d ' ') || return 1
  expected=$((${#value} + 1))
  [ "$bytes" = "$expected" ] || return 1
  printf '%s\n' "$value" | cmp -s "$path" -
}

fm_backend_worktree_request_file_valid() {
  local path=$1 value=$2 links
  fm_backend_worktree_request_file_content_valid "$path" "$value" || return 1
  links=$(fm_backend_worktree_request_file_links "$path") || return 1
  [ "$links" = 1 ]
}

fm_backend_worktree_request_recover_candidate() {
  local candidate=$1 target=$2 value=$3 candidate_links target_links candidate_inode target_inode
  [ -n "$candidate" ] || return 0
  fm_backend_worktree_request_file_content_valid "$candidate" "$value" || return 1
  candidate_links=$(fm_backend_worktree_request_file_links "$candidate") || return 1
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    if [ "$value" = attempted ]; then
      [ "$candidate_links" = 1 ] || return 1
      rm -f -- "$candidate"
      return
    fi
    [ "$candidate_links" = 1 ] || return 1
    command link "$candidate" "$target" 2>/dev/null || {
      [ -e "$target" ] || [ -L "$target" ] || return 1
    }
  fi
  [ -f "$target" ] && [ ! -L "$target" ] || return 1
  target_links=$(fm_backend_worktree_request_file_links "$target") || return 1
  candidate_links=$(fm_backend_worktree_request_file_links "$candidate") || return 1
  [ "$target_links" = 2 ] && [ "$candidate_links" = 2 ] || return 1
  target_inode=$(fm_backend_worktree_request_file_inode "$target") || return 1
  candidate_inode=$(fm_backend_worktree_request_file_inode "$candidate") || return 1
  [ "$target_inode" = "$candidate_inode" ] || return 1
  rm -f -- "$candidate" || return 1
  fm_backend_worktree_request_file_valid "$target" "$value"
}

fm_backend_worktree_request_ack_state() {
  local ack_dir=$1 entry name attempted_candidate= accepted_candidate= attempted accepted
  if [ ! -e "$ack_dir" ] && [ ! -L "$ack_dir" ]; then
    printf 'absent'
    return 0
  fi
  [ -d "$ack_dir" ] && [ ! -L "$ack_dir" ] || return 1
  for entry in "$ack_dir"/* "$ack_dir"/.[!.]* "$ack_dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    case "$name" in
      attempted|accepted) ;;
      .attempted.*)
        [ -z "$attempted_candidate" ] || return 1
        attempted_candidate=$entry
        ;;
      .accepted.*)
        [ -z "$accepted_candidate" ] || return 1
        accepted_candidate=$entry
        ;;
      *) return 1 ;;
    esac
  done
  attempted="$ack_dir/attempted"
  accepted="$ack_dir/accepted"
  fm_backend_worktree_request_recover_candidate "$attempted_candidate" "$attempted" attempted || return 1
  fm_backend_worktree_request_recover_candidate "$accepted_candidate" "$accepted" accepted || return 1
  if [ ! -e "$attempted" ] && [ ! -L "$attempted" ]; then
    [ ! -e "$accepted" ] && [ ! -L "$accepted" ] || return 1
    printf 'prepared'
    return 0
  fi
  fm_backend_worktree_request_file_valid "$attempted" attempted || return 1
  if [ ! -e "$accepted" ] && [ ! -L "$accepted" ]; then
    printf 'ambiguous'
    return 0
  fi
  fm_backend_worktree_request_file_valid "$accepted" accepted || return 1
  printf 'accepted'
}

fm_backend_worktree_request_phase_publish() {
  local ack_dir=$1 phase=$2 target tmp rc=0
  case "$phase" in attempted|accepted) ;; *) return 1 ;; esac
  target="$ack_dir/$phase"
  [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
  tmp=$(umask 077; mktemp "$ack_dir/.$phase.XXXXXX") || return 1
  printf '%s\n' "$phase" > "$tmp" && chmod 600 "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  command link "$tmp" "$target" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || {
    rm -f -- "$tmp"
    return 1
  }
  rm -f -- "$tmp" 2>/dev/null || true
}

fm_backend_worktree_request_ack_abort() {
  local ack_dir=$1 state
  state=$(fm_backend_worktree_request_ack_state "$ack_dir") || return 1
  [ "$state" = ambiguous ] || return 1
  rm -f -- "$ack_dir/attempted" || return 1
  rmdir -- "$ack_dir"
}

fm_backend_worktree_request_send_owned() {
  local send_fn=$1 target=$2 text=$3 ack_dir=$4 expected_label=${5:-} state rc=0
  state=$(fm_backend_worktree_request_ack_state "$ack_dir") || return 2
  if [ "$state" = absent ]; then
    mkdir -m 700 -- "$ack_dir" || return 2
    state=prepared
  fi
  [ "$state" = prepared ] || return 2
  fm_backend_worktree_request_phase_publish "$ack_dir" attempted || return 2
  "$send_fn" "$target" "$text" "$expected_label" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 3 ]; then
      fm_backend_worktree_request_ack_abort "$ack_dir" || return 2
    fi
    return "$rc"
  fi
  fm_backend_worktree_request_phase_publish "$ack_dir" accepted || return 2
}
