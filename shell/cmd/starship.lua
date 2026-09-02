-- ===== Suppress banners / normalize spacing =====
settings.set("clink.logo", "none")
settings.set("prompt.spacing", "sparse")  -- cmd.exe adds its own newline + starship add_newline = 2 lines; sparse normalizes to 1

-- ===== Add bin/ to PATH (wrapper scripts for cmd aliases) =====
local bin_dir = os.getenv("LOCALAPPDATA") .. "\\clink\\bin"
local current_path = os.getenv("PATH") or ""
if not current_path:find(bin_dir, 1, true) then
    os.setenv("PATH", bin_dir .. ";" .. current_path)
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

-- doskey <macro> — define one doskey macro through the System32 binary.
local function doskey(macro)
    os.execute(cmd_line(doskey_exe, macro))
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

-- ===== Navigation (doskey - simple aliases) =====
doskey('..=cd ..')
doskey('.1=up 1')
doskey('.2=up 2')
doskey('.3=up 3')
doskey('.4=up 4')
doskey('.5=up 5')
doskey('.6=up 6')
doskey('.7=up 7')
doskey('.8=up 8')
doskey('.9=up 9')
doskey('c=cls')

-- ===== Git =====
doskey('g=git $*')
doskey('ga=git add $*')
doskey('gaa=git add --all')
doskey('gb=git branch $*')
doskey('gc=git commit $*')
doskey('gcm=git commit -m $*')
doskey('gco=git checkout $*')
doskey('gd=git diff $*')
doskey('gds=git diff --staged $*')
doskey('gf=git fetch --all --prune')
doskey('gl=git log --oneline --graph $*')
doskey('gpl=git pull $*')
doskey('gps=git push $*')
doskey('gst=git status -sb')
doskey('gsw=git switch $*')

-- ===== Docker =====
doskey('d=docker $*')
doskey('dc=docker compose $*')
doskey('dcb=docker compose build $*')
doskey('dcd=docker compose down $*')
doskey('dce=docker compose exec $*')
doskey('dcl=docker compose logs $*')
doskey('dcu=docker compose up $*')
doskey('di=docker images $*')
doskey('dps=docker ps $*')
doskey('dri=docker run -it $*')
doskey('drir=docker run -it --rm $*')

-- ===== Editor =====
doskey('code=code-insiders $*')
doskey('gu=gitui $*')

-- ===== Track _OLDPWD for back command =====
local _prev_dir = os.getcwd()
local oldpwd_filter = clink.promptfilter(99)
function oldpwd_filter:filter(prompt)
    local cur = os.getcwd()
    if cur ~= _prev_dir then
        os.setenv("_OLDPWD", _prev_dir)
        _prev_dir = cur
    end
    return nil  -- don't modify prompt
end

-- ===== Zoxide (smart cd) =====
local zoxide_exe = find_on_path("zoxide")
if zoxide_exe then
    local zh = io.popen(cmd_line(zoxide_exe, "init cmd 2>nul"))
    if zh then
        local zoxide_init = zh:read("*a")
        zh:close()
        if zoxide_init and zoxide_init ~= "" then
            load(zoxide_init)()
            doskey('zd=z $*')
            doskey('zdi=zi $*')
        end
    end
end

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
