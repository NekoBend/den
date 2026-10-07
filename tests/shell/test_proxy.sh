#!/usr/bin/env bash
# test_proxy.sh — Tests for proxy.sh (named proxy profiles, env-only on/off).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

PROXY_SH_GUARDED="$DOTFILES/shell/posix/proxy.sh"
PROXY_SH="$TESTTMP/proxy_test.sh"
# proxy.sh puts its store in place with _den_put from _helpers.sh, which
# init.bash and init.zsh load first; the file the tests source loads both.
make_noninteractive_source_copy "$PROXY_SH_GUARDED" "$TESTTMP/proxy_only.sh"
printf ". '%s'\n. '%s'\n" "$DOTFILES/shell/posix/_helpers.sh" "$TESTTMP/proxy_only.sh" > "$PROXY_SH" ||
    abort_suite "cannot write $PROXY_SH"

# Isolate profile storage under WORK so tests never touch the real ~/.config.
export XDG_CONFIG_HOME="$WORK/xdg"
PROXY_CONF="$XDG_CONFIG_HOME/den/proxy.conf"

PROXY_DIR="$XDG_CONFIG_HOME/den"
DOTS="$WORK/dots"

reset_conf() { rm -f "$PROXY_CONF"; }

# modes - the octal modes of the store's directory and of the store.
modes() { stat -c '%a' "$PROXY_DIR" "$PROXY_CONF" | paste -sd' ' -; }

# A url with a password, which holds a : and an @ of its own, and how den shows it.
SECRET_URL='http://alice:S3cr:et@x@proxy.corp:8080'
SHOWN_URL='http://alice:***@proxy.corp:8080'
TAB=$(printf '\t')

# proxy_suite <shell> — run the same checks under bash and zsh. Each subcommand
# is chained inside ONE shell invocation because `on`/`off` only touch the
# current shell's env (a fresh `run_*` would not see a prior `on`).
proxy_suite() {
    local sh="$1"
    local run="run_${sh}"

    echo "================================================"
    echo "  Testing proxy.sh with ${sh}"
    echo "================================================"

    echo "[$sh] guard: non-interactive source skips proxy"
    actual=$("$sh" -c "source '$PROXY_SH_GUARDED'; type proxy >/dev/null 2>&1 && echo DEFINED || echo UNDEFINED" | tr -d '\r')
    assert_eq "$sh/guard non-interactive" "UNDEFINED" "$actual"

    reset_conf
    echo "[$sh] add + ls"
    actual=$("$run" "$PROXY_SH" "proxy add work http://proxy:8080 >/dev/null 2>&1; proxy ls" | tr -d '\r')
    assert_contains "$sh/ls shows name" "work" "$actual"
    assert_contains "$sh/ls shows url" "http://proxy:8080" "$actual"

    reset_conf
    echo "[$sh] on + status (same shell)"
    actual=$("$run" "$PROXY_SH" "proxy add work http://proxy:8080 >/dev/null 2>&1; proxy on work >/dev/null 2>&1; proxy status" | tr -d '\r')
    assert_contains "$sh/status active" "active: work" "$actual"
    assert_contains "$sh/status http_proxy" "http_proxy=http://proxy:8080" "$actual"
    assert_contains "$sh/status default no_proxy" "no_proxy=localhost,127.0.0.1,::1" "$actual"

    reset_conf
    echo "[$sh] on exports uppercase vars too"
    actual=$("$run" "$PROXY_SH" "proxy add work http://proxy:8080 >/dev/null 2>&1; proxy on work >/dev/null 2>&1; echo UC=\$HTTPS_PROXY" | tr -d '\r')
    assert_contains "$sh/uppercase HTTPS_PROXY" "UC=http://proxy:8080" "$actual"

    reset_conf
    echo "[$sh] on merges loopback defaults with the profile's no_proxy"
    actual=$("$run" "$PROXY_SH" "proxy add home http://h:3128 10.0.0.0/8 >/dev/null 2>&1; proxy on home >/dev/null 2>&1; proxy status" | tr -d '\r')
    assert_contains "$sh/merged no_proxy" "no_proxy=localhost,127.0.0.1,::1,10.0.0.0/8" "$actual"

    reset_conf
    echo "[$sh] on keeps '*' (bypass all) standalone"
    actual=$("$run" "$PROXY_SH" "proxy add all http://h:3128 '*' >/dev/null 2>&1; proxy on all >/dev/null 2>&1; proxy status" | tr -d '\r')
    assert_contains "$sh/star no_proxy" "no_proxy=*" "$actual"

    reset_conf
    echo "[$sh] off clears env + active"
    actual=$("$run" "$PROXY_SH" "proxy add work http://proxy:8080 >/dev/null 2>&1; proxy on work >/dev/null 2>&1; proxy off >/dev/null 2>&1; proxy status; echo UC=\$HTTP_PROXY" | tr -d '\r')
    assert_contains "$sh/off active none" "active: (none)" "$actual"
    assert_not_contains "$sh/off no leftover url" "proxy:8080" "$actual"
    assert_contains "$sh/off uppercase cleared" "UC=" "$actual"

    reset_conf
    echo "[$sh] add overwrites an existing name (no duplicate)"
    actual=$("$run" "$PROXY_SH" "proxy add work http://old:1 >/dev/null 2>&1; proxy add work http://new:2 >/dev/null 2>&1; proxy ls" | tr -d '\r')
    assert_contains "$sh/overwrite new url" "http://new:2" "$actual"
    assert_not_contains "$sh/overwrite drops old" "http://old:1" "$actual"

    reset_conf
    echo "[$sh] rm removes a profile"
    actual=$("$run" "$PROXY_SH" "proxy add work http://proxy:8080 >/dev/null 2>&1; proxy rm work >/dev/null 2>&1; proxy ls 2>&1" | tr -d '\r')
    assert_not_contains "$sh/rm gone" "http://proxy:8080" "$actual"

    reset_conf
    echo "[$sh] on a missing profile fails"
    actual=$("$run" "$PROXY_SH" "proxy add work http://proxy:8080 >/dev/null 2>&1; proxy on nope 2>&1; echo rc=\$?" | tr -d '\r')
    assert_contains "$sh/on missing message" "no such profile" "$actual"
    assert_contains "$sh/on missing rc" "rc=1" "$actual"

    reset_conf
    echo "[$sh] add rejects an invalid name"
    actual=$("$run" "$PROXY_SH" "proxy add 'bad name' http://x 2>&1; echo rc=\$?" | tr -d '\r')
    assert_contains "$sh/add invalid name msg" "must match" "$actual"
    assert_contains "$sh/add invalid name rc" "rc=1" "$actual"

    echo "[$sh] unknown command fails with usage"
    actual=$("$run" "$PROXY_SH" "proxy frobnicate 2>&1; echo rc=\$?" | tr -d '\r')
    assert_contains "$sh/unknown cmd msg" "unknown command" "$actual"
    assert_contains "$sh/unknown cmd rc" "rc=1" "$actual"

    reset_conf
    echo "[$sh] add, on, ls and status show a password as ***; the store and the env keep it"
    actual=$("$run" "$PROXY_SH" "proxy add c '$SECRET_URL' 2>&1; proxy on c 2>&1; proxy ls 2>&1; proxy status 2>&1; echo env=\$http_proxy" | tr -d '\r')
    assert_eq "$sh/password shown as ***" "proxy: saved 'c' -> $SHOWN_URL
proxy: on (c -> $SHOWN_URL)
* c${TAB}$SHOWN_URL
active: c
http_proxy=$SHOWN_URL
https_proxy=$SHOWN_URL
all_proxy=$SHOWN_URL
no_proxy=localhost,127.0.0.1,::1
env=$SECRET_URL" "$actual"
    assert_eq "$sh/store keeps the password" "c${TAB}$SECRET_URL${TAB}" "$(cat "$PROXY_CONF")"

    reset_conf
    echo "[$sh] a url without a password shows as it is; one without a scheme is masked too"
    actual=$("$run" "$PROXY_SH" "proxy add u http://bob@p:1 2>/dev/null; proxy add h p:3128 2>/dev/null; proxy add s 'bob:pw@p:2' 2>/dev/null; proxy ls" | tr -d '\r')
    assert_eq "$sh/only a password is masked" "  u${TAB}http://bob@p:1
  h${TAB}p:3128
  s${TAB}bob:***@p:2" "$actual"

    echo "[$sh] add makes the store 0600 in a 0700 directory, under umask 022"
    rm -rf "${PROXY_DIR:?}"
    "$run" "$PROXY_SH" "umask 022; proxy add c '$SECRET_URL' 2>/dev/null"
    assert_eq "$sh/new store modes" "700 600" "$(modes)"

    echo "[$sh] rm and add tighten an older den's 0644 store and 0755 directory"
    printf 'a\thttp://a:1\t\nb\thttp://b:1\t\n' > "$PROXY_CONF"
    chmod 755 "$PROXY_DIR"
    chmod 644 "$PROXY_CONF"
    "$run" "$PROXY_SH" "umask 022; proxy rm b 2>/dev/null"
    assert_eq "$sh/rm tightens both" "700 600" "$(modes)"
    chmod 755 "$PROXY_DIR"
    chmod 644 "$PROXY_CONF"
    "$run" "$PROXY_SH" "umask 022; proxy add c '$SECRET_URL' 2>/dev/null"
    assert_eq "$sh/add tightens both" "700 600" "$(modes)"

    # Mode 0200: the store can be written but not read. root reads it anyway,
    # so there the case is skipped.
    echo "[$sh] add leaves a store it cannot read as it was"
    printf 'a\thttp://a:1\t\n' > "$PROXY_CONF"
    if [ "$(id -u)" -ne 0 ] && chmod 200 "$PROXY_CONF" 2>/dev/null && [ ! -r "$PROXY_CONF" ]; then
        actual=$("$run" "$PROXY_SH" "proxy add n http://n:1 2>&1; echo rc=\$?" | tr -d '\r')
        chmod 600 "$PROXY_CONF"
        assert_contains "$sh/unreadable store: message" "proxy add: cannot read $PROXY_CONF; it is left as it was" "$actual"
        assert_contains "$sh/unreadable store: rc" "rc=1" "$actual"
        assert_eq "$sh/unreadable store: kept" "a${TAB}http://a:1${TAB}" "$(cat "$PROXY_CONF")"
    else
        echo "  SKIP: $sh/unreadable store (running as root)"
    fi

    echo "[$sh] add and rm write through a symlinked proxy.conf, as pwsh does"
    rm -rf "${DOTS:?}"
    mkdir -p "$DOTS"
    rm -f "$PROXY_CONF"
    printf 'a\thttp://a:1\t\n' > "$DOTS/proxy.conf"
    chmod 644 "$DOTS/proxy.conf"
    ln -s "$DOTS/proxy.conf" "$PROXY_CONF"
    "$run" "$PROXY_SH" "umask 022; proxy add b http://b:2 2>/dev/null; proxy rm a 2>/dev/null"
    assert_eq "$sh/symlink kept" "link" "$([ -L "$PROXY_CONF" ] && echo link || echo replaced)"
    assert_eq "$sh/symlink target updated, 0600" "b${TAB}http://b:2${TAB} 600" \
        "$(cat "$DOTS/proxy.conf") $(stat -c '%a' "$DOTS/proxy.conf")"
    rm -f "$PROXY_CONF"
    ln -s "$DOTS/new-proxy.conf" "$PROXY_CONF"
    "$run" "$PROXY_SH" "umask 022; proxy add n http://n:1 2>/dev/null"
    assert_eq "$sh/dangling symlink target created" "link n${TAB}http://n:1${TAB} 600" \
        "$([ -L "$PROXY_CONF" ] && echo link || echo replaced) $(cat "$DOTS/new-proxy.conf" 2>&1) $(stat -c '%a' "$DOTS/new-proxy.conf" 2>&1)"

    # An interactive shell has den's cat wrapper (wrappers.sh), a function
    # that runs bat with the user's bat config and prints a notice. The copy
    # through the symlink must not go through it.
    echo "[$sh] add writes through a symlinked proxy.conf with the native cat, not a cat function"
    printf 'a\thttp://a:1\t\n' > "$DOTS/proxy.conf"
    rm -f "$PROXY_CONF"
    ln -s "$DOTS/proxy.conf" "$PROXY_CONF"
    actual=$("$run" "$PROXY_SH" "cat() { echo '[den] cat -> bat' >&2; echo WRAPPED; }; proxy add b http://b:2 2>&1" | tr -d '\r')
    assert_eq "$sh/cat function: message" "proxy: saved 'b' -> http://b:2" "$actual"
    assert_eq "$sh/cat function: target updated" "a${TAB}http://a:1${TAB}
b${TAB}http://b:2${TAB}" "$(cat "$DOTS/proxy.conf")"
    rm -f "$PROXY_CONF"
}

proxy_suite bash
if command -v zsh >/dev/null 2>&1; then
    proxy_suite zsh
else
    echo "zsh not found; skipping zsh proxy tests"
fi

# =============================================================================
# History: a line that runs proxy add with a url that holds a password stays out
# of the history file; one without a password is saved as usual. Each case types
# its lines into a real interactive shell (bash -i, zsh -i) that reads them from
# a pipe, with HOME and HISTFILE in WORK, and reads the file the shell wrote.
# =============================================================================
HIST_DIR="$WORK/hist"
HIST_OUT="$HIST_DIR/out"
HIST_RC="$TESTTMP/hist_bashrc"
HIST_ZDOT="$TESTTMP/hist_zdot"
SECRET_LINE="proxy add c '$SECRET_URL'"
HIST_LINES=('echo before' "$SECRET_LINE" 'proxy add u http://bob@p:1' 'proxy add h p:3128 .corp' 'echo after')
HIST_KEPT='echo before
proxy add u http://bob@p:1
proxy add h p:3128 .corp
echo after'

# hist_bash <setup> <line>... - type the lines into bash -i, with <setup> run
# before proxy.sh loads; print the history file without its time stamp lines.
# What the shell printed is in HIST_OUT.
hist_bash() {
    local setup=$1 hf="$HIST_DIR/bash_history"
    shift
    rm -rf "${HIST_DIR:?}"
    mkdir -p "$HIST_DIR"
    printf '%s\n' "HISTFILE='$hf'" "$setup" ". '$DOTFILES/shell/posix/_helpers.sh'" ". '$PROXY_SH_GUARDED'" > "$HIST_RC"
    printf '%s\n' "$@" | env -i HOME="$HIST_DIR" PATH="$PATH" TERM=dumb XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
        bash --rcfile "$HIST_RC" -i > "$HIST_OUT" 2>&1
    grep -v '^#[0-9]' "$hf"
}

# hist_zsh <setup> <line>... - the same with zsh -i (no global rc files), with
# proxy.sh loaded twice, as a reload of the config would.
hist_zsh() {
    local setup=$1 hf="$HIST_DIR/zsh_history"
    shift
    rm -rf "${HIST_DIR:?}"
    mkdir -p "$HIST_DIR" "$HIST_ZDOT"
    printf '%s\n' 'setopt no_global_rcs' > "$HIST_ZDOT/.zshenv"
    printf '%s\n' "HISTFILE='$hf'; HISTSIZE=100; SAVEHIST=100" "$setup" ". '$DOTFILES/shell/posix/_helpers.sh'" \
        ". '$PROXY_SH_GUARDED'" ". '$PROXY_SH_GUARDED'" > "$HIST_ZDOT/.zshrc"
    printf '%s\n' "$@" | env -i HOME="$HIST_DIR" PATH="$PATH" TERM=dumb ZDOTDIR="$HIST_ZDOT" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
        zsh -i > "$HIST_OUT" 2>&1
    cat "$hf"
}

echo "================================================"
echo "  Testing proxy add and the history file"
echo "================================================"

reset_conf
echo "[bash] a password in proxy add keeps the line out of HISTFILE, under den's HISTCONTROL and a HISTTIMEFORMAT"
actual=$(hist_bash "HISTCONTROL=ignoreboth; HISTTIMEFORMAT='%F %T '" "${HIST_LINES[@]}")
assert_eq "bash/history: only the line with a password is left out" "$HIST_KEPT" "$actual"

reset_conf
echo "[bash] the same with a history -a in PROMPT_COMMAND and histappend"
actual=$(hist_bash "PROMPT_COMMAND='history -a'; shopt -s histappend" "${HIST_LINES[@]}")
assert_eq "bash/history: history -a in PROMPT_COMMAND writes no password" "$HIST_KEPT" "$actual"

# The line with a leading space is not saved (ignorespace); the entry before it
# holds no password, so it stays.
reset_conf
echo "[bash] a line HISTCONTROL left out does not cost the line before it"
actual=$(hist_bash 'HISTCONTROL=ignoreboth' 'echo before' " $SECRET_LINE" 'echo after')
assert_eq "bash/history: the entry before an ignored line stays" "echo before
echo after" "$actual"

echo "[bash] the user's HISTIGNORE is left as it was and still applies"
actual=$(hist_bash "HISTIGNORE='echo mine'" 'echo mine' "$SECRET_LINE" 'echo "HI=$HISTIGNORE"')
assert_eq "bash/history: HISTIGNORE still applies" "echo \"HI=\$HISTIGNORE\"" "$actual"
assert_contains "bash/history: HISTIGNORE unchanged" "HI=echo mine" "$(cat "$HIST_OUT")"

# A subshell has a copy of the history list: the line stays, and proxy says how
# to take it out.
echo "[bash] proxy add in a pipe says how to take the line out"
hist_bash '' 'echo before' "$SECRET_LINE 2>&1 | cat" > /dev/null
assert_contains "bash/history: subshell hint" "it ran in a subshell; run: history -d 2" "$(cat "$HIST_OUT")"

if command -v zsh >/dev/null 2>&1; then
    reset_conf
    echo "[zsh] a password in proxy add keeps the line out of HISTFILE"
    actual=$(hist_zsh '' "${HIST_LINES[@]}")
    assert_eq "zsh/history: only the line with a password is left out" "$HIST_KEPT" "$actual"

    # reload runs fc -W, which writes a line a zshaddhistory hook kept in memory
    # only (status 2); fc -A does the same.
    for w in 'fc -W' 'fc -A'; do
        reset_conf
        echo "[zsh] $w (reload runs fc -W) writes no password"
        actual=$(hist_zsh '' "${HIST_LINES[@]}" "$w")
        assert_not_contains "zsh/history: $w writes no password" "S3cr" "$actual"
        assert_contains "zsh/history: $w keeps the line without one" "proxy add u http://bob@p:1" "$actual"
    done

    for opt in inc_append_history share_history; do
        reset_conf
        echo "[zsh] the same under setopt $opt"
        actual=$(hist_zsh "setopt $opt" "${HIST_LINES[@]}")
        assert_eq "zsh/history: $opt writes no password" "$HIST_KEPT" "$actual"
    done

    # den's hook goes next to a zshaddhistory function of the user's own, which
    # still leaves its lines out, as HISTORY_IGNORE does; loading proxy.sh twice
    # adds the hook once.
    reset_conf
    echo "[zsh] the user's zshaddhistory and HISTORY_IGNORE still apply"
    actual=$(hist_zsh "zshaddhistory() { case \$1 in *mine*) return 1 ;; esac; return 0; }; HISTORY_IGNORE='echo theirs'" \
        'echo mine' 'echo theirs' "$SECRET_LINE" 'proxy add u http://bob@p:1' 'echo "hooks=${#zshaddhistory_functions}"')
    assert_eq "zsh/history: the user's hook and HISTORY_IGNORE still apply" "proxy add u http://bob@p:1
echo \"hooks=\${#zshaddhistory_functions}\"" "$actual"
    assert_contains "zsh/history: den's hook added once" "hooks=1" "$(cat "$HIST_OUT")"
fi

# pwsh port: same proxy.conf store + same no_proxy loopback logic. on/off/status
# chain inside ONE run_pwsh (env vars only live in that pwsh session). proxy status
# prints to stdout; add/on/off messages go to stderr (not captured here).
if command -v pwsh >/dev/null 2>&1; then
    # proxy.ps1 writes its store with _DenWritePrivate from _helpers.ps1, which
    # init.ps1 loads first; this file loads both in that order.
    PROXY_PS1="$TESTTMP/proxy_test.ps1"
    printf ". '%s'\n. '%s'\n" "$DOTFILES/shell/pwsh/_helpers.ps1" "$DOTFILES/shell/pwsh/proxy.ps1" > "$PROXY_PS1" ||
        abort_suite "cannot write $PROXY_PS1"

    reset_conf
    echo "[pwsh] add + on sets env and prepends loopback to no_proxy"
    actual=$(run_pwsh "$PROXY_PS1" "proxy add work http://p:8080 '.corp'; proxy on work; proxy status" | tr -d '\r')
    assert_contains "pwsh/proxy http_proxy" "http_proxy=http://p:8080" "$actual"
    assert_contains "pwsh/proxy no_proxy loopback" "no_proxy=localhost,127.0.0.1,::1,.corp" "$actual"
    assert_contains "pwsh/proxy active" "active: work" "$actual"

    reset_conf
    echo "[pwsh] off clears env + active"
    actual=$(run_pwsh "$PROXY_PS1" "proxy add w http://p:1; proxy on w; proxy off; proxy status" | tr -d '\r')
    assert_contains "pwsh/proxy off active none" "active: (none)" "$actual"
    assert_not_contains "pwsh/proxy off cleared url" "http://p:1" "$actual"

    reset_conf
    echo "[pwsh] no_proxy=* stays standalone"
    actual=$(run_pwsh "$PROXY_PS1" "proxy add all http://p:2 '*'; proxy on all; proxy status" | tr -d '\r')
    assert_contains "pwsh/proxy star no_proxy" "no_proxy=*" "$actual"

    reset_conf
    echo "[pwsh] add rejects an empty url"
    actual=$(run_pwsh "$PROXY_PS1" "proxy add x ''; proxy ls" 2>&1 | tr -d '\r')
    assert_contains "pwsh/proxy empty url rejected" "no profiles" "$actual"

    reset_conf
    echo "[pwsh] add, on, ls and status show a password as ***; the store and the env keep it"
    # The messages (stderr) apart from the listings (stdout): pwsh does not keep
    # the order between the two.
    actual=$(run_pwsh_stderr "$PROXY_PS1" "proxy add c '$SECRET_URL'; proxy on c; proxy ls; proxy status")
    assert_eq "pwsh/proxy password shown as *** by add and on" "proxy: saved 'c' -> $SHOWN_URL
proxy: on (c -> $SHOWN_URL)" "$actual"
    actual=$(run_pwsh "$PROXY_PS1" "proxy add c '$SECRET_URL'; proxy on c; proxy ls; proxy status; \"env=\$env:http_proxy\"" 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/proxy password shown as *** by ls and status" "* c${TAB}$SHOWN_URL
active: c
http_proxy=$SHOWN_URL
https_proxy=$SHOWN_URL
all_proxy=$SHOWN_URL
no_proxy=localhost,127.0.0.1,::1
env=$SECRET_URL" "$actual"
    assert_eq "pwsh/proxy store keeps the password" "c${TAB}$SECRET_URL${TAB}" "$(cat "$PROXY_CONF")"

    reset_conf
    echo "[pwsh] a url without a password shows as it is; one without a scheme is masked too"
    actual=$(run_pwsh "$PROXY_PS1" "proxy add u http://bob@p:1; proxy add h p:3128; proxy add s 'bob:pw@p:2'; proxy ls" 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/proxy only a password is masked" "  u${TAB}http://bob@p:1
  h${TAB}p:3128
  s${TAB}bob:***@p:2" "$actual"

    echo "[pwsh] add makes the store 0600 in a 0700 directory, under umask 022"
    rm -rf "${PROXY_DIR:?}"
    (umask 022; run_pwsh "$PROXY_PS1" "proxy add c '$SECRET_URL'" 2>/dev/null)
    assert_eq "pwsh/proxy new store modes" "700 600" "$(modes)"

    echo "[pwsh] rm tightens an older den's 0644 store and 0755 directory"
    printf 'a\thttp://a:1\t\nb\thttp://b:1\t\n' > "$PROXY_CONF"
    chmod 755 "$PROXY_DIR"
    chmod 644 "$PROXY_CONF"
    (umask 022; run_pwsh "$PROXY_PS1" "proxy rm b" 2>/dev/null)
    assert_eq "pwsh/proxy rm tightens both" "700 600" "$(modes)"

    echo "[pwsh] add leaves a store it cannot read as it was"
    printf 'a\thttp://a:1\t\n' > "$PROXY_CONF"
    if [ "$(id -u)" -ne 0 ] && chmod 200 "$PROXY_CONF" 2>/dev/null && [ ! -r "$PROXY_CONF" ]; then
        actual=$(run_pwsh "$PROXY_PS1" "proxy add n http://n:1; 'after'" 2>/dev/null | tr -d '\r')
        chmod 600 "$PROXY_CONF"
        assert_eq "pwsh/proxy unreadable store: add ends" "" "$actual"
        assert_eq "pwsh/proxy unreadable store: kept" "a${TAB}http://a:1${TAB}" "$(cat "$PROXY_CONF")"
    else
        echo "  SKIP: pwsh/proxy unreadable store (running as root)"
    fi
else
    echo "pwsh not found; skipping pwsh proxy tests"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_proxy"
[ "$FAIL" -eq 0 ]
