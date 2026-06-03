-- ===== Suppress banners / normalize spacing =====
settings.set("clink.logo", "none")
settings.set("prompt.spacing", "sparse")  -- cmd.exe adds its own newline + starship add_newline = 2 lines; sparse normalizes to 1

-- ===== Add bin/ to PATH (wrapper scripts for cmd aliases) =====
local bin_dir = os.getenv("LOCALAPPDATA") .. "\\clink\\bin"
local current_path = os.getenv("PATH") or ""
if not current_path:find(bin_dir, 1, true) then
    os.setenv("PATH", bin_dir .. ";" .. current_path)
end

-- ===== Hardware info (for starship) =====
-- Uses env var caching — skips detection if STARSHIP_* vars are already set
-- (e.g. inherited from parent process or previous clink session).
local has_hw_cache = (os.getenv("STARSHIP_CPU_INTEL") or os.getenv("STARSHIP_CPU_AMD")
    or os.getenv("STARSHIP_GPU_NVIDIA") or os.getenv("STARSHIP_GPU_AMD") or os.getenv("STARSHIP_GPU_INTEL"))

if not has_hw_cache then
    -- Uses PowerShell for CIM queries (WMIC deprecated on Win11)
    local h = io.popen('powershell.exe -NoProfile -NoLogo -Command "'
        .. '$cpu=(Get-CimInstance Win32_Processor).Name.Trim();'
        .. "$gpu='';"
        .. 'if(Get-Command nvidia-smi -EA 0){'
        .. '$gpu=(nvidia-smi --query-gpu=gpu_name --format=csv,noheader 2>$null|Select -First 1).Trim()};'
        .. 'if(-not $gpu){'
        .. '$gpu=(Get-CimInstance Win32_VideoController|Select -First 1).Name.Trim()};'
        .. 'Write-Host $cpu;Write-Host $gpu"')
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
os.execute('doskey ..=cd ..')
os.execute('doskey .1=up 1')
os.execute('doskey .2=up 2')
os.execute('doskey .3=up 3')
os.execute('doskey .4=up 4')
os.execute('doskey .5=up 5')
os.execute('doskey .6=up 6')
os.execute('doskey .7=up 7')
os.execute('doskey .8=up 8')
os.execute('doskey .9=up 9')
os.execute('doskey c=cls')

-- ===== Git =====
os.execute('doskey g=git $*')
os.execute('doskey ga=git add $*')
os.execute('doskey gaa=git add --all')
os.execute('doskey gb=git branch $*')
os.execute('doskey gc=git commit $*')
os.execute('doskey gcm=git commit -m $*')
os.execute('doskey gco=git checkout $*')
os.execute('doskey gd=git diff $*')
os.execute('doskey gds=git diff --staged $*')
os.execute('doskey gf=git fetch --all --prune')
os.execute('doskey gl=git log --oneline --graph $*')
os.execute('doskey gpl=git pull $*')
os.execute('doskey gps=git push $*')
os.execute('doskey gst=git status -sb')
os.execute('doskey gsw=git switch $*')

-- ===== Docker =====
os.execute('doskey d=docker $*')
os.execute('doskey dc=docker compose $*')
os.execute('doskey dcb=docker compose build $*')
os.execute('doskey dcd=docker compose down $*')
os.execute('doskey dce=docker compose exec $*')
os.execute('doskey dcl=docker compose logs $*')
os.execute('doskey dcu=docker compose up $*')
os.execute('doskey di=docker images $*')
os.execute('doskey dps=docker ps $*')
os.execute('doskey dri=docker run -it $*')
os.execute('doskey drir=docker run -it --rm $*')

-- ===== Editor =====
os.execute('doskey code=code-insiders $*')
os.execute('doskey gu=gitui $*')

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
local zh = io.popen('zoxide init cmd 2>nul')
if zh then
    local zoxide_init = zh:read("*a")
    zh:close()
    if zoxide_init and zoxide_init ~= "" then
        load(zoxide_init)()
        os.execute('doskey zd=z $*')
        os.execute('doskey zdi=zi $*')
    end
end

-- ===== Starship =====
local sh = io.popen('starship init cmd 2>nul')
if sh then
    local starship_init = sh:read("*a")
    sh:close()
    if starship_init and starship_init ~= "" then
        load(starship_init)()
    end
end
