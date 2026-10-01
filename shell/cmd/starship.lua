-- ===== Suppress banners / normalize spacing =====
settings.set("clink.logo", "none")
settings.set("prompt.spacing", "sparse")  -- cmd.exe adds its own newline + starship add_newline = 2 lines; sparse normalizes to 1

-- ===== den's command shims: Clink aliases, never on PATH =====
-- The shims in bin_dir (ls.cmd, find.cmd, python.cmd, ...) are reached only
-- through the aliases defined below. An alias (a doskey macro) expands only on
-- a line typed at the Clink prompt, so batch files, `cmd /c`, child processes
-- and starship's own probes keep seeing Windows' commands: System32 find.exe,
-- the real python. den's own commands (mkcd, dg, back, ...) do not exist there
-- either. bin_dir used to be put on PATH; a cmd started from such an older
-- session inherits that entry, so take it off again.
local bin_dir = os.getenv("LOCALAPPDATA") .. "\\clink\\bin"
do
    local kept, dropped = {}, false
    for dir in (os.getenv("PATH") or ""):gmatch("[^;]+") do
        if dir:gsub('"', ""):gsub("[\\/]+$", ""):lower() == bin_dir:lower() then
            dropped = true
        else
            kept[#kept + 1] = dir
        end
    end
    if dropped then
        os.setenv("PATH", table.concat(kept, ";"))
    end
end

-- ===== Spawn helpers (never resolve a command from the current directory) =====
-- io.popen/os.execute run their string through `cmd.exe /c`, and cmd resolves a
-- bare command name from the CURRENT DIRECTORY before %PATH%. Clink loads this
-- script into every new cmd session, so a `zoxide.cmd`/`starship.bat`/`doskey.bat`
-- sitting in a cloned repo would run at startup -- and the zoxide/starship output
-- is handed to load(), i.e. arbitrary code execution with nothing typed. Every
-- command below is therefore spawned by absolute path: tools from %PATH% only
-- (relative and empty PATH entries, which mean "current directory", are skipped),
-- system tools from %SystemRoot%\System32.

-- Resolve <name> to an absolute path using %PATH%, or nil when not found.
local function find_on_path(name)
    for dir in (os.getenv("PATH") or ""):gmatch("[^;]+") do
        dir = dir:gsub('"', ""):gsub("[\\/]+$", "")
        -- Absolute (drive-letter or UNC) entries only: "", ".", "..\bin" and any
        -- other relative entry resolves against the current directory.
        if dir:match("^%a:[\\/]") or dir:match("^\\\\") then
            for _, ext in ipairs({ ".exe", ".cmd", ".bat" }) do
                local candidate = dir .. "\\" .. name .. ext
                local f = io.open(candidate, "r")
                if f then
                    f:close()
                    return candidate
                end
            end
        end
    end
    return nil
end

-- Build a `cmd /c` line for an absolute exe plus arguments. The extra outer quote
-- pair is required: cmd strips the first and last quote of the line whenever it
-- holds more than two quotes (redirections, a quoted -Command argument), which
-- would otherwise unquote a path containing spaces such as
-- C:\Program Files\starship\bin\starship.exe.
local function cmd_line(exe, args)
    return '""' .. exe .. '" ' .. args .. '"'
end

local system_root = os.getenv("SystemRoot") or os.getenv("windir") or "C:\\Windows"
local doskey_exe = system_root .. "\\System32\\doskey.exe"
local powershell_exe = system_root .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"

-- den's aliases, in the order they are defined: { name, macro text } pairs.
local den_aliases = {}
local function alias(name, text)
    den_aliases[#den_aliases + 1] = { name, text }
end

-- The macro text that runs bin_dir\<file>.cmd with <args> ($* = every argument
-- typed after the alias). The path is quoted and its "$" doubled, since doskey
-- reads "$" as the start of a macro code.
local function shim(file, args)
    local path = (bin_dir .. "\\" .. file .. ".cmd"):gsub("%$", "$$")
    return '"' .. path .. '" ' .. (args or "$*")
end

-- Define every alias in den_aliases. Clink 1.6.11+ sets them in this process
-- (os.setalias); older Clink loads them all with one `doskey /macrofile` run,
-- and Clink before 1.1.42 (no os.createtmpfile) runs doskey once per alias.
-- Starting a cmd + doskey pair per alias made each new window wait for dozens.
local function define_aliases()
    if os.setalias then
        for _, a in ipairs(den_aliases) do
            os.setalias(a[1], a[2])
        end
        return
    end
    local f, name
    if os.createtmpfile then
        f, name = os.createtmpfile("den-aliases", ".txt")
    end
    if f then
        for _, a in ipairs(den_aliases) do
            f:write(a[1], "=", a[2], "\r\n")
        end
        f:close()
        os.execute(cmd_line(doskey_exe, '/macrofile="' .. name .. '"'))
        os.remove(name)
        return
    end
    for _, a in ipairs(den_aliases) do
        os.execute(cmd_line(doskey_exe, a[1] .. "=" .. a[2]))
    end
end

-- ===== Hardware info (for starship) =====
-- Uses env var caching — skips detection if STARSHIP_* vars are already set
-- (e.g. inherited from parent process or previous clink session).
local has_hw_cache = (os.getenv("STARSHIP_CPU_INTEL") or os.getenv("STARSHIP_CPU_AMD")
    or os.getenv("STARSHIP_GPU_NVIDIA") or os.getenv("STARSHIP_GPU_AMD") or os.getenv("STARSHIP_GPU_INTEL"))

if not has_hw_cache then
    -- Uses PowerShell for CIM queries (WMIC deprecated on Win11)
    local h = io.popen(cmd_line(powershell_exe, '-NoProfile -NoLogo -Command "'
        .. '$cpu=(Get-CimInstance Win32_Processor).Name.Trim();'
        .. "$gpu='';"
        .. 'if(Get-Command nvidia-smi -EA 0){'
        .. '$gpu=(nvidia-smi --query-gpu=gpu_name --format=csv,noheader 2>$null|Select -First 1).Trim()};'
        .. 'if(-not $gpu){'
        .. '$gpu=(Get-CimInstance Win32_VideoController|Select -First 1).Name.Trim()};'
        .. 'Write-Host $cpu;Write-Host $gpu"'))
    if h then
        local cpu_raw = (h:read("*l") or ""):gsub("%s+$", "")
        local gpu_raw = (h:read("*l") or ""):gsub("%s+$", "")
        h:close()

        if cpu_raw ~= "" then
            local cpu_short = cpu_raw
                :gsub(".*Core%(TM%)%s*", "")
                :gsub(".*Ryzen%s*", "Ryzen ")
                :gsub("%s+", " ")
                :match("^%s*(.-)%s*$")
            if cpu_raw:find("Intel") then
                os.setenv("STARSHIP_CPU_INTEL", cpu_short)
            elseif cpu_raw:find("AMD") then
                os.setenv("STARSHIP_CPU_AMD", cpu_short)
            end
        end

        if gpu_raw ~= "" then
            local gpu_short = gpu_raw
                :gsub("NVIDIA%s+GeForce%s*", "")
                :gsub("AMD%s+", "")
                :gsub("Intel%(R%)%s*", "")
                :gsub("%s+", " ")
                :match("^%s*(.-)%s*$")
            if gpu_raw:find("NVIDIA") then
                os.setenv("STARSHIP_GPU_NVIDIA", gpu_short)
            elseif gpu_raw:find("AMD") or gpu_raw:find("Radeon") then
                os.setenv("STARSHIP_GPU_AMD", gpu_short)
            elseif gpu_raw:find("Intel") then
                os.setenv("STARSHIP_GPU_INTEL", gpu_short)
            end
        end
    end
end

-- ===== Aliases =====
-- One per shim in bin_dir, named after it (back.cmd -> back, tgl-hw.cmd -> tgl-hw).
for _, name in ipairs({
    "again", "back", "cat", "dg", "digest", "find", "fwd", "grep", "head", "la",
    "ll", "lla", "llt", "ls", "lt", "mkcd", "path", "pip", "python", "python3",
    "tail", "tgl-hw", "tgl-uv", "tgl-wr", "toggle-hwinfo", "toggle-uv",
    "toggle-wrapper", "touch", "up", "uv", "wc", "which",
}) do
    alias(name, shim(name))
end

-- Navigation. A macro never expands another macro, so .1-.9 run up.cmd by path.
alias("..", "cd ..")
for n = 1, 9 do
    alias("." .. n, shim("up", tostring(n)))
end
alias("c", "cls")

-- Git
alias("g", "git $*")
alias("ga", "git add $*")
alias("gaa", "git add --all")
alias("gb", "git branch $*")
alias("gc", "git commit $*")
alias("gcm", "git commit -m $*")
alias("gco", "git checkout $*")
alias("gd", "git diff $*")
alias("gds", "git diff --staged $*")
alias("gf", "git fetch --all --prune")
alias("gl", "git log --oneline --graph $*")
alias("gpl", "git pull $*")
alias("gps", "git push $*")
alias("gst", "git status -sb")
alias("gsw", "git switch $*")

-- Docker
alias("d", "docker $*")
alias("dc", "docker compose $*")
alias("dcb", "docker compose build $*")
alias("dcd", "docker compose down $*")
alias("dce", "docker compose exec $*")
alias("dcl", "docker compose logs $*")
alias("dcu", "docker compose up $*")
alias("di", "docker images $*")
alias("dps", "docker ps $*")
alias("dri", "docker run -it $*")
alias("drir", "docker run -it --rm $*")

-- Editor
alias("code", "code-insiders $*")
alias("gu", "gitui $*")

-- ===== zoxide =====
-- zoxide has no cmd init (`zoxide init cmd` is an error), so den does what
-- zoxide's own init does elsewhere: the directory-history filter below runs
-- `zoxide add` for each directory you move to, and a line that is just
-- `z ...` / `zi ...` (or zd / zdi, the names the other shells use) becomes a
-- `cd /d` to the directory `zoxide query` picks.
local zoxide_exe = find_on_path("zoxide")

-- One argument for a program's command line, in double quotes. A trailing
-- backslash is doubled, or it would escape the closing quote (C:\ would
-- arrive as C:"). The text holds no double quote: words lose theirs.
local function quote_arg(s)
    return '"' .. (s:gsub("(\\+)$", "%1%1")) .. '"'
end

-- ===== Directory history for back / fwd (and _OLDPWD) =====
-- Browser-style history for this cmd session. It lives in two environment
-- variables, where the back.cmd / fwd.cmd shims (run by this same cmd process)
-- can read it: directories joined by '|' (no Windows path holds one), both in
-- `back -l` order, i.e. _DEN_DIRBACK farthest entry first and _DEN_DIRFWD
-- nearest first. At each prompt, a change of directory pushes the directory
-- left onto the back list and clears the forward list, as a browser does. A
-- shim that moved instead leaves a note in _DEN_DIRNAV: "back:N" / "fwd:N"
-- after moving N entries, "dropback:N" / "dropfwd:N" when entry N no longer
-- exists; the filter then shifts (or prunes) the lists to match, rather than
-- recording a new move. Each list keeps 25 entries, not 50 as in the other
-- shells: a shim reads a whole list on one command line, which cmd caps at 8191
-- characters. _OLDPWD is still set on every change, as before.
local dirhist_max = 25
-- A child cmd inherits these from its parent; this session starts empty.
os.setenv("_DEN_DIRBACK", nil)
os.setenv("_DEN_DIRFWD", nil)
os.setenv("_DEN_DIRNAV", nil)

-- Read a list, nearest entry first (_DEN_DIRBACK is stored the other way round).
local function dirhist_get(name)
    local list = {}
    for dir in (os.getenv(name) or ""):gmatch("[^|]+") do
        if name == "_DEN_DIRBACK" then
            table.insert(list, 1, dir)
        else
            list[#list + 1] = dir
        end
    end
    return list
end

-- Store a list given nearest entry first, keeping the nearest dirhist_max.
local function dirhist_set(name, list)
    local out = {}
    for i = 1, math.min(#list, dirhist_max) do
        if name == "_DEN_DIRBACK" then
            table.insert(out, 1, list[i])
        else
            out[#out + 1] = list[i]
        end
    end
    os.setenv(name, #out > 0 and table.concat(out, "|") or nil)
end

-- Windows paths compare case-insensitively.
local function same_dir(a, b)
    return a:lower() == b:lower()
end

local _prev_dir = os.getcwd()
local dirhist_filter = clink.promptfilter(99)
function dirhist_filter:filter(prompt)
    local cur = os.getcwd()
    local back = dirhist_get("_DEN_DIRBACK")
    local fwd = dirhist_get("_DEN_DIRFWD")
    local from = _prev_dir  -- where a move to cur started
    local nav = os.getenv("_DEN_DIRNAV")
    if nav then
        os.setenv("_DEN_DIRNAV", nil)
        local op, n = nav:match("^(%a+):(%d+)$")
        n = tonumber(n)
        local list, other = back, fwd
        if op == "fwd" or op == "dropfwd" then
            list, other = fwd, back
        end
        local target = n and list[n]
        if target and (op == "dropback" or op == "dropfwd") then
            if not os.isdir(target) then
                table.remove(list, n)
            end
        elseif target and (op == "back" or op == "fwd") and same_dir(cur, target) then
            -- The entries passed over and the directory left go to the other
            -- list, nearest first, so `back 3` then `fwd 3` returns.
            table.insert(other, 1, _prev_dir)
            for i = 1, n - 1 do
                table.insert(other, 1, list[i])
            end
            for _ = 1, n do
                table.remove(list, 1)
            end
            from = cur
        end
    end
    if not same_dir(cur, from) then
        -- A consecutive duplicate is kept once.
        if not (back[1] and same_dir(back[1], from)) then
            table.insert(back, 1, from)
        end
        fwd = {}
    end
    dirhist_set("_DEN_DIRBACK", back)
    dirhist_set("_DEN_DIRFWD", fwd)

    if cur ~= _prev_dir then
        os.setenv("_OLDPWD", _prev_dir)
        _prev_dir = cur
        if zoxide_exe then
            os.execute(cmd_line(zoxide_exe, "add -- " .. quote_arg(cur)))
        end
    end
    return nil  -- don't modify prompt
end

-- ===== z / zi / zd / zdi =====
-- Split a typed line into words as cmd quotes them: blanks separate, double
-- quotes group and are dropped. nil when an & | < > or ^ stands outside
-- quotes: a line with more than one command is left to cmd.
local function split_words(line)
    local words, word, quoted, inword = {}, {}, false, false
    for c in line:gmatch(".") do
        if c == '"' then
            quoted, inword = not quoted, true
        elseif not quoted and c:match("%s") then
            if inword then
                words[#words + 1] = table.concat(word)
                word, inword = {}, false
            end
        elseif not quoted and c:match("[&|<>^]") then
            return nil
        else
            word[#word + 1] = c
            inword = true
        end
    end
    if inword then
        words[#words + 1] = table.concat(word)
    end
    return words
end

-- The directory `zoxide query <opts> -- <words>` picks, or nil when it finds
-- none or its picker is cancelled (zoxide says why on stderr).
local function zoxide_query(opts, words)
    local args = { "query" }
    for _, o in ipairs(opts) do
        args[#args + 1] = o
    end
    args[#args + 1] = "--"
    for _, w in ipairs(words) do
        args[#args + 1] = quote_arg(w)
    end
    local h = io.popen(cmd_line(zoxide_exe, table.concat(args, " ")))
    if not h then
        return nil
    end
    local dir = (h:read("*l") or ""):gsub("%s+$", "")
    h:close()
    return dir ~= "" and dir or nil
end

-- As zoxide's z: no words go home, `-` to the previous directory, one word
-- that names a directory straight there, anything else to zoxide's best
-- match other than here. zi picks interactively (fzf). No pick leaves a
-- command that only sets ERRORLEVEL 1 (`verify other`).
local function zoxide_filter(line)
    local words = split_words(line)
    local cmd = words and words[1] and words[1]:lower()
    if cmd ~= "z" and cmd ~= "zd" and cmd ~= "zi" and cmd ~= "zdi" then
        return nil
    end
    table.remove(words, 1)
    local dir
    if cmd == "zi" or cmd == "zdi" then
        dir = zoxide_query({ "--interactive" }, words)
    elseif #words == 0 then
        dir = os.getenv("USERPROFILE")
    elseif #words == 1 and words[1] == "-" then
        dir = os.getenv("_OLDPWD")
        if not dir then
            io.stderr:write("zoxide: _OLDPWD is not set\n")
        end
    elseif #words == 1 and os.isdir(words[1]) then
        dir = words[1]
    else
        dir = zoxide_query({ "--exclude", quote_arg(os.getcwd()) }, words)
    end
    if not dir then
        return "verify other 2>nul"
    end
    return 'cd /d "' .. dir .. '"'
end

if zoxide_exe and clink.onfilterinput then
    clink.onfilterinput(zoxide_filter)
end

-- ===== again [N]: re-run a command from Clink's history =====
-- cmd's own history (doskey /history) stays empty under Clink, which keeps
-- its own. A line that is just `again [N]` is caught here (Clink has already
-- added it to its history): the Nth previous command, skipping again lines,
-- goes to again.cmd in _DEN_AGAIN (or a message in _DEN_AGAIN_ERR), and
-- again.cmd asks before it sets _DEN_AGAIN_RUN=1. The next edit prompt then
-- hands that command to cmd as its input line, so it runs as if typed, den's
-- aliases included. Needs Clink 1.3.18 (onprovideline, history access); on an
-- older Clink the again alias reaches again.cmd alone, which says so.
-- A child cmd inherits these from its parent; this session starts without.
os.setenv("_DEN_AGAIN", nil)
os.setenv("_DEN_AGAIN_ERR", nil)
os.setenv("_DEN_AGAIN_RUN", nil)

-- The first word of a line, lower-cased, without cmd's echo-off "@".
local function first_word(line)
    local w = line:match("^%s*@?(%S+)")
    return w and w:lower()
end

local function again_filter(line)
    if first_word(line) ~= "again" then
        return nil
    end
    local arg = line:match("^%s*@?%S+%s*(.-)%s*$")
    local n = arg == "" and 1 or (arg:match("^[1-9]%d?%d?%d?$") and tonumber(arg))
    os.setenv("_DEN_AGAIN", nil)
    os.setenv("_DEN_AGAIN_RUN", nil)
    os.setenv("_DEN_AGAIN_ERR", nil)
    if not n then
        os.setenv("_DEN_AGAIN_ERR", "usage: again [N]  (N=positive integer, default 1)")
    else
        local want = n
        local count = rl.gethistorycount()
        local items = rl.gethistoryitems(math.max(1, count - n - 50), count)
        local found
        for i = #items, 1, -1 do
            local w = first_word(items[i].line or "")
            if w and w ~= "again" then
                n = n - 1
                if n == 0 then
                    found = items[i].line
                    break
                end
            end
        end
        if found then
            os.setenv("_DEN_AGAIN", found)
        else
            os.setenv("_DEN_AGAIN_ERR", "again: no command at position " .. want .. " in history")
        end
    end
    return '"' .. bin_dir .. '\\again.cmd"'
end

local function again_provide()
    local cmd, run = os.getenv("_DEN_AGAIN"), os.getenv("_DEN_AGAIN_RUN")
    os.setenv("_DEN_AGAIN", nil)
    os.setenv("_DEN_AGAIN_RUN", nil)
    os.setenv("_DEN_AGAIN_ERR", nil)
    if run == "1" and cmd and cmd ~= "" then
        return cmd
    end
    return nil
end

if clink.onfilterinput and clink.onprovideline and rl and rl.gethistoryitems then
    clink.onfilterinput(again_filter)
    clink.onprovideline(again_provide)
end

define_aliases()

-- ===== Starship =====
local starship_exe = find_on_path("starship")
if starship_exe then
    local sh = io.popen(cmd_line(starship_exe, "init cmd 2>nul"))
    if sh then
        local starship_init = sh:read("*a")
        sh:close()
        if starship_init and starship_init ~= "" then
            load(starship_init)()
        end
    end
end
