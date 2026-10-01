#!/usr/bin/env bash
# test_cmd.sh - Tests for the cmd / Clink port (shell/cmd): starship.lua run
# against a stub of the Clink and Windows calls it makes, and the PowerShell
# commands the cmd shims hand to powershell.exe. cmd itself cannot run here;
# the Windows CI job runs the shims (tests/shell/cmd_shims.cmd).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

STARSHIP_LUA="$DOTFILES/shell/cmd/starship.lua"
CMD_BIN="$DOTFILES/shell/cmd/bin"

echo "================================================"
echo "  Testing the cmd / Clink port (shell/cmd)"
echo "================================================"

LUA_BIN=$(command -v lua5.4 || command -v lua5.3 || command -v lua || true)
if [ -z "$LUA_BIN" ]; then
    echo "  SKIP: starship.lua (no lua interpreter)"
fi

# The stub: H.boot(opts) installs fake os/io/clink/rl/settings tables and runs
# starship.lua. Files live in H.files (lower-cased path -> content), so a tool
# is "on PATH" when its file is there; every spawn is recorded (os.execute in
# H.execs, io.popen in H.popens) and io.popen answers with opts.popen(cmdline).
# opts.old drops the Clink APIs a version lacks: "1.6" no os.setalias, "1.1"
# no os.createtmpfile either, "1.2" no clink.onfilterinput / onprovideline /
# rl history. H.input(line) types a line: Clink adds it to its history, then
# hands it to the onfilterinput handlers (clink/app/src/host/host.cpp), and
# the result is what cmd runs. H.provide() is the next onprovideline answer.
CMD_STUB="$TESTTMP/cmd_stub.lua"
cat > "$CMD_STUB" <<'LUA'
local H = { env = {}, files = {}, dirs = {}, execs = {}, popens = {}, written = {},
            aliases = {}, alias_names = {}, filters = {}, inputs = {}, provides = {},
            history = {}, cwd = "C:\\start" }
local function key(p) return p:lower() end

local function reader(text)
    local pos, f = 1, {}
    function f:read(fmt)
        if pos > #text then return nil end
        if fmt == "*a" or fmt == "a" then
            local s = text:sub(pos); pos = #text + 1; return s
        end
        local nl = text:find("\n", pos, true)
        local line
        if nl then line = text:sub(pos, nl - 1); pos = nl + 1
        else line = text:sub(pos); pos = #text + 1 end
        return line
    end
    function f:lines() return function() return f:read("*l") end end
    function f:close() return true end
    return f
end

local function writer(path)
    local buf, f = {}, {}
    function f:write(...)
        for _, s in ipairs({ ... }) do buf[#buf + 1] = tostring(s) end
        return f
    end
    function f:close()
        H.files[key(path)] = table.concat(buf)
        H.written[#H.written + 1] = path
        return true
    end
    return f
end

io.open = function(path, mode)
    mode = mode or "r"
    if mode:find("[wa]") then
        if H.unwritable then return nil, path .. ": Permission denied" end
        return writer(path)
    end
    local t = H.files[key(path)]
    if t == nil then return nil, path .. ": No such file or directory" end
    return reader(t)
end
io.popen = function(c)
    H.popens[#H.popens + 1] = c
    local out = H.popen_out and H.popen_out(c) or ""
    if out == nil then return nil end
    return reader(out)
end

os.getenv = function(n) return H.env[n] end
os.setenv = function(n, v) H.env[n] = v; return true end
os.getcwd = function() return H.cwd end
-- A relative path is taken from H.cwd, as Windows does.
local function abs(p)
    if p:match("^%a:") or p:match("^[\\/]") then return p end
    return (H.cwd:gsub("\\$", "")) .. "\\" .. p
end
os.isdir = function(p) return H.dirs[key(abs(p))] == true end
os.mkdir = function(p) H.dirs[key(p)] = true; return true end
os.execute = function(c)
    H.execs[#H.execs + 1] = c
    local mf = c:match('/macrofile="([^"]+)"')
    if mf then H.macrofile = H.files[key(mf)] end
    return true
end
os.getpid = function() return 4242 end
local function remove(p)
    if H.files[key(p)] == nil then return nil, p .. ": No such file" end
    H.files[key(p)] = nil
    return true
end
local function rename(a, b)
    if H.files[key(a)] == nil or H.files[key(b)] ~= nil then return nil, "cannot move" end
    H.files[key(b)] = H.files[key(a)]; H.files[key(a)] = nil
    return true
end
os.remove, os.unlink, os.rename, os.move = remove, remove, rename, rename

settings = { set = function() end }

function H.boot(opts)
    opts = opts or {}
    local env = { LOCALAPPDATA = "C:\\L", SystemRoot = "C:\\Windows", PATH = "",
                  COMPUTERNAME = "PC", USERPROFILE = "C:\\Users\\me" }
    for k, v in pairs(opts.env or {}) do env[k] = v end
    for k, v in pairs(env) do if v ~= false then H.env[k] = v end end
    for k, v in pairs(opts.files or {}) do H.files[key(k)] = v end
    for _, d in ipairs(opts.dirs or {}) do H.dirs[key(d)] = true end
    H.popen_out = opts.popen
    H.unwritable = opts.unwritable
    H.cwd = opts.cwd or H.cwd
    local old = opts.old or ""
    os.setalias = nil
    if old == "" then
        os.setalias = function(n, t)
            if H.aliases[n] == nil then H.alias_names[#H.alias_names + 1] = n end
            H.aliases[n] = t
            return true
        end
    end
    os.createtmpfile = nil
    if old == "" or old == "1.6" or old == "1.2" then
        os.createtmpfile = function(prefix, ext)
            local name = "C:\\T\\" .. prefix .. "_4242_1" .. ext
            return writer(name), name
        end
    end
    clink = { promptfilter = function()
        local f = {}; H.filters[#H.filters + 1] = f; return f
    end }
    rl = nil
    if old ~= "1.2" and old ~= "1.1" then
        clink.onfilterinput = function(fn) H.inputs[#H.inputs + 1] = fn end
        clink.onprovideline = function(fn) H.provides[#H.provides + 1] = fn end
        rl = {
            gethistorycount = function() return #H.history end,
            gethistoryitems = function(s, e)
                local t = {}
                for i = s, e do
                    if H.history[i] then t[#t + 1] = { line = H.history[i] } end
                end
                return t
            end,
        }
    end
    dofile(arg[1])
end

function H.prompt() for _, f in ipairs(H.filters) do f:filter("") end end
function H.input(line)
    H.history[#H.history + 1] = line
    for _, fn in ipairs(H.inputs) do
        local r = fn(line)
        if r ~= nil then return r end
    end
    return line
end
function H.provide()
    for _, fn in ipairs(H.provides) do
        local r = fn()
        if r ~= nil and r ~= "" then return r end
    end
    return nil
end
function H.file(p) return H.files[key(p)] end
function H.show(v) return v == nil and "nil" or tostring(v) end
return H
LUA

# run_lua <name> <scenario>: run a scenario against starship.lua; the scenario
# gets the stub as H and runs H.boot{...} itself.
run_lua() {
    local f="$TESTTMP/$1.lua"
    printf 'local H = dofile([[%s]])\n%s\n' "$CMD_STUB" "$2" > "$f" || abort_suite "cannot write $f"
    "$LUA_BIN" "$f" "$STARSHIP_LUA" 2>&1
}

# =============================================================================
# Aliases, not PATH
# =============================================================================
if [ -n "$LUA_BIN" ]; then

echo "[cmd] den's commands are Clink aliases set in-process, and PATH is left alone"
out=$(run_lua aliases '
H.boot{ env = { PATH = "C:\\Windows\\system32;C:\\tools", STARSHIP_CPU_INTEL = "stub" } }
print("PATH=" .. H.env.PATH)
print("execs=" .. #H.execs .. " popens=" .. #H.popens)
for _, n in ipairs({ "ls", "find", "python", "again", ".3", "..", "g", "code" }) do
    print(n .. "=" .. H.show(H.aliases[n]))
end')
assert_eq "cmd/aliases: in-process, by absolute path, PATH untouched" 'PATH=C:\Windows\system32;C:\tools
execs=0 popens=0
ls="C:\L\clink\bin\ls.cmd" $*
find="C:\L\clink\bin\find.cmd" $*
python="C:\L\clink\bin\python.cmd" $*
again="C:\L\clink\bin\again.cmd" $*
.3="C:\L\clink\bin\up.cmd" 3
..=cd ..
g=git $*
code=code-insiders $*' "$out"

echo "[cmd] every shim in shell/cmd/bin gets an alias of its own name"
out=$(run_lua alias_names '
H.boot{ env = { STARSHIP_CPU_INTEL = "stub" } }
local names = {}
for _, n in ipairs(H.alias_names) do
    local file = H.aliases[n]:match("^\"C:\\L\\clink\\bin\\([^\\\"]+)%.cmd\" %$%*$")
    if file then
        if file == n then names[#names + 1] = n else print("MISMATCH " .. n .. " -> " .. file) end
    end
end
table.sort(names)
print(table.concat(names, " "))')
want=$(cd "$CMD_BIN" && for f in *.cmd; do printf '%s\n' "${f%.cmd}"; done | LC_ALL=C sort | tr '\n' ' ')
assert_eq "cmd/aliases: one per shim, same name" "${want% }" "$out"

echo "[cmd] the shim folder an older den put on PATH is taken off again"
out=$(run_lua path_strip '
H.boot{ env = { PATH = "C:\\L\\clink\\bin;C:\\Windows;\"c:\\l\\CLINK\\bin\\\";C:\\tools", STARSHIP_CPU_INTEL = "stub" } }
print(H.env.PATH)')
assert_eq "cmd/aliases: old bin_dir entries removed, others kept in order" 'C:\Windows;C:\tools' "$out"

echo "[cmd] a \$ in the shim path is doubled (doskey reads \$ as a macro code)"
out=$(run_lua dollar '
H.boot{ env = { LOCALAPPDATA = "C:\\Users\\a$b\\AppData\\Local", STARSHIP_CPU_INTEL = "stub" } }
print(H.aliases.ls)')
assert_eq "cmd/aliases: \$ doubled" '"C:\Users\a$$b\AppData\Local\clink\bin\ls.cmd" $*' "$out"

echo "[cmd] Clink before 1.6.11 loads every alias with one doskey /macrofile run"
out=$(run_lua macrofile '
H.boot{ old = "1.6", env = { STARSHIP_CPU_INTEL = "stub" } }
print("execs=" .. #H.execs)
print(H.execs[1])
print("file left=" .. H.show(H.file("C:\\T\\den-aliases_4242_1.txt") ~= nil))
print("aliases=" .. H.show(next(H.aliases)))')
assert_eq "cmd/aliases: one doskey run, temp file removed" 'execs=1
""C:\Windows\System32\doskey.exe" /macrofile="C:\T\den-aliases_4242_1.txt""
file left=false
aliases=nil' "$out"

echo "[cmd] the macro file holds every alias, one name=text line each"
out=$(run_lua macrofile_lines '
H.boot{ old = "1.6", env = { STARSHIP_CPU_INTEL = "stub" } }
local n, crlf = 0, true
for line in H.macrofile:gmatch("([^\n]*)\n") do
    n = n + 1
    if not line:find("\r$") then crlf = false end
end
print("lines=" .. n .. " crlf=" .. tostring(crlf))
print(H.macrofile:match("ls=[^\r]*"))
print(H.macrofile:match("%.9=[^\r]*"))
print(H.macrofile:match("\n(gst=[^\r]*)"))')
nshims=$(cd "$CMD_BIN" && ls -- *.cmd | wc -l)
assert_eq "cmd/aliases: macro file lines" "lines=$((nshims + 11 + 15 + 11 + 2)) crlf=true
ls=\"C:\\L\\clink\\bin\\ls.cmd\" \$*
.9=\"C:\\L\\clink\\bin\\up.cmd\" 9
gst=git status -sb" "$out"

echo "[cmd] Clink before 1.1.42 (no os.createtmpfile) still defines them, one doskey run each"
out=$(run_lua per_alias '
H.boot{ old = "1.1", env = { STARSHIP_CPU_INTEL = "stub" } }
print("execs=" .. #H.execs)
print(H.execs[1])')
assert_eq "cmd/aliases: per-alias fallback" "execs=$((nshims + 11 + 15 + 11 + 2))
\"\"C:\\Windows\\System32\\doskey.exe\" again=\"C:\\L\\clink\\bin\\again.cmd\" \$*\"" "$out"


# =============================================================================
# again [N]
# =============================================================================
echo "[cmd] again takes the previous command from Clink's history and runs it after a yes"
out=$(run_lua again_yes '
H.boot{ env = { STARSHIP_CPU_INTEL = "stub", _DEN_AGAIN = "stale", _DEN_AGAIN_RUN = "1" } }
print("load: " .. H.show(H.env._DEN_AGAIN) .. " " .. H.show(H.env._DEN_AGAIN_RUN))
H.input("echo hi")
print("cmd runs: " .. H.input("again"))
print("_DEN_AGAIN=" .. H.show(H.env._DEN_AGAIN) .. " _DEN_AGAIN_ERR=" .. H.show(H.env._DEN_AGAIN_ERR))
H.env._DEN_AGAIN_RUN = "1"   -- again.cmd: the answer was yes
print("next line: " .. H.show(H.provide()))
print("after: " .. H.show(H.env._DEN_AGAIN) .. " " .. H.show(H.env._DEN_AGAIN_RUN))
print("then: " .. H.show(H.provide()))')
assert_eq "cmd/again: lookup, then the command as the next input line" 'load: nil nil
cmd runs: "C:\L\clink\bin\again.cmd"
_DEN_AGAIN=echo hi _DEN_AGAIN_ERR=nil
next line: echo hi
after: nil nil
then: nil' "$out"

echo "[cmd] again N counts back over the again lines; a no runs nothing"
out=$(run_lua again_n '
H.boot{ env = { STARSHIP_CPU_INTEL = "stub" } }
for _, l in ipairs({ "dir", "echo a & echo b", "again", "  AGAIN 2", "@again", "type x.txt" }) do H.input(l) end
H.input("again 2"); print("again 2: " .. H.show(H.env._DEN_AGAIN))
H.input("again 3"); print("again 3: " .. H.show(H.env._DEN_AGAIN))
H.input("again"); print("again: " .. H.show(H.env._DEN_AGAIN))
print("no: " .. H.show(H.provide()) .. " " .. H.show(H.env._DEN_AGAIN))
print("dir: " .. H.input("dir") .. " " .. H.show(H.env._DEN_AGAIN))')
assert_eq "cmd/again: Nth previous non-again line" 'again 2: echo a & echo b
again 3: dir
again: type x.txt
no: nil nil
dir: dir nil' "$out"

echo "[cmd] again with a bad N or too short a history leaves a message for again.cmd"
out=$(run_lua again_err '
H.boot{ env = { STARSHIP_CPU_INTEL = "stub" } }
for _, l in ipairs({ "again 0", "again x", "again 01", "again 1 2", "again", "again 3" }) do
    local r = H.input(l)
    print(l .. ": " .. r .. " | " .. H.show(H.env._DEN_AGAIN) .. " | " .. H.show(H.env._DEN_AGAIN_ERR))
end')
assert_eq "cmd/again: usage and empty-history messages" 'again 0: "C:\L\clink\bin\again.cmd" | nil | usage: again [N]  (N=positive integer, default 1)
again x: "C:\L\clink\bin\again.cmd" | nil | usage: again [N]  (N=positive integer, default 1)
again 01: "C:\L\clink\bin\again.cmd" | nil | usage: again [N]  (N=positive integer, default 1)
again 1 2: "C:\L\clink\bin\again.cmd" | nil | usage: again [N]  (N=positive integer, default 1)
again: "C:\L\clink\bin\again.cmd" | nil | again: no command at position 1 in history
again 3: "C:\L\clink\bin\again.cmd" | nil | again: no command at position 3 in history' "$out"

echo "[cmd] on a Clink without onfilterinput and history access, again is left to its shim"
out=$(run_lua again_old '
H.boot{ old = "1.2", env = { STARSHIP_CPU_INTEL = "stub" } }
H.input("echo hi")
print(H.input("again") .. " " .. H.show(H.env._DEN_AGAIN) .. " " .. #H.inputs .. " " .. #H.provides)')
assert_eq "cmd/again: old Clink, line untouched" 'again nil 0 0' "$out"


# =============================================================================
# zoxide: z / zi / zd / zdi and zoxide add
# =============================================================================
# ZX boots with zoxide on PATH; its stub answers `query` with C:\proj\<last
# keyword> (nothing for "nomatch").
ZX='local function zx(opts)
    opts = opts or {}
    opts.env = opts.env or {}
    opts.env.PATH = "C:\\tools"
    opts.env.STARSHIP_CPU_INTEL = "stub"
    opts.files = { ["C:\\tools\\zoxide.exe"] = "" }
    opts.popen = function(c)
        local last = c:match("\"([^\"]*)\"\"$")
        if not c:find(" query ", 1, true) or not last or last == "nomatch" then return "" end
        return "C:\\proj\\" .. last .. "\n"
    end
    H.boot(opts)
end'

echo "[cmd] no zoxide init at startup: zoxide has no cmd target"
out=$(run_lua zx_start "$ZX"'
zx()
print("popens=" .. #H.popens .. " execs=" .. #H.execs .. " handlers=" .. #H.inputs)')
assert_eq "cmd/zoxide: startup spawns nothing" 'popens=0 execs=0 handlers=2' "$out"

echo "[cmd] z / zd ask zoxide query for the keywords and cd there"
out=$(run_lua zx_query "$ZX"'
zx()
print(H.input("z foo bar"))
print(H.popens[1])
print(H.input("zd \"my dir\" \"a&b\""))
print(H.popens[2])
print(H.input("Z nomatch"))')
assert_eq "cmd/zoxide: z and zd" 'cd /d "C:\proj\bar"
""C:\tools\zoxide.exe" query --exclude "C:\start" -- "foo" "bar""
cd /d "C:\proj\a&b"
""C:\tools\zoxide.exe" query --exclude "C:\start" -- "my dir" "a&b""
verify other 2>nul' "$out"

echo "[cmd] zi / zdi use zoxide's interactive picker"
out=$(run_lua zx_interactive "$ZX"'
zx()
print(H.input("zi foo"))
print(H.popens[1])
print(H.input("zdi"))
print(H.popens[2])')
assert_eq "cmd/zoxide: zi and zdi" 'cd /d "C:\proj\foo"
""C:\tools\zoxide.exe" query --interactive -- "foo""
verify other 2>nul
""C:\tools\zoxide.exe" query --interactive --"' "$out"

echo "[cmd] z alone goes home, z - back, z <dir> straight there, a drive root stays quoted"
out=$(run_lua zx_forms "$ZX"'
zx{ dirs = { "C:\\sub" }, cwd = "C:\\" }
print(H.input("z"))
print(H.input("z -") .. " " .. #H.popens)
H.env._OLDPWD = "C:\\prev"
print(H.input("z -"))
print(H.input("z sub"))
print("popens=" .. #H.popens)
print(H.input("z x"))
print(H.popens[1])' 2>&1)
assert_eq "cmd/zoxide: the special forms" 'cd /d "C:\Users\me"
zoxide: _OLDPWD is not set
verify other 2>nul 0
cd /d "C:\prev"
cd /d "sub"
popens=0
cd /d "C:\proj\x"
""C:\tools\zoxide.exe" query --exclude "C:\\" -- "x""' "$out"

echo "[cmd] a line with more than one command is left to cmd"
out=$(run_lua zx_compound "$ZX"'
zx()
print(H.input("z foo & dir"))
print(H.input("zip -r a.zip ."))
print("popens=" .. #H.popens)')
assert_eq "cmd/zoxide: compound lines and other words untouched" 'z foo & dir
zip -r a.zip .
popens=0' "$out"

echo "[cmd] each directory change is fed to zoxide add, once"
out=$(run_lua zx_add "$ZX"'
zx()
H.prompt(); print("first prompt: " .. #H.execs)
H.cwd = "C:\\a"; H.prompt(); print(H.execs[1])
H.prompt(); print("same dir: " .. #H.execs)
H.cwd = "C:\\"; H.prompt(); print(H.execs[2])')
assert_eq "cmd/zoxide: zoxide add on change" 'first prompt: 0
""C:\tools\zoxide.exe" add -- "C:\a""
same dir: 1
""C:\tools\zoxide.exe" add -- "C:\\""' "$out"

echo "[cmd] without zoxide nothing is added or rewritten"
out=$(run_lua zx_none '
H.boot{ env = { STARSHIP_CPU_INTEL = "stub" } }
H.cwd = "C:\\a"; H.prompt()
print(H.input("z foo") .. " execs=" .. #H.execs .. " popens=" .. #H.popens)')
assert_eq "cmd/zoxide: absent" 'z foo execs=0 popens=0' "$out"

fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_cmd"
[ "$FAIL" -eq 0 ]
