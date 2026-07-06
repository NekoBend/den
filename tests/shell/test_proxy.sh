#!/usr/bin/env bash
# test_proxy.sh — Tests for proxy.sh (named proxy profiles, env-only on/off).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

PROXY_SH_GUARDED="$DOTFILES/shell/posix/proxy.sh"
PROXY_SH="/tmp/proxy_test_$$.sh"
make_noninteractive_source_copy "$PROXY_SH_GUARDED" "$PROXY_SH"

# Isolate profile storage under WORK so tests never touch the real ~/.config.
export XDG_CONFIG_HOME="$WORK/xdg"
PROXY_CONF="$XDG_CONFIG_HOME/den/proxy.conf"

_cleanup_proxy() { rm -f "$PROXY_SH"; }
trap '_cleanup_proxy' EXIT

reset_conf() { rm -f "$PROXY_CONF"; }

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
}

proxy_suite bash
if command -v zsh >/dev/null 2>&1; then
    proxy_suite zsh
else
    echo "zsh not found; skipping zsh proxy tests"
fi

# pwsh port: same proxy.conf store + same no_proxy loopback logic. on/off/status
# chain inside ONE run_pwsh (env vars only live in that pwsh session). proxy status
# prints to stdout; add/on/off messages go to stderr (not captured here).
if command -v pwsh >/dev/null 2>&1; then
    PROXY_PS1="$DOTFILES/shell/pwsh/proxy.ps1"

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
else
    echo "pwsh not found; skipping pwsh proxy tests"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_proxy"
[ "$FAIL" -eq 0 ]
