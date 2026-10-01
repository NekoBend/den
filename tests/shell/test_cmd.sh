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
# path.cmd excepted: `path` is a cmd builtin that also sets PATH, and stays it.
want=$(cd "$CMD_BIN" && for f in *.cmd; do [ "$f" = path.cmd ] || printf '%s\n' "${f%.cmd}"; done | LC_ALL=C sort | tr '\n' ' ')
assert_eq "cmd/aliases: one per shim but path, same name" "${want% }" "$out"

echo "[cmd] typed path stays cmd's own PATH command (it also sets PATH)"
out=$(run_lua alias_path '
H.boot{ env = { STARSHIP_CPU_INTEL = "stub" } }
print("path=" .. H.show(H.aliases.path))')
assert_eq "cmd/aliases: no alias over the path builtin" 'path=nil' "$out"

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
# One alias per shim but path, plus .., .1-.9 and c (11), 15 git, 11 docker
# and 2 editor macros.
nshims=$(cd "$CMD_BIN" && ls -- *.cmd | grep -vxc path.cmd)
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

echo "[cmd] a Lua error after the aliases leaves them defined"
out=$(run_lua alias_first '
local ok = pcall(H.boot, { env = { PATH = "C:\\tools" }, files = { ["C:\\tools\\starship.exe"] = "" },
    popen = function() error("boom") end })
print("boot ok=" .. tostring(ok) .. " ls=" .. H.show(H.aliases.ls))')
assert_eq "cmd/aliases: defined before the hardware setup" 'boot ok=false ls="C:\L\clink\bin\ls.cmd" $*' "$out"

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


# =============================================================================
# Hardware info: the cache file shared with pwsh's hwinfo.ps1
# =============================================================================
# HW boots with starship on PATH. Its stub answers the PowerShell detection
# with opts.detect (CPU line, GPU line) and starship's init with nothing;
# HW_DUMP prints the values, the spawns and the cache file.
HW='local CACHE = "C:\\L\\shell-cache\\hwinfo-cache.PC.ps1"
local function hw(opts)
    opts = opts or {}
    opts.env = opts.env or {}
    opts.env.PATH = "C:\\tools"
    opts.files = opts.files or {}
    opts.files["C:\\tools\\starship.exe"] = ""
    opts.popen = function(c)
        if c:find("powershell.exe", 1, true) then return opts.detect end
        return ""
    end
    H.boot(opts)
end
local function dump()
    local ps = 0
    for _, c in ipairs(H.popens) do if c:find("powershell.exe", 1, true) then ps = ps + 1 end end
    for _, v in ipairs({ "CPU_INTEL", "CPU_AMD", "GPU_NVIDIA", "GPU_AMD", "GPU_INTEL" }) do
        local cur, saved = H.env["STARSHIP_" .. v], H.env["_DEN_SAVED_" .. v]
        if cur or saved then print(v .. "=" .. H.show(cur) .. " saved=" .. H.show(saved)) end
    end
    print("detections=" .. ps .. " cache=" .. H.show(H.file(CACHE)))
end'

echo "[cmd] without starship nothing is detected"
out=$(run_lua hw_nostarship '
H.boot{}
print("popens=" .. #H.popens)')
assert_eq "cmd/hwinfo: no starship, no PowerShell" 'popens=0' "$out"

echo "[cmd] the cache file hwinfo.ps1 wrote is read, not run, and nothing is detected"
out=$(run_lua hw_read "$HW"'
hw{ files = { [CACHE] = "\239\187\191$env:STARSHIP_CPU_INTEL = '"'i7-12700H'"'\r\n$env:STARSHIP_GPU_NVIDIA = '"'RTX O'"''"'Brien'"'\r\n" } }
dump()')
assert_eq "cmd/hwinfo: cache hit (BOM, CRLF, doubled quote)" "CPU_INTEL=i7-12700H saved=nil
GPU_NVIDIA=RTX O'Brien saved=nil
detections=0 cache=$(printf '\357\273\277')\$env:STARSHIP_CPU_INTEL = 'i7-12700H'
\$env:STARSHIP_GPU_NVIDIA = 'RTX O''Brien'" "$(printf '%s' "$out" | tr -d '\r')"

echo "[cmd] a miss detects once and writes the file as hwinfo.ps1 does"
out=$(run_lua hw_miss "$HW"'
hw{ detect = "Intel(R) Core(TM) i7-12700H\r\nNVIDIA GeForce RTX O'"'"'Brien\r\n" }
dump()
print("dir made=" .. tostring(H.dirs["c:\\l\\shell-cache"]) .. " temp left=" .. tostring(H.file(CACHE .. ".tmp.4242") ~= nil))')
assert_eq "cmd/hwinfo: miss, detect, write" "CPU_INTEL=i7-12700H saved=nil
GPU_NVIDIA=RTX O'Brien saved=nil
detections=1 cache=\$env:STARSHIP_CPU_INTEL = 'i7-12700H'
\$env:STARSHIP_GPU_NVIDIA = 'RTX O''Brien'

dir made=true temp left=false" "$out"

echo "[cmd] a detection that recognizes nothing is recorded, and the next window trusts it"
out=$(run_lua hw_none "$HW"'
hw{ detect = "Snapdragon(R) X Elite\nQualcomm(R) Adreno(TM) X1-85 GPU\n" }
dump()
H.popens = {}
hw{ detect = "Intel(R) Core(TM) i7-12700H\n\n" }
dump()')
assert_eq "cmd/hwinfo: no-match marker" 'detections=1 cache=# den: no CPU or GPU name it recognizes

detections=0 cache=# den: no CPU or GPU name it recognizes' "$out"

echo "[cmd] a cache file with any other line is ignored and replaced"
out=$(run_lua hw_bad "$HW"'
for _, bad in ipairs({
    "$env:STARSHIP_CPU_INTEL = '"'a'"'; Remove-Item C:\\x; '"'b'"'",
    "$env:PATH = '"'C:/evil'"'",
    "Remove-Item C:\\x",
    "$env:STARSHIP_CPU_INTEL = '"'tab\there'"'",
    "",
}) do
    H.files = {}; H.popens = {}; H.env = {}
    hw{ files = { [CACHE] = bad }, detect = "AMD Ryzen 7 7840U\nAMD Radeon 780M\n" }
    print(H.show(H.env.PATH) .. " " .. H.show(H.env.STARSHIP_CPU_AMD) .. " " .. H.show(H.env.STARSHIP_CPU_INTEL)
        .. " | " .. H.file(CACHE):gsub("\n", " / "))
end')
want_bad="C:\\tools Ryzen 7 7840U nil | \$env:STARSHIP_CPU_AMD = 'Ryzen 7 7840U' / \$env:STARSHIP_GPU_AMD = 'Radeon 780M' / "
assert_eq "cmd/hwinfo: anything but den's lines is never trusted" "$want_bad
$want_bad
$want_bad
$want_bad
$want_bad" "$out"

echo "[cmd] inherited values are used as they are; a failed detection writes nothing"
out=$(run_lua hw_inherit "$HW"'
hw{ env = { STARSHIP_GPU_AMD = "780M" }, files = { [CACHE] = "$env:STARSHIP_CPU_INTEL = '"'x'"'\n" } }
dump()
H.files = {}; H.popens = {}; H.env = {}
hw{ detect = "" }
dump()')
assert_eq "cmd/hwinfo: inherited, failed detection" "GPU_AMD=780M saved=nil
detections=0 cache=\$env:STARSHIP_CPU_INTEL = 'x'

detections=1 cache=nil" "$out"

echo "[cmd] an inherited _DEN_HWINFO_HIDDEN=1 keeps the values hidden, as toggle-hwinfo left them"
out=$(run_lua hw_hidden "$HW"'
hw{ env = { _DEN_HWINFO_HIDDEN = "1" }, files = { [CACHE] = "$env:STARSHIP_CPU_INTEL = '"'i7'"'\n" } }
dump()')
assert_eq "cmd/hwinfo: hidden stays hidden" "CPU_INTEL=nil saved=i7
detections=0 cache=\$env:STARSHIP_CPU_INTEL = 'i7'" "$out"

fi

# =============================================================================
# The PowerShell the head / tail / wc shims run
# =============================================================================
# A shim hands powershell.exe -Command "<text>" with its arguments in _ARG1 /
# _ARG2; run that text the same way with pwsh.
cmd_ps_commands() {
    sed -n 's/.*powershell\(\.exe"\)\{0,1\} -NoProfile -Command "\(.*\)"[[:space:]]*$/\2/p' "$CMD_BIN/$1.cmd"
}
ps_counts() {
    _ARG1="$1" pwsh -NoProfile -NonInteractive -Command "\$o = & { $2 }; '{0} {1} {2}' -f \$o.Lines, \$o.Words, \$o.Characters"
}

if command -v pwsh >/dev/null 2>&1; then
    WC_CMD=$(cmd_ps_commands wc)
    printf 'a b\n\n\nc\n\n' > "$WORK/wc-blank.txt"
    printf 'x y' > "$WORK/wc-noeol.txt"
    printf 'a\r\nb\r\n' > "$WORK/wc-crlf.txt"
    : > "$WORK/wc-empty.txt"

    echo "[cmd] wc counts blank lines and line ends, as GNU wc and pwsh's wc do"
    assert_eq "cmd/wc: blank lines" "5 3 9" "$(ps_counts "$WORK/wc-blank.txt" "$WC_CMD")"
    assert_eq "cmd/wc: no final line feed" "0 2 3" "$(ps_counts "$WORK/wc-noeol.txt" "$WC_CMD")"
    assert_eq "cmd/wc: CRLF" "2 2 6" "$(ps_counts "$WORK/wc-crlf.txt" "$WC_CMD")"
    assert_eq "cmd/wc: empty file" "0 0 0" "$(ps_counts "$WORK/wc-empty.txt" "$WC_CMD")"

    echo "[cmd] wc keeps Measure-Object's table"
    out=$(_ARG1="$WORK/wc-blank.txt" pwsh -NoProfile -NonInteractive -Command "$WC_CMD" \
        | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^$')
    assert_match "cmd/wc: header" "^Lines +Words +Characters +Property$" "$(printf '%s\n' "$out" | head -n 1)"
    assert_match "cmd/wc: values" "^ +5 +3 +9 *$" "$(printf '%s\n' "$out" | tail -n 1)"

    echo "[cmd] tail reads the last lines with Get-Content -Tail"
    seq 1 15 > "$WORK/tail.txt"
    TAIL_DEFAULT=$(cmd_ps_commands tail | sed -n 1p)
    TAIL_N=$(cmd_ps_commands tail | sed -n 2p)
    assert_eq "cmd/tail: default 10" "$(seq 6 15)" "$(_ARG1="$WORK/tail.txt" pwsh -NoProfile -NonInteractive -Command "$TAIL_DEFAULT" | tr -d '\r')"
    assert_eq "cmd/tail: N" "$(seq 13 15)" "$(_ARG1="$WORK/tail.txt" _ARG2=3 pwsh -NoProfile -NonInteractive -Command "$TAIL_N" | tr -d '\r')"
    # Select-Object -Last passed every line of the file through the pipeline
    # (about 3 s for a 92 MB log, against 0.3 s with -Tail).
    assert_eq "cmd/tail: both forms use -Tail, none streams the file" "2 0" \
        "$(cmd_ps_commands tail | grep -c -- ' -Tail ') $(cmd_ps_commands tail | grep -c 'Select-Object -Last')"
else
    echo "  SKIP: head/tail/wc PowerShell (no pwsh)"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_cmd"
[ "$FAIL" -eq 0 ]
