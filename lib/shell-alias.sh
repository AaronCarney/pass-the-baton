#!/usr/bin/env bash
# lib/shell-alias.sh - sourceable helpers to install/remove a marker-guarded shell
# alias in the user's rc file. Consumed by the installer opt-in (tools/install.sh) and
# the /baton dashboard launch_alias key (tools/baton-dashboard.sh). POSIX-ish; ships OSS.

_ALIAS_MARK_BEGIN='# >>> baton launch alias >>>'
_ALIAS_MARK_END='# <<< baton launch alias <<<'

# Hardcoded builtin/keyword deny-lists (compgen needs bash; keep explicit so the check
# works under any POSIX sh that sources this file).
_ALIAS_BUILTINS='cd echo test [ [[ pwd read printf export unset alias unalias set shift eval exec source . type command builtin true false wait jobs kill trap umask hash help let local readonly return times ulimit'
_ALIAS_KEYWORDS='if then else elif fi for while until do done case esac function select in time coproc'

alias_name_valid() {
  # 0 = usable. Distinct nonzero code per rejection reason so callers warn precisely:
  #   1 empty | 2 bad token | 3 shell builtin | 4 shell keyword | 5 shadows a PATH command
  # arg2 (sentinel) is a name the caller is intentionally reclaiming; a name equal to the
  # sentinel skips the PATH-shadow check so re-running the installer/dashboard can rewrite
  # an alias it itself put on PATH.
  local name="$1" sentinel="${2:-}"
  [ -n "$name" ] || return 1
  case "$name" in
    *[!A-Za-z0-9_-]* | [!A-Za-z_]*) return 2 ;;
  esac
  local b
  for b in $_ALIAS_BUILTINS; do [ "$name" = "$b" ] && return 3; done
  for b in $_ALIAS_KEYWORDS; do [ "$name" = "$b" ] && return 4; done
  if [ "$name" != "$sentinel" ] && command -v "$name" >/dev/null 2>&1; then
    return 5
  fi
  return 0
}

alias_rc_files() {
  # Echo the rc file(s) to edit, one per line. Detect bash (~/.bashrc) and zsh (~/.zshrc);
  # print each that exists. If neither exists, create ~/.bashrc (documented default) and
  # print it, so a caller always has at least one target.
  local printed=0
  if [ -f "$HOME/.bashrc" ]; then printf '%s\n' "$HOME/.bashrc"; printed=1; fi
  if [ -f "$HOME/.zshrc" ]; then printf '%s\n' "$HOME/.zshrc"; printed=1; fi
  if [ "$printed" -eq 0 ]; then
    : > "$HOME/.bashrc"
    printf '%s\n' "$HOME/.bashrc"
  fi
}

alias_write() {
  # Idempotently write a marker-guarded alias block to rc_file. Replaces an existing block
  # in place (awk splice between markers); otherwise appends after ensuring a trailing
  # newline. Never duplicates.
  local name="$1" target_cmd="$2" rc_file="$3"
  [ -n "$name" ] && [ -n "$target_cmd" ] && [ -n "$rc_file" ] || return 1
  # Escape single quotes so an install path containing an apostrophe (e.g.
  # /home/o'brien/...) cannot break the single-quoted alias body (synthetic path; publish-home-ok).  '  ->  '\''
  local esc_target
  esc_target=$(printf '%s' "$target_cmd" | sed "s/'/'\\\\''/g")
  local block
  block="${_ALIAS_MARK_BEGIN}
alias ${name}='${esc_target}'
${_ALIAS_MARK_END}"
  if [ -f "$rc_file" ] && grep -qF "$_ALIAS_MARK_BEGIN" "$rc_file"; then
    local tmp; tmp=$(mktemp "${rc_file}.baton.XXXXXX")
    awk -v b="$_ALIAS_MARK_BEGIN" -v e="$_ALIAS_MARK_END" -v repl="$block" '
      $0==b {inblk=1; print repl; next}
      $0==e && inblk {inblk=0; next}
      !inblk {print}
    ' "$rc_file" > "$tmp" && cat "$tmp" > "$rc_file"
    rm -f "$tmp" 2>/dev/null || true
  else
    touch "$rc_file"
    # Ensure a trailing newline before appending so the marker never fuses onto the last
    # line (mirrors the .gitignore-append guard in tools/install.sh around the .baton/ append).
    if [ -s "$rc_file" ] && [ "$(tail -c1 "$rc_file" | od -An -tx1 | tr -d ' \n')" != "0a" ]; then
      printf '\n' >> "$rc_file"
    fi
    printf '%s\n' "$block" >> "$rc_file"
  fi
}
