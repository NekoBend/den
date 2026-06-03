#!/bin/sh
# wrappers.sh — CLI tool wrapper functions (modern tool → native fallback).
# Sourced by init.bash / init.zsh. Requires _helpers.sh loaded first.
# Deploy target: ~/.config/shell/wrappers.sh

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

# Guard: ensure _helpers.sh is loaded
if ! type _wrap >/dev/null 2>&1; then
    _hf="${HOME}/.config/shell/_helpers.sh"
    [ -f "$_hf" ] && . "$_hf"; unset _hf
fi

# ===== Toggle-aware wrappers (_wrap) =====
# _wrap <func> <modern> <modern_flags> <fallback> <fallback_flags>

_wrap cat      bat  "--style=plain --paging=never"  cat  ""
_wrap find     fd   ""                               find ""
_wrap grep     rg   ""                               grep "--color=auto"
_wrap la       lsd  "-a"                             ls   "-A --color=auto"
_wrap ll       lsd  "-l"                             ls   "-lF --color=auto"
_wrap lla      lsd  "-la"                            ls   "-laF --color=auto"
_wrap llt      lsd  "-l --tree"                      ""   ""
_wrap ls       lsd  ""                               ls   "--color=auto"
_wrap lt       lsd  "--tree"                         ""   ""
_wrap ripgrep  rg   ""                               ""   ""

# ===== Always-modern w-suffix bypasses (_wsfx) =====
# _wsfx <func> <modern> <modern_flags>

_wsfx catw   bat  "--style=plain --paging=never"
_wsfx findw  fd   ""
_wsfx grepw  rg   ""
_wsfx lsw    lsd  ""
