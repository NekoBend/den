"""docker/ubuntu/Dockerfile: what the dev image gives root and dev.

.github/workflows/docker-dev-image.yml builds this image and checks it with
docker, but only when docker/ changes. These tests run on every push and read
the Dockerfile instead. They evaluate the ENV that every `docker exec` starts
with, check how den is fetched, and run the scripts the image installs (the
entrypoint, the /etc/zsh/zshenv and /etc/bash.bashrc blocks and the
/etc/profile.d script) in a scratch directory. Commands that would change
accounts or files are stubs there, and the effective UID is read from
FAKE_EUID so the root branches run without root. The script tests are skipped
on native Windows and where the shell they need is missing.
"""

import datetime
import hashlib
import io
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import threading
import zipfile
from collections.abc import Iterator
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = ROOT / "docker" / "ubuntu" / "Dockerfile"
WORKFLOW = ROOT / ".github" / "workflows" / "docker-dev-image.yml"
SYSTEM_DIRS = (
    "/usr/local/sbin",
    "/usr/local/bin",
    "/usr/sbin",
    "/usr/bin",
    "/sbin",
    "/bin",
)
SYSTEM_PATH = ":".join(SYSTEM_DIRS)
# The tool directories dev gets, in PATH order.
USER_TOOL_DIRS = (".nvm/current/bin", ".local/bin", ".cargo/bin")
# What pwsh reads when it starts: no telemetry, and no check for a newer release.
PWSH_ENV = {"POWERSHELL_TELEMETRY_OPTOUT": "1", "POWERSHELL_UPDATECHECK": "Off"}


def _text() -> str:
    return DOCKERFILE.read_text(encoding="utf-8")


def _parse() -> list[tuple[str, str, str]]:
    """(KEYWORD, arguments, heredoc body) per instruction, without comments."""
    lines = _text().splitlines()
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        while line.endswith("\\") and i < len(lines):
            line = line[:-1] + " " + lines[i].strip()
            i += 1
        body = ""
        heredoc = re.search(r"<<-?['\"]?(\w+)['\"]?", line)
        if heredoc:
            start = i
            while i < len(lines) and lines[i] != heredoc.group(1):
                i += 1
            body = "\n".join(lines[start:i]) + "\n"
            i += 1
        keyword, _, rest = line.strip().partition(" ")
        out.append((keyword.upper(), rest.strip(), body))
    return out


def _instructions() -> list[tuple[str, str]]:
    """(KEYWORD, arguments) per instruction, without comments or heredoc bodies."""
    return [(keyword, rest) for keyword, rest, _ in _parse()]


def _expand(value: str, env: dict[str, str], args: dict[str, str]) -> str:
    def lookup(match: re.Match[str]) -> str:
        name = match.group(1) or match.group(2)
        return env.get(name, args.get(name, ""))

    return re.sub(r"\$\{(\w+)\}|\$(\w+)", lookup, value)


def _walk() -> Iterator[tuple[str, str, str, dict[str, str], dict[str, str]]]:
    """(stage, KEYWORD, USER, ENV, build args) after each instruction of a stage.

    A stage built FROM another stage starts with that stage's USER, ENV and
    build args; the Ubuntu base image starts as root with the system PATH,
    scratch with nothing. ENV wins over a build arg of the same name, as in
    Docker.
    """
    finals: dict[str, tuple[str, dict[str, str], dict[str, str]]] = {}
    stage = ""
    user = ""
    env: dict[str, str] = {}
    args: dict[str, str] = {}
    for keyword, rest in _instructions():
        if keyword == "FROM":
            base, *alias = rest.split()
            if base in finals:
                user, base_env, base_args = finals[base]
                env, args = dict(base_env), dict(base_args)
            else:
                user = "root"
                env, args = ({} if base == "scratch" else {"PATH": SYSTEM_PATH}), {}
            stage = alias[-1] if alias else base
        elif not stage:
            continue
        elif keyword == "ARG":
            for item in shlex.split(rest):
                name, _, default = item.partition("=")
                args[name] = _expand(default, env, args)
        elif keyword == "ENV":
            for item in shlex.split(_expand(rest, env, args)):
                name, _, value = item.partition("=")
                env[name] = value
        elif keyword == "USER":
            user = _expand(rest, env, args)
        finals[stage] = (user, env, args)
        yield stage, keyword, user, dict(env), dict(args)


def _stages() -> list[tuple[str, dict[str, str], dict[str, str]]]:
    """(name, ENV, build args) for each stage, after its last instruction."""
    finals: dict[str, tuple[dict[str, str], dict[str, str]]] = {}
    for stage, _, _, env, args in _walk():
        finals[stage] = (env, args)
    return [(name, env, args) for name, (env, args) in finals.items()]


def _run_steps() -> list[tuple[str, str, dict[str, str], dict[str, str]]]:
    """(stage, USER, ENV, build args) that each RUN executes with."""
    return [
        (stage, user, env, args)
        for stage, keyword, user, env, args in _walk()
        if keyword == "RUN"
    ]


def _run_scripts() -> list[tuple[str, str, dict[str, str], dict[str, str], str]]:
    """(stage, USER, ENV, build args, script) per RUN.

    The script is the RUN line, then its heredoc body if it has one.
    """
    bodies = [(rest, body) for keyword, rest, body in _parse() if keyword == "RUN"]
    return [
        (stage, user, env, args, f"{rest}\n{body}")
        for (stage, user, env, args), (rest, body) in zip(
            _run_steps(), bodies, strict=True
        )
    ]


def _install_step(marker: str) -> tuple[str, dict[str, str], str]:
    """(USER, environment, body) of the RUN heredoc named ``marker``.

    The RUN line may hold flags (--mount) before the heredoc. The environment
    is what the step runs with: its build args and the ENV, which wins over a
    build arg of the same name.
    """
    for _, user, env, args, script in _run_scripts():
        line, _, body = script.partition("\n")
        if line.rstrip().endswith(f"<<'{marker}'"):
            return user, {**args, **env}, body
    raise AssertionError(f"the Dockerfile has no RUN <<'{marker}' step")


def _appended_block(target: str) -> str:
    """The heredoc the image writes to ``target`` (cat >> or > target <<'MARKER')."""
    pattern = rf"cat >>? {re.escape(target)} <<'(\w+)'\n(.*?)\n\1\n"
    match = re.search(pattern, _text(), flags=re.DOTALL)
    assert match, f"the Dockerfile writes nothing to {target}"
    return match.group(2) + "\n"


def _entrypoint_script() -> str:
    match = re.search(
        r"cat > /usr/local/bin/container-entrypoint <<'(\w+)'\n(.*?)\n\1\n",
        _text(),
        flags=re.DOTALL,
    )
    assert match, "the Dockerfile no longer writes the entrypoint"
    return match.group(2) + "\n"


def _patched(script: str, replacements: dict[str, str]) -> str:
    for old, new in replacements.items():
        assert old in script, f"the script no longer contains {old!r}; update this test"
        script = script.replace(old, new)
    return script


def _tool(name: str) -> str:
    """Absolute path of a program the test's skip mark checked for (ruff S607)."""
    exe = shutil.which(name)
    assert exe is not None, f"the skip mark skips this test without {name}"
    return exe


def _needs(*tools: str) -> pytest.MarkDecorator:
    return pytest.mark.skipif(
        sys.platform == "win32" or any(shutil.which(tool) is None for tool in tools),
        reason=f"needs {', '.join(tools)} on a POSIX system",
    )


def _user_path(home: str) -> str:
    return ":".join([*(f"{home}/{d}" for d in USER_TOOL_DIRS), SYSTEM_PATH])


# --- the environment every docker exec starts with ----------------------------


def test_a_root_exec_path_holds_only_system_directories():
    # docker exec, root's included, starts with the image's ENV. With dev's
    # ~/.local/bin, ~/.cargo/bin or ~/.nvm/current/bin on it, a file dev drops
    # there (an apt-get, an ls) ran as root on the next `docker exec denbox ...`.
    _, env, _ = _stages()[-1]
    entries = env["PATH"].split(":")
    assert entries
    assert all(entry in SYSTEM_DIRS for entry in entries), env["PATH"]


def test_a_root_exec_home_is_roots():
    # With the image's HOME=/home/dev, a root exec without a shell (or through
    # bash -c or sh -c) read files dev can write as root's configuration:
    # ~/.dpkg.cfg, ~/.gitconfig, and the .pth files in the Python user
    # site-packages, which python3 runs at startup (apt's scripts start it).
    _, env, _ = _stages()[-1]
    assert env["HOME"] == "/root"


def test_build_steps_that_run_as_the_user_keep_its_home():
    # rustup, cargo, the installers, nvm and den write under the user's home,
    # so ENV HOME=/root must come after the last of them.
    as_user = [
        (stage, env, args)
        for stage, user, env, args in _run_steps()
        if user.partition(":")[0] not in {"root", "0"}
    ]
    assert len(as_user) > 5, "the parser no longer sees the user's build steps"
    for stage, env, args in as_user:
        assert env["HOME"] == f"/home/{args['USERNAME']}", stage


def test_root_build_steps_after_the_user_steps_use_roots_home():
    # Once a step has run as the user (rustup, the installers, nvm), the
    # user's home may hold ~/.curlrc, ~/.dpkg.cfg or Python .pth files, which
    # curl, dpkg's hooks and python3 read as root's configuration.
    steps = _run_steps()
    first_user = next(
        i
        for i, (_, user, _, _) in enumerate(steps)
        if user.partition(":")[0] not in {"root", "0"}
    )
    as_root = [
        (stage, env)
        for stage, user, env, _ in steps[first_user:]
        if user.partition(":")[0] in {"root", "0"}
    ]
    assert as_root, "the parser no longer sees a root step after the user's"
    for stage, env in as_root:
        assert env["HOME"] == "/root", stage


def test_root_build_steps_resolve_commands_from_system_directories_only():
    # The user's steps put ~/.nvm/current/bin, ~/.local/bin and ~/.cargo/bin
    # first on PATH, and the user can write there. A root step that kept that
    # PATH ran an installer's planted curl, dpkg or apt-get as root.
    steps = _run_steps()
    as_root = [
        (i, stage, env)
        for i, (stage, user, env, _) in enumerate(steps)
        if user.partition(":")[0] in {"root", "0"}
    ]
    first_user = next(
        i
        for i, (_, user, _, _) in enumerate(steps)
        if user.partition(":")[0] not in {"root", "0"}
    )
    assert any(i > first_user for i, _, _ in as_root), (
        "the parser no longer sees a root step after the user's"
    )
    for i, stage, env in as_root:
        entries = env["PATH"].split(":")
        assert all(entry in SYSTEM_DIRS for entry in entries), (
            f"RUN #{i} (stage {stage}): {env['PATH']}"
        )


def test_build_steps_that_run_as_the_user_after_a_root_one_get_its_path_back():
    # The user's steps after the root one run uv and den by name from
    # ~/.local/bin, so they get the user's tool directories back: the list the
    # entrypoint gives the user at run time.
    steps = _run_steps()
    first_user = next(
        i
        for i, (_, user, _, _) in enumerate(steps)
        if user.partition(":")[0] not in {"root", "0"}
    )
    first_root_after = next(
        i
        for i, (_, user, _, _) in enumerate(steps)
        if i > first_user and user.partition(":")[0] in {"root", "0"}
    )
    as_user = [
        (stage, env)
        for stage, user, env, _ in steps[first_root_after:]
        if user.partition(":")[0] not in {"root", "0"}
    ]
    assert as_user, "the parser no longer sees a user step after a root one"
    for stage, env in as_user:
        assert env["PATH"] == _user_path(env["HOME"]), stage


def test_den_comes_from_a_git_source_of_main_mounted_into_the_install():
    # A RUN that cloned den was cached on its command text, so a rebuild after
    # main moved kept the first build's den. BuildKit resolves a git source's
    # branch to a commit on every build, and the mount makes it the install
    # step's input.
    stage = ""
    source_stage = ""
    install = ""
    for keyword, rest in _instructions():
        if keyword == "FROM":
            stage = rest.split()[-1]
        elif keyword == "ADD" and re.search(
            r"https://github\.com/NekoBend/den\.git#main(\s|$)", rest
        ):
            source_stage = stage
        elif keyword == "RUN":
            assert "github.com/NekoBend/den" not in rest, "a RUN fetches den itself"
            if "uv tool install" in rest:
                install = rest
    assert source_stage, "no stage ADDs den's main branch"
    mounts = [
        dict(option.split("=", 1) for option in mount.split(","))
        for mount in re.findall(r"--mount=(\S+)", install)
    ]
    source_mounts = [
        m for m in mounts if m.get("type") == "bind" and m.get("from") == source_stage
    ]
    assert len(source_mounts) == 1, install
    source = source_mounts[0]["target"]
    assert (
        f"uv tool install --python /usr/bin/python3 --link-mode copy {source} "
        in install
    )


# --- what the image leaves out -------------------------------------------------

# The image ships no coding-agent CLI and no den skills: an image built FROM it
# adds them (docker/README.md, "Adding your own tools"). eza and broot are left
# out too, and bubblewrap served only codex's sandbox. A pattern also matches
# the host a removed installer came from.
_LEFT_OUT = {
    "claude": r"\bclaude\b",
    "codex": r"\bcodex\b|\bchatgpt\.com\b",
    "acpx": r"\bacpx\b",
    "grok": r"\bgrok\b|\bx\.ai\b",
    "muse": r"\bmuse\b|\bdev\.meta\.ai\b",
    "agy": r"\bagy\b|\bantigravity\b",
    "eza": r"\beza\b",
    "broot": r"\bbroot\b",
    "bubblewrap": r"\bbubblewrap\b|\bbwrap\b",
    "den install skills": r"\bden\s+install\s+skills\b",
}


@pytest.mark.parametrize("name", sorted(_LEFT_OUT))
def test_the_image_installs_no_agent_cli_eza_broot_or_den_skills(name):
    # Comment lines, the Dockerfile's and its heredoc scripts', may name them.
    pattern = re.compile(_LEFT_OUT[name], flags=re.IGNORECASE)
    found = [
        line.strip()
        for line in _text().splitlines()
        if not line.lstrip().startswith("#") and pattern.search(line)
    ]
    assert not found, f"{name} is back in the Dockerfile: {found}"


def _dropin_files(tmp_path: Path) -> tuple[Path, Path]:
    """Install extracted helpers; fake root ownership only at the stat boundary."""
    config = tmp_path / "denbox"
    for name in ("init.d", "user-init.d", "user-env.d", "user-path.d"):
        (config / name).mkdir(parents=True, exist_ok=True)
    default = config / "user-path.d" / "denbox.list"
    default.write_text(_appended_block("/etc/denbox/user-path.d/denbox.list"))
    metadata = tmp_path / "metadata"
    metadata.write_text(
        f"#!{sys.executable}\n"
        "import os, stat, sys\n"
        "path = sys.argv[-1]\n"
        "info = os.lstat(path)\n"
        "owner = 123 if (path.endswith('non-root') or\n"
        "    os.path.exists(path + '/.non-root-owner')) else 0\n"
        "mode = stat.S_IMODE(info.st_mode)\n"
        "if stat.S_ISDIR(info.st_mode) and not path.endswith('unsafe-dir'):\n"
        "    mode = 0o755\n"
        "print(f'{owner}:{mode:o}')\n"
    )
    metadata.chmod(0o755)
    library = tmp_path / "dropins.sh"
    library.write_text(
        _appended_block("/usr/local/lib/denbox/dropins.sh")
        .replace("/etc/denbox", str(config))
        .replace("/usr/bin/gnustat", str(metadata))
    )
    wrapper = tmp_path / "user-exec"
    wrapper.write_text(
        _appended_block("/usr/local/lib/denbox/user-exec").replace(
            "/usr/local/lib/denbox/dropins.sh", str(library)
        )
    )
    wrapper.chmod(0o755)
    return library, wrapper


# --- /etc/zsh/zshenv and /etc/bash.bashrc --------------------------------------


def _source_block(
    tmp_path: Path,
    shell: str,
    target: str,
    *,
    euid: int,
    home: str,
    user: str,
    histfile: str = "",
    extra: tuple[str, ...] = (),
    inherited_path: str = SYSTEM_PATH,
) -> list[str]:
    """Source the block twice in ``shell``.

    Returns HOME, PATH, skip_global_compinit, HISTFILE and USER, then the
    variables ``extra`` names ("unset" for one that is not set). ``histfile``
    stands in for the HISTFILE bash sets from HOME before it reads its startup
    files.
    """
    user_file = tmp_path / "container-user"
    user_file.write_text(f"{user}\n", encoding="utf-8")
    library, _ = _dropin_files(tmp_path)
    text = _appended_block(target).replace(
        "/usr/local/lib/denbox/dropins.sh", str(library)
    )
    # Patch only the branch condition; identity still uses the real account.
    euid_ref = '"$_denbox_uid"' if '"$_denbox_uid"' in text else '"$EUID"'
    block = tmp_path / "block"
    block.write_text(
        _patched(
            text,
            {"/etc/container-user": str(user_file), euid_ref: '"$FAKE_EUID"'},
        ),
        encoding="utf-8",
    )
    # Set everything inside the probe: zsh reads the real /etc/zsh/zshenv even
    # with -f, and in this image that file runs the very block under test.
    probe = (
        f"export HOME={shlex.quote(home)} PATH={shlex.quote(inherited_path)}; "
        "unset skip_global_compinit HISTFILE USER LOGNAME"
        + "".join(f" {name}" for name in extra)
        + "; "
        + (f"HISTFILE={shlex.quote(histfile)}; " if histfile else "")
        + f". {shlex.quote(str(block))}; . {shlex.quote(str(block))}; "
        'printf "%s\\n" "$HOME" "$PATH" "${skip_global_compinit-unset}" '
        '"${HISTFILE-unset}" "${USER-unset}"'
        + "".join(f' "${{{name}-unset}}"' for name in extra)
    )
    flags = {"zsh": ["-f"], "bash": ["--norc"], "sh": []}[shell]
    argv = [_tool(shell), *flags, "-c", probe]
    result = subprocess.run(
        argv,
        env={"FAKE_EUID": str(euid), "PATH": SYSTEM_PATH},
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    return result.stdout.splitlines()


def _zsh_username() -> str:
    """The name zsh puts in $USERNAME for this process."""
    result = subprocess.run(
        [_tool("zsh"), "-f", "-c", 'print -r -- "$USERNAME"'],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    return result.stdout.strip()


def _login_name() -> str:
    """The name ``id -un`` prints for this process, as the bash and sh blocks run it."""
    result = subprocess.run(
        [_tool("id"), "-un"],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    return result.stdout.strip()


@_needs("zsh")
def test_zshenv_gives_a_non_root_zsh_the_user_tool_directories_once(tmp_path):
    home = str(tmp_path / "home")
    out = _source_block(
        tmp_path, "zsh", "/etc/zsh/zshenv", euid=1000, home=home, user="dev"
    )
    assert out[:2] == [home, _user_path(home)]


@_needs("zsh")
def test_zshenv_resets_a_root_zsh_and_adds_no_user_directories(tmp_path):
    out = _source_block(
        tmp_path, "zsh", "/etc/zsh/zshenv", euid=0, home="/home/dev", user="dev"
    )
    assert out == ["/root", SYSTEM_PATH, "unset", "unset", "root"]


@_needs("zsh")
def test_zshenv_gives_the_container_user_its_home_back(tmp_path):
    # docker exec --user dev keeps the image's HOME=/root, which dev cannot
    # read. zsh finds ~/.zshenv, ~/.zshrc and the rest through the HOME this
    # block sets, and the tool directories hang off it.
    me = _zsh_username()
    assert me
    out = _source_block(
        tmp_path, "zsh", "/etc/zsh/zshenv", euid=1000, home="/root", user=me
    )
    assert out == [f"/home/{me}", _user_path(f"/home/{me}"), "1", "unset", me]


@_needs("zsh")
def test_zshenv_gives_no_other_user_the_container_users_home(tmp_path):
    me = _zsh_username()
    out = _source_block(
        tmp_path, "zsh", "/etc/zsh/zshenv", euid=1000, home="/root", user=f"{me}-other"
    )
    assert out[0] == "/root"
    assert out[4] == "unset"


@_needs("zsh")
def test_zshenv_skips_ubuntus_global_compinit_for_the_container_user_only(tmp_path):
    # With skip_global_compinit set, Ubuntu's /etc/zsh/zshrc runs no compinit
    # and den's init.zsh runs its quick one instead of that full one.
    home = str(tmp_path / "home")
    me = _zsh_username()
    assert me
    dev = _source_block(
        tmp_path, "zsh", "/etc/zsh/zshenv", euid=1000, home=home, user=me
    )
    assert dev[2] == "1"
    other = _source_block(
        tmp_path, "zsh", "/etc/zsh/zshenv", euid=1000, home=home, user=f"{me}-other"
    )
    assert other[2] == "unset"


@_needs("bash")
def test_bashrc_gives_a_non_root_bash_the_user_tool_directories_once(tmp_path):
    home = str(tmp_path / "home")
    out = _source_block(
        tmp_path, "bash", "/etc/bash.bashrc", euid=1000, home=home, user="dev"
    )
    assert out[:2] == [home, _user_path(home)]


@_needs("bash")
def test_bashrc_gives_a_root_bash_its_own_home(tmp_path):
    # A root `docker exec -it denbox bash` kept HOME=/home/dev and so read
    # dev's ~/.bashrc, which dev can rewrite.
    out = _source_block(
        tmp_path, "bash", "/etc/bash.bashrc", euid=0, home="/home/dev", user="dev"
    )
    assert out[:2] == ["/root", SYSTEM_PATH]


@_needs("bash")
def test_bashrc_moves_a_root_bash_history_out_of_the_user_home(tmp_path):
    # bash sets HISTFILE from the HOME it starts with, so a root bash that got
    # HOME=/root back still saved its history (typed secrets included) to
    # /home/dev/.bash_history, a file dev can read or point at a root file.
    out = _source_block(
        tmp_path,
        "bash",
        "/etc/bash.bashrc",
        euid=0,
        home="/home/dev",
        user="dev",
        histfile="/home/dev/.bash_history",
    )
    assert out == ["/root", SYSTEM_PATH, "unset", "/root/.bash_history", "root"]


@_needs("bash", "id")
def test_bashrc_gives_the_container_user_its_home_and_history_back(tmp_path):
    # An interactive bash started by docker exec --user dev reads ~/.bashrc
    # through the HOME this block sets, and had set HISTFILE from the image's
    # HOME=/root, where dev cannot save it.
    me = _login_name()
    assert me
    out = _source_block(
        tmp_path,
        "bash",
        "/etc/bash.bashrc",
        euid=1000,
        home="/root",
        user=me,
        histfile="/root/.bash_history",
    )
    assert out == [
        f"/home/{me}",
        _user_path(f"/home/{me}"),
        "unset",
        f"/home/{me}/.bash_history",
        me,
    ]


@_needs("bash", "id")
def test_bashrc_gives_no_other_user_the_container_users_home(tmp_path):
    me = _login_name()
    out = _source_block(
        tmp_path,
        "bash",
        "/etc/bash.bashrc",
        euid=1000,
        home="/root",
        user=f"{me}-other",
        histfile="/root/.bash_history",
    )
    assert out[0] == "/root"
    assert out[3:] == ["/root/.bash_history", "unset"]


@_needs("bash")
def test_bashrc_keeps_a_history_file_it_did_not_derive_from_the_user_home(tmp_path):
    root_choice = _source_block(
        tmp_path,
        "bash",
        "/etc/bash.bashrc",
        euid=0,
        home="/home/dev",
        user="dev",
        histfile="/root/elsewhere",
    )
    assert root_choice[3] == "/root/elsewhere"
    home = str(tmp_path / "home")
    dev = _source_block(
        tmp_path,
        "bash",
        "/etc/bash.bashrc",
        euid=1000,
        home=home,
        user="dev",
        histfile=f"{home}/.bash_history",
    )
    assert dev[3] == f"{home}/.bash_history"


@_needs("zsh", "bash")
@pytest.mark.parametrize(
    ("shell", "target"), [("zsh", "/etc/zsh/zshenv"), ("bash", "/etc/bash.bashrc")]
)
@pytest.mark.parametrize("euid", [0, 1000])
def test_shells_turn_powershell_telemetry_and_update_check_off(
    tmp_path, shell, target, euid
):
    # pwsh started from a shell sends no telemetry and checks for no update,
    # also when the shell started without the image's environment (env -i,
    # su -).
    out = _source_block(
        tmp_path,
        shell,
        target,
        euid=euid,
        home=str(tmp_path / "home"),
        user="dev",
        extra=tuple(PWSH_ENV),
    )
    assert out[5:] == list(PWSH_ENV.values())


def _profile_script() -> str:
    match = re.search(r"cat > (/etc/profile\.d/\S+) <<'", _text())
    assert match, "the Dockerfile writes no /etc/profile.d script"
    return match.group(1)


def test_the_profile_script_has_a_name_etc_profile_runs():
    # Ubuntu's /etc/profile only sources names run-parts lists with this regex.
    name = _profile_script().rsplit("/", 1)[1]
    assert re.fullmatch(r"[a-zA-Z0-9_][a-zA-Z0-9._-]*\.sh", name), name


@_needs("sh", "bash")
@pytest.mark.parametrize("shell", ["sh", "bash"])
def test_profile_gives_a_root_login_shell_its_own_home(tmp_path, shell):
    # A root `docker exec denbox bash -lc ...` or `sh -lc ...` is not
    # interactive, so it skips /etc/bash.bashrc and ran dev's ~/.profile.
    out = _source_block(
        tmp_path, shell, _profile_script(), euid=0, home="/home/dev", user="dev"
    )
    assert out[:2] == ["/root", SYSTEM_PATH]


@_needs("sh", "bash", "id")
@pytest.mark.parametrize("shell", ["sh", "bash"])
def test_profile_gives_the_container_users_login_shell_its_home_back(tmp_path, shell):
    # bash -lc and sh -lc are not interactive, so only /etc/profile reaches
    # them, and without its home dev's ~/.profile was never found.
    me = _login_name()
    assert me
    out = _source_block(
        tmp_path, shell, _profile_script(), euid=1000, home="/root", user=me
    )
    assert out[:2] == [f"/home/{me}", _user_path(f"/home/{me}")]
    assert out[4] == me


@_needs("sh", "id")
def test_profile_gives_no_other_user_the_container_users_home(tmp_path):
    me = _login_name()
    out = _source_block(
        tmp_path, "sh", _profile_script(), euid=1000, home="/root", user=f"{me}-other"
    )
    assert out[0] == "/root"
    assert out[4] == "unset"


@_needs("sh")
def test_profile_leaves_a_non_root_login_shell_alone(tmp_path):
    home = str(tmp_path / "home")
    out = _source_block(
        tmp_path, "sh", _profile_script(), euid=1000, home=home, user="dev"
    )
    assert out[:2] == [home, _user_path(home)]


# --- the entrypoint ------------------------------------------------------------


def _mount_table(*paths: str) -> str:
    """A mount table with / and PATHS, escaped as /proc/self/mountinfo does.

    It names each mount point by its physical path, as the kernel does.
    """
    lines = ["22 1 0:21 / / rw,relatime - overlay overlay rw\n"]
    for n, path in enumerate(paths, start=40):
        escaped = _escaped_mount_point(Path(path).resolve())
        lines.append(f"{n} 22 0:{n} / {escaped} rw,relatime - ext4 /dev/sdb1 rw\n")
    return "".join(lines)


def _escaped_mount_point(path: Path) -> str:
    """PATH as the mount table writes it.

    A space, tab, newline or backslash becomes a backslash and three octal
    digits.
    """
    return "".join(f"\\{ord(c):03o}" if c in " \t\n\\" else c for c in str(path))


def _run_entrypoint(
    tmp_path: Path,
    *,
    uid: int,
    env: dict[str, str],
    mounts: tuple[str, ...] = ("/workspace",),
    nested: tuple[str, ...] = (),
    table: bool = True,
    ids: tuple[int, int] = (1000, 1000),
    home: Path | None = None,
    workspace: Path | None = None,
    real_find: bool = False,
    stack_kib: int | None = None,
) -> tuple[subprocess.CompletedProcess[str], str]:
    """Run the entrypoint as ``uid`` with stubs; return the result and the call log.

    The account is dev, with ``ids`` (1000:1000 unless given) and the home
    ``home`` (/home/dev unless given), which this does not make; ``workspace``
    takes the place of /workspace. The state volume's mount point is
    tmp_path/state and /tmp is tmp_path/tmp, neither of which this makes;
    mountpoint finds a mount point at each path ``mounts`` names and nowhere
    else. The mount table the entrypoint reads lists /, ``mounts`` and
    ``nested`` (mount points below those, which mountpoint is not asked
    about), or is missing when ``table`` is false. setpriv logs its call and
    runs nothing: for state-link it exits with FAKE_STATE_LINK_STATUS
    (default 0), and otherwise prints its arguments, the HOME it got and the
    PWSH_ENV variables. gnutimeout logs its call and runs the command after
    its three options; gnumkdir logs its call and makes the directory; find
    logs its call and fails when its first argument is FAKE_FIND_FAIL (as
    ``env`` gives it), and with ``real_find`` runs the system's find when
    that argument is in tmp_path, after it writes the environment it got to
    tmp_path/find-env-<its PID>; gnuchown logs its call and adds its
    arguments, each followed by a NUL, to tmp_path/chowned; usermod logs its
    call and fails when FAKE_USERMOD_FAIL is "ids" and it has --uid, or
    "home" and it has not; the other commands that change accounts or files
    only log theirs. The entrypoint runs in tmp_path, with a stack limit of
    ``stack_kib`` KiB when that is given.
    """
    dropins = _dropin_files(tmp_path)
    sh = _tool("sh")
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    log = tmp_path / "calls.log"
    log.touch()
    logged = f'echo "$(basename "$0") $*" >> {shlex.quote(str(log))}'

    def stub(name: str, body: str) -> None:
        path = stubs / name
        path.write_text(f"#!{sh}\n{body}\n", encoding="utf-8")
        path.chmod(0o755)

    stub("id", f'case "$1" in -u|-g) echo {uid} ;; *) exit 1 ;; esac')
    account = f"dev:x:{ids[0]}:{ids[1]}::{home or '/home/dev'}:/bin/zsh"
    stub(
        "getent",
        'case "$1 $2" in\n'
        f'  "passwd dev") echo {shlex.quote(account)} ;;\n'
        '  "group "*) exit 0 ;;\n'
        "  *) exit 2 ;;\n"
        "esac",
    )
    stub("groupadd", logged)
    stub(
        "usermod",
        f"{logged}\n"
        'case " $* " in *" --uid "*) fails=ids ;; *) fails=home ;; esac\n'
        '[ "${FAKE_USERMOD_FAIL-}" != "$fails" ]',
    )
    chowned = shlex.quote(str(tmp_path / "chowned"))
    stub("gnuchown", f"{logged}\nprintf '%s\\0' \"$@\" >> {chowned}")
    real = (
        f'case "$1" in {shlex.quote(str(tmp_path))}/*)'
        f" {shlex.quote(_tool('env'))} > {shlex.quote(str(tmp_path / 'find-env-'))}$$"
        f' && exec {shlex.quote(_tool("find"))} "$@" ;; esac\n'
        if real_find
        else ""
    )
    # find may get none of env, so the path it fails for is part of the stub.
    stub(
        "find",
        f"{logged}\n"
        f'[ "$1" != {shlex.quote(env.get("FAKE_FIND_FAIL", ""))} ] || exit 1\n{real}',
    )
    stub(
        "mountpoint",
        f"{logged}\n"
        "for arg do last=$arg; done\n"
        'case ":$FAKE_MOUNTS:" in *":$last:"*) exit 0 ;; esac\n'
        "exit 32",
    )
    stub("gnumkdir", f'{logged}\nexec mkdir "$@"')
    stub("gnutimeout", f'{logged}\nshift 3\nexec "$@"')
    stub(
        "setpriv",
        f"{logged}\n"
        f'case " $* " in *" {_STATE_LINK} "*)'
        ' exit "${FAKE_STATE_LINK_STATUS:-0}" ;; esac\n'
        'case " $* " in *"/user-init.d/"*) shift 5; exec "$@" ;; esac\n'
        'printf "%s\\n" "$@" "HOME=$HOME"'
        + "".join(f' "{name}=${{{name}-unset}}"' for name in PWSH_ENV),
    )
    user_file = tmp_path / "container-user"
    user_file.write_text("dev\n", encoding="utf-8")
    mountinfo = tmp_path / "mountinfo"
    if table:
        mountinfo.write_text(_mount_table(*mounts, *nested), encoding="utf-8")
    system = "/usr/sbin:/usr/bin:/sbin:/bin"  # the entrypoint's own PATH
    places = {}
    if home is not None:
        assert home.name == "dev", "the account is dev"
        places['"/home/$username"'] = f'"{home.parent}/$username"'
    if workspace is not None:
        places["/workspace"] = str(workspace)
    script = tmp_path / "container-entrypoint"
    script.write_text(
        _patched(
            _entrypoint_script(),
            {
                **places,
                "/usr/local/lib/denbox/dropins.sh": str(dropins[0]),
                "/usr/local/lib/denbox/user-exec": str(dropins[1]),
                "root_hooks=/etc/denbox/init.d": (
                    f"root_hooks={tmp_path / 'denbox/init.d'}"
                ),
                "user_hooks=/etc/denbox/user-init.d": (
                    f"user_hooks={tmp_path / 'denbox/user-init.d'}"
                ),
                "state_dir=/state": f"state_dir={tmp_path / 'state'}",
                "tmp_dir=/tmp": f"tmp_dir={tmp_path / 'tmp'}",
                "mountinfo=/proc/self/mountinfo": f"mountinfo={mountinfo}",
                "/etc/container-user": str(user_file),
                # The PATH the entrypoint sets for itself, not the one it
                # gives state-link.
                f"PATH={system}\nexport PATH": f"PATH={stubs}:{system}\nexport PATH",
                "/usr/bin/setpriv": str(stubs / "setpriv"),
                "/usr/bin/gnuchown": str(stubs / "gnuchown"),
                "/usr/bin/gnumkdir": str(stubs / "gnumkdir"),
                "/usr/bin/gnutimeout": str(stubs / "gnutimeout"),
            },
        ),
        encoding="utf-8",
    )
    command = [sh, str(script), _tool("env")]
    if stack_kib is not None:
        command = [
            sh,
            "-c",
            'ulimit -s "$1" && shift && exec "$@"',
            "sh",
            str(stack_kib),
            *command,
        ]
    result = subprocess.run(
        command,
        env={"PATH": SYSTEM_PATH, "FAKE_MOUNTS": ":".join(mounts), **env},
        cwd=tmp_path,
        input="hook-input\n",
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    return result, log.read_text(encoding="utf-8")


@_needs("sh", "env")
def test_entrypoint_starts_the_command_with_the_user_tool_directories(tmp_path):
    result, _ = _run_entrypoint(tmp_path, uid=0, env={})
    assert result.returncode == 0, result.stderr
    assert f"PATH={_user_path('/home/dev')}" in result.stdout.splitlines()


@_needs("sh", "env")
def test_entrypoint_started_as_the_user_adds_the_user_tool_directories(tmp_path):
    result, _ = _run_entrypoint(tmp_path, uid=1000, env={})
    assert result.returncode == 0, result.stderr
    assert f"PATH={_user_path('/home/dev')}" in result.stdout.splitlines()


@_needs("sh", "env")
@pytest.mark.parametrize("uid", [0, 1000])
def test_entrypoint_gives_the_command_the_user_home(tmp_path, uid):
    # The entrypoint starts with the image's HOME=/root, whether docker run
    # starts it as root or with --user; the command it runs gets the user's.
    result, _ = _run_entrypoint(tmp_path, uid=uid, env={"HOME": "/root"})
    assert result.returncode == 0, result.stderr
    assert "HOME=/home/dev" in result.stdout.splitlines()


@_needs("sh", "env")
@pytest.mark.parametrize("uid", [0, 1000])
def test_entrypoint_turns_powershell_telemetry_and_update_check_off(tmp_path, uid):
    # pwsh reads both settings when it starts; the command gets them even when
    # docker run passed other values.
    result, _ = _run_entrypoint(
        tmp_path,
        uid=uid,
        env={"POWERSHELL_TELEMETRY_OPTOUT": "0", "POWERSHELL_UPDATECHECK": "LTS"},
    )
    assert result.returncode == 0, result.stderr
    lines = result.stdout.splitlines()
    for name, value in PWSH_ENV.items():
        assert f"{name}={value}" in lines


@_needs("sh", "env")
def test_entrypoint_says_once_that_a_remap_copies_the_home(tmp_path):
    # A UID other than the build's re-owns all of /home/dev, which overlayfs
    # copies into each new container; the build args avoid it.
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={"HOST_UID": "501", "HOST_GID": "20"}
    )
    assert result.returncode == 0, result.stderr
    assert _calls(calls, "usermod") == _usermod_calls(501, 20)
    lines = result.stderr.splitlines()
    assert len(lines) == 1, result.stderr
    # The copy is an overlayfs cost; other storage drivers re-own in place.
    assert "re-owns /home/dev, which on overlayfs copies all of it" in lines[0]
    assert "--build-arg USER_UID=501 --build-arg USER_GID=20" in lines[0]


@_needs("sh", "env")
def test_entrypoint_is_quiet_when_the_ids_already_match(tmp_path):
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={"HOST_UID": "1000", "HOST_GID": "1000"}
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert "usermod" not in calls


# --- the entrypoint's account change -------------------------------------------

# The home the account has while usermod gives it its new IDs.
_NO_HOME = "/dev/null/no-home"


def _usermod_calls(uid: int, gid: int, home: str = "/home/dev") -> list[str]:
    """The usermod calls of a remap to UID:GID, as the usermod stub logs them.

    usermod --uid/--gid also re-owns what the old IDs own in the home the
    account has, in a walk that goes into mount points below it. The first
    call gives the account a home that does not exist, and so a walk of
    nothing; the second, with no --uid or --gid, walks nothing either.
    """
    return [
        f"usermod --home {_NO_HOME} --uid {uid} --gid {gid} dev",
        f"usermod --home {home} dev",
    ]


@_needs("sh", "env")
def test_entrypoint_gives_the_user_its_new_ids_while_it_has_no_home(tmp_path):
    # A1 (GPT's reviews): usermod's own walk of the home re-owned what is
    # mounted there, and rewriting /etc/passwd by hand took none of the locks
    # the account tools take. usermod changes the IDs, with its locks, while
    # the account's home is a path that cannot exist, and then gives the home
    # back; neither call moves anything. The workspace walk comes first, so a
    # failed one leaves the old IDs for a retry, and the home's walk, reown's,
    # comes last.
    # A workspace of the test's own: a CI runner has no /workspace.
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    result, calls = _run_entrypoint(
        tmp_path,
        uid=0,
        env={"HOST_UID": "501", "HOST_GID": "20", "FIX_WORKSPACE_OWNERSHIP": "1"},
        workspace=workspace,
    )
    assert result.returncode == 0, result.stderr
    assert _calls(calls, "usermod") == _usermod_calls(501, 20)
    assert not os.path.lexists(_NO_HOME)
    order = [
        line.split(" ", 2)[1]
        for line in calls.splitlines()
        if line.split(" ", 1)[0] in {"find", "usermod"}
    ]
    assert order == [str(workspace), "--home", "--home", "/home/dev"], calls
    assert "HOME=/home/dev" in result.stdout.splitlines()


@_needs("sh", "env")
@pytest.mark.parametrize(
    ("fails", "message", "ran"),
    [
        ("ids", "Could not give dev the IDs 501:20", 1),
        (
            "home",
            "Could not give dev its home /home/dev back after its new IDs;"
            " recreate the container",
            2,
        ),
    ],
)
def test_entrypoint_stops_when_usermod_fails(tmp_path, fails, message, ran):
    # Either call failing stops the start before the home's walk.
    result, calls = _run_entrypoint(
        tmp_path,
        uid=0,
        env={"HOST_UID": "501", "HOST_GID": "20", "FAKE_USERMOD_FAIL": fails},
    )
    assert result.returncode == 2
    assert result.stderr.splitlines()[-1] == message
    assert _calls(calls, "usermod") == _usermod_calls(501, 20)[:ran]
    assert [line for line in _calls(calls, "find") if "/home/dev" in line] == []
    assert "HOME=" not in result.stdout


# --- the entrypoint's state volume and /tmp steps ------------------------------

_STATE_LINK = "/usr/local/lib/denbox/state-link"


def _state_link_call(uid: int = 1000, gid: int = 1000) -> str:
    """The call that runs state-link as dev, as the setpriv stub logs it.

    env -i: state-link gets HOME and PATH, nothing of the image's ENV or of
    docker run -e.
    """
    return (
        f"setpriv --reuid {uid} --regid {gid} --init-groups /usr/bin/env -i"
        f" HOME=/home/dev PATH=/usr/sbin:/usr/bin:/sbin:/bin {_STATE_LINK}"
    )


def _calls(log: str, name: str) -> list[str]:
    return [line for line in log.splitlines() if line.split(" ", 1)[0] == name]


@_needs("sh", "env")
def test_entrypoint_links_the_home_into_a_mounted_state_volume_as_the_user(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={}, mounts=("/workspace", str(state))
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    # Root makes /state/home, and gives /state and /state/home, and nothing
    # in them, to dev; chown -h changes a link itself, never its target.
    assert _calls(calls, "gnumkdir") == [f"gnumkdir {state}/home"]
    assert (state / "home").is_dir()
    assert _calls(calls, "gnuchown") == [f"gnuchown -h 1000:1000 {state} {state}/home"]
    # Then state-link runs as dev, before the command does, and root waits
    # for it 300 seconds at most.
    assert _calls(calls, "setpriv")[0] == _state_link_call()
    assert len(_calls(calls, "setpriv")) == 2
    assert _calls(calls, "gnutimeout") == [
        f"gnutimeout -k 10 300 {tmp_path / 'stubs' / 'setpriv'}"
        + _state_link_call().removeprefix("setpriv")
    ]
    # The IDs match, so nothing is walked.
    assert not _calls(calls, "find")


@_needs("sh", "env")
def test_entrypoint_keeps_an_existing_state_home(tmp_path):
    state = tmp_path / "state"
    (state / "home").mkdir(parents=True)
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={}, mounts=("/workspace", str(state))
    )
    assert result.returncode == 0, result.stderr
    assert not _calls(calls, "gnumkdir")
    assert _calls(calls, "gnuchown") == [f"gnuchown -h 1000:1000 {state} {state}/home"]
    assert _state_link_call() in calls


@_needs("sh", "env")
@pytest.mark.parametrize(
    ("link_status", "warning"),
    [
        ("1", "state-link reported problems (see above)"),
        (
            "124",
            "state-link was stopped after 300 seconds, so the run was cut"
            f" short; run {_STATE_LINK} as dev to finish it",
        ),
        (
            "137",
            "state-link was killed, by the time limit or by a signal, so the run"
            f" was cut short; run {_STATE_LINK} as dev to finish it",
        ),
    ],
    ids=["failed", "stopped-by-term", "killed"],
)
def test_entrypoint_starts_the_command_when_state_link_fails_or_is_stopped(
    tmp_path, link_status, warning
):
    # B5: state-link's warnings are above this line; the start goes on, under
    # set -e too. gnutimeout exits 124 when its TERM stopped state-link, and
    # 137 when a KILL did: its own, 10 seconds later, or anyone else's (the
    # OOM killer), so that message does not claim the time limit.
    state = tmp_path / "state"
    state.mkdir()
    result, calls = _run_entrypoint(
        tmp_path,
        uid=0,
        env={"FAKE_STATE_LINK_STATUS": link_status},
        mounts=("/workspace", str(state)),
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == f"container-entrypoint: {warning}\n"
    assert _state_link_call() in calls
    assert "HOME=/home/dev" in result.stdout.splitlines()


@_needs("sh", "env")
@pytest.mark.parametrize("where", ["state", "tmp"])
def test_entrypoint_starts_the_command_when_a_state_walk_or_the_tmp_delete_fails(
    tmp_path, where
):
    state = tmp_path / "state"
    state.mkdir()
    (tmp_path / "tmp").mkdir()
    if where == "state":
        env = {"HOST_UID": "501", "HOST_GID": "20"}
        mounts = ("/workspace", str(state))
        warning = f"re-owning {state} from 1000:1000 failed part way"
    else:
        env = {"DENBOX_CLEAN_TMP": "1"}
        mounts = ("/workspace", str(tmp_path / "tmp"))
        warning = "some entries under /tmp were left in place"
    result, _ = _run_entrypoint(
        tmp_path,
        uid=0,
        env={**env, "FAKE_FIND_FAIL": str(tmp_path / where)},
        mounts=mounts,
    )
    assert result.returncode == 0, result.stderr
    assert f"container-entrypoint: {warning}" in result.stderr.splitlines()
    assert "HOME=/home/dev" in result.stdout.splitlines()


@_needs("sh", "env")
@pytest.mark.parametrize(
    ("denbox_state", "mounted"), [("1", False), ("0", True), ("0", False)]
)
def test_entrypoint_leaves_state_alone_unless_mounted_and_on(
    tmp_path, denbox_state, mounted
):
    # The image's own /state is in the container's layer, which a new
    # container loses; DENBOX_STATE=0 turns the step off with a volume there too.
    state = tmp_path / "state"
    state.mkdir()
    mounts = ("/workspace", str(state)) if mounted else ("/workspace",)
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={"DENBOX_STATE": denbox_state}, mounts=mounts
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert _STATE_LINK not in calls
    assert not _calls(calls, "gnumkdir")
    assert not _calls(calls, "gnuchown")
    assert not (state / "home").exists()


@_needs("sh", "env")
@pytest.mark.parametrize("name", ["DENBOX_STATE", "DENBOX_CLEAN_TMP"])
@pytest.mark.parametrize("value", ["2", "yes", " 1"])
def test_entrypoint_rejects_a_switch_other_than_0_or_1(tmp_path, name, value):
    result, calls = _run_entrypoint(tmp_path, uid=0, env={name: value})
    assert result.returncode == 2
    assert result.stderr == f"{name} must be 0 or 1\n"
    assert "setpriv" not in calls


@_needs("sh", "env")
def test_entrypoint_does_not_follow_a_state_mount_point_that_is_a_link(tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    state = tmp_path / "state"
    state.symlink_to(outside)
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={}, mounts=("/workspace", str(state), str(outside))
    )
    assert result.returncode == 0, result.stderr
    assert _STATE_LINK not in calls
    assert not _calls(calls, "gnumkdir")
    assert not _calls(calls, "gnuchown")
    assert list(outside.iterdir()) == []


@_needs("sh", "env")
def test_entrypoint_does_not_follow_a_state_home_that_is_a_link(tmp_path):
    # B1: a /state/home that is a link (dev owns /state after the first
    # start) must not make root re-own or link through it.
    outside = tmp_path / "outside"
    outside.mkdir()
    state = tmp_path / "state"
    state.mkdir()
    (state / "home").symlink_to(outside)
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={}, mounts=("/workspace", str(state))
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == (
        f"container-entrypoint: {state}/home is a symbolic link;"
        f" the home is not linked into {state}\n"
    )
    assert _STATE_LINK not in calls
    assert not _calls(calls, "gnumkdir")
    assert not _calls(calls, "gnuchown")


@_needs("sh", "env")
def test_entrypoint_starts_without_the_state_step_when_state_home_is_a_file(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    (state / "home").write_text("", encoding="utf-8")
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={}, mounts=("/workspace", str(state))
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr.splitlines()[-1] == (
        f"container-entrypoint: could not prepare {state}/home;"
        f" the home is not linked into {state}"
    )
    assert _STATE_LINK not in calls
    assert not _calls(calls, "gnuchown")
    # The command still starts.
    assert "HOME=/home/dev" in result.stdout.splitlines()


@_needs("sh", "env")
@pytest.mark.parametrize("mounted", [True, False])
def test_entrypoint_started_as_the_user_only_warns_about_a_mounted_state(
    tmp_path, mounted
):
    state = tmp_path / "state"
    state.mkdir()
    mounts = ("/workspace", str(state)) if mounted else ("/workspace",)
    result, calls = _run_entrypoint(tmp_path, uid=1000, env={}, mounts=mounts)
    assert result.returncode == 0, result.stderr
    expected = (
        f"container-entrypoint: {state} is mounted, but only a root start links"
        " the home into it; omit --user, or set DENBOX_STATE=0\n"
    )
    assert result.stderr == (expected if mounted else "")
    assert _STATE_LINK not in calls
    assert not (state / "home").exists()


@_needs("sh", "env")
def test_entrypoint_re_owns_the_state_volume_when_it_remaps_the_ids(tmp_path):
    # B8: files in the volume that dev made under the old IDs stay dev's.
    state = tmp_path / "state"
    state.mkdir()
    result, calls = _run_entrypoint(
        tmp_path,
        uid=0,
        env={"HOST_UID": "501", "HOST_GID": "20"},
        mounts=("/workspace", str(state)),
    )
    assert result.returncode == 0, result.stderr
    walks = [line for line in _calls(calls, "find") if f" {state} " in f"{line} "]
    assert len(walks) == 1, calls
    words = walks[0].split()
    # No link followed (find's default, and chown -h), no other file system.
    assert words[1:3] == [str(state), "-xdev"]
    assert "-h --from=1000 501" in walks[0]
    assert "-h --from=:1000 :20" in walks[0]
    assert _calls(calls, "gnuchown") == [f"gnuchown -h 501:20 {state} {state}/home"]
    assert _state_link_call(501, 20) in calls


@_needs("sh", "env")
@pytest.mark.parametrize(
    ("nested", "table", "walked"),
    [
        # Another named volume, or a bind mount, can share the volume's
        # device number, which is all find -xdev compares.
        ("state/home/.cache", True, False),
        ("state/my dir", True, False),
        # A mount point only spelled like one below it.
        ("state2", True, True),
        ("", False, False),
    ],
    ids=["below", "escaped", "sibling", "no-table"],
)
def test_entrypoint_re_owns_no_state_volume_with_a_mount_point_below_it(
    tmp_path, nested, table, walked
):
    state = tmp_path / "state"
    state.mkdir()
    below = (str(tmp_path / nested),) if nested else ()
    result, calls = _run_entrypoint(
        tmp_path,
        uid=0,
        env={"HOST_UID": "501", "HOST_GID": "20"},
        mounts=("/workspace", str(state)),
        nested=below,
        table=table,
    )
    assert result.returncode == 0, result.stderr
    walks = [line for line in _calls(calls, "find") if f" {state} " in f"{line} "]
    assert len(walks) == (1 if walked else 0), calls
    warnings = [
        line for line in result.stderr.splitlines() if "is re-owned from" in line
    ]
    if walked:
        assert warnings == []
    elif table:
        assert warnings == [
            f"container-entrypoint: mount point {tmp_path / nested} is below"
            f" {state}, so nothing in {state} is re-owned from 1000:1000;"
            " docker/README.md shows how to re-own a volume once"
        ]
    else:
        assert warnings == [
            f"container-entrypoint: could not read the mount table"
            f" {tmp_path / 'mountinfo'}, so nothing in {state} is re-owned from"
            " 1000:1000; docker/README.md shows how to re-own a volume once"
        ]
    # The rest of the start goes on: the home is re-owned, and state-link runs.
    assert [line for line in _calls(calls, "find") if "/home/dev " in line]
    assert _calls(calls, "gnuchown")[-1] == f"gnuchown -h 501:20 {state} {state}/home"
    assert _state_link_call(501, 20) in calls
    assert "HOME=/home/dev" in result.stdout.splitlines()


@_needs("sh", "env")
def test_entrypoint_leaves_an_unmounted_state_out_of_the_remap(tmp_path):
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={"HOST_UID": "501", "HOST_GID": "20"}
    )
    assert result.returncode == 0, result.stderr
    assert [line for line in _calls(calls, "find") if "/state " in f"{line} "] == []


@_needs("sh", "env")
def test_entrypoint_leaves_a_mounted_state_out_of_the_remap_when_den_state_is_0(
    tmp_path,
):
    # D7: DENBOX_STATE=0 turns the whole state step off, the /state walk too.
    state = tmp_path / "state"
    state.mkdir()
    result, calls = _run_entrypoint(
        tmp_path,
        uid=0,
        env={"DENBOX_STATE": "0", "HOST_UID": "501", "HOST_GID": "20"},
        mounts=("/workspace", str(state)),
    )
    assert result.returncode == 0, result.stderr
    assert _calls(calls, "usermod") == _usermod_calls(501, 20)
    assert [line for line in _calls(calls, "find") if str(state) in line] == []
    assert _STATE_LINK not in calls
    assert not _calls(calls, "gnuchown")


@_needs("sh", "env")
@pytest.mark.parametrize(
    ("clean", "mounted", "link", "emptied"),
    [
        ("1", True, False, True),
        ("0", True, False, False),
        ("", True, False, False),
        ("1", False, False, False),
        ("1", True, True, False),
    ],
)
def test_entrypoint_empties_tmp_only_on_request_and_on_its_own_mount_point(
    tmp_path, clean, mounted, link, emptied
):
    # B3: emptying the image's /tmp would delete what does not belong to this
    # start. A mount point there is emptied, a bound host directory too (the
    # README says never to bind one).
    tmp = tmp_path / "tmp"
    if link:
        (tmp_path / "elsewhere").mkdir()
        tmp.symlink_to(tmp_path / "elsewhere")
    else:
        tmp.mkdir()
    env = {"DENBOX_CLEAN_TMP": clean} if clean else {}
    mounts = ("/workspace", str(tmp)) if mounted else ("/workspace",)
    result, calls = _run_entrypoint(tmp_path, uid=0, env=env, mounts=mounts)
    assert result.returncode == 0, result.stderr
    deletes = [line for line in _calls(calls, "find") if "-delete" in line]
    if emptied:
        assert deletes == [f"find {tmp} -xdev -mindepth 1 -delete"]
        assert result.stderr == ""
    else:
        assert deletes == []
    if clean == "1" and not emptied:
        assert result.stderr == (
            "container-entrypoint: DENBOX_CLEAN_TMP=1 empties /tmp only when it is"
            " a mount point of its own; it is left as it is\n"
        )


@_needs("sh", "env")
@pytest.mark.parametrize(
    ("nested", "table", "emptied"),
    [
        # docker run -v scratch:/tmp -v cache:/tmp/cache: two named volumes
        # share the device number, and find -xdev would empty both.
        ("tmp/cache", True, False),
        ("tmp/.X11-unix", True, False),
        ("tmp/my dir", True, False),
        # A mount point only spelled like one below it.
        ("tmp2", True, True),
        ("", False, False),
    ],
    ids=["volume", "x11", "escaped", "sibling", "no-table"],
)
def test_entrypoint_empties_no_tmp_with_a_mount_point_below_it(
    tmp_path, nested, table, emptied
):
    tmp = tmp_path / "tmp"
    tmp.mkdir()
    below = (str(tmp_path / nested),) if nested else ()
    result, calls = _run_entrypoint(
        tmp_path,
        uid=0,
        env={"DENBOX_CLEAN_TMP": "1"},
        mounts=("/workspace", str(tmp)),
        nested=below,
        table=table,
    )
    assert result.returncode == 0, result.stderr
    deletes = [line for line in _calls(calls, "find") if "-delete" in line]
    if emptied:
        assert deletes == [f"find {tmp} -xdev -mindepth 1 -delete"]
        assert result.stderr == ""
    elif table:
        assert deletes == []
        assert result.stderr == (
            "container-entrypoint: DENBOX_CLEAN_TMP=1 empties /tmp only when no mount"
            f" point is below it, and {tmp_path / nested} is one; it is left as"
            " it is\n"
        )
    else:
        assert deletes == []
        assert result.stderr == (
            "container-entrypoint: DENBOX_CLEAN_TMP=1 empties /tmp only when no mount"
            f" point is below it, and the mount table {tmp_path / 'mountinfo'}"
            " could not be read; it is left as it is\n"
        )
    assert "HOME=/home/dev" in result.stdout.splitlines()


@_needs("sh", "env")
def test_entrypoint_started_as_the_user_leaves_tmp_alone(tmp_path):
    tmp = tmp_path / "tmp"
    tmp.mkdir()
    result, calls = _run_entrypoint(
        tmp_path,
        uid=1000,
        env={"DENBOX_CLEAN_TMP": "1"},
        mounts=("/workspace", str(tmp)),
    )
    assert result.returncode == 0, result.stderr
    assert not _calls(calls, "find")
    assert result.stderr == (
        "container-entrypoint: DENBOX_CLEAN_TMP=1 needs a root start;"
        " /tmp is left as it is\n"
    )


# --- the entrypoint's re-own walks ---------------------------------------------
#
# A remapping start re-owns, from dev's old IDs, what is in the home, and in
# /workspace with FIX_WORKSPACE_OWNERSHIP=1. These run the system's find on a
# tree in tmp_path whose files the test's own IDs own, so the account gets
# those IDs; the gnuchown stub only records what it was given.

_WALKS = ["workspace", "home"]


def _other_id(n: int) -> int:
    """An ID other than N, to remap to."""
    return 4242 if n != 4242 else 4243


def _paths(root: Path) -> set[str]:
    """ROOT and everything below it, as find names them."""
    found = {str(root)}
    for parent, dirs, files in root.walk():
        found.update(str(parent / name) for name in [*dirs, *files])
    return found


def _remap_walk(
    tmp_path: Path,
    walk: str,
    *,
    nested: tuple[str, ...] = (),
    others: tuple[str, ...] = (),
    files: tuple[str, ...] = (),
    listed: tuple[str, ...] = (),
    sibling: bool = False,
    table: bool = True,
    fail: bool = False,
    env: dict[str, str] | None = None,
    stack_kib: int | None = None,
) -> tuple[subprocess.CompletedProcess[str], Path, set[str], str]:
    """Start with other IDs, so that the WALK ("workspace" or "home") runs.

    The walked directory has a file, a directory with a file for each of
    ``nested`` (each a mount point in the table) and ``others`` (plain
    directories), and a file for each of ``files`` (each a mount point in the
    table); the table also lists ``listed`` below it, which this does not
    make. ``sibling`` adds a mount point next to it whose name starts with
    its own. ``env`` adds to the start's environment, and ``stack_kib`` is
    its stack limit in KiB. Return the result, the walked directory, the
    paths in tmp_path that gnuchown was given, and the IDs it re-owns from,
    as the warnings write them.
    """
    uid, gid = os.getuid(), os.getgid()
    home = tmp_path / "home" / "dev"
    workspace = tmp_path / "workspace"
    root = workspace if walk == "workspace" else home
    for path in (home, workspace):
        path.mkdir(parents=True)
        (path / "file").touch()
    for name in (*others, *nested):
        (root / name).mkdir(parents=True, exist_ok=True)
        (root / name / "file").touch()
    for name in files:
        (root / name).touch()
    below = tuple(str(root / name) for name in (*nested, *files, *listed))
    if sibling:
        twin = root.with_name(f"{root.name}2")
        twin.mkdir()
        (twin / "file").touch()
        below = (*below, str(twin))
    start_env = {
        **(env or {}),
        "HOST_UID": str(_other_id(uid)),
        "HOST_GID": str(_other_id(gid)),
    }
    if walk == "workspace":
        start_env["FIX_WORKSPACE_OWNERSHIP"] = "1"
    if fail:
        start_env["FAKE_FIND_FAIL"] = str(root)
    result, _ = _run_entrypoint(
        tmp_path,
        uid=0,
        env=start_env,
        mounts=(str(workspace),),
        nested=below,
        table=table,
        ids=(uid, gid),
        home=home,
        workspace=workspace,
        real_find=True,
        stack_kib=stack_kib,
    )
    chowned = tmp_path / "chowned"
    words = chowned.read_bytes().split(b"\0") if chowned.exists() else []
    given = {os.fsdecode(word) for word in words}
    return result, root, given & _paths(tmp_path), f"{uid}:{gid}"


@_needs("sh", "env", "find")
@pytest.mark.parametrize("walk", _WALKS)
@pytest.mark.parametrize(
    ("nested", "others"),
    [
        # docker run -v ~/proj:/workspace -v ~/cache:/workspace/.cache: two
        # host directories of one disk share the device number, which is all
        # find -xdev compares.
        ((".cache",), ()),
        ((".cache", "src/build"), ("src",)),
        # The mount table writes a space as \040.
        (("my dir",), ("my",)),
        # find -path takes a pattern: each of these matches only itself, and
        # not the plain directory next to it that the bare pattern would.
        (("a*b",), ("aXb",)),
        (("a?b",), ("aYb",)),
        (("[x]",), ("x",)),
        (("a\\b",), ("ab",)),
        # A quote or $( in a mount point is no shell code.
        (("it's $(touch pwned)",), ()),
    ],
    ids=["below", "two", "space", "star", "question", "bracket", "backslash", "quote"],
)
def test_entrypoint_re_owns_no_mount_point_below_a_walk(tmp_path, walk, nested, others):
    result, root, reowned, ids = _remap_walk(
        tmp_path, walk, nested=nested, others=others
    )
    assert result.returncode == 0, result.stderr
    # No part of a mount point ran as shell code.
    assert not list(tmp_path.rglob("pwned"))
    left_out = {str(root / name) for name in nested}
    expected = {
        path
        for path in _paths(root)
        if not any(path == m or path.startswith(f"{m}/") for m in left_out)
    }
    # The walk goes on around them: the rest is re-owned, the files below a
    # mount point keep the old IDs, and so does the mount point itself.
    assert {path for path in reowned if path in _paths(root)} == expected
    assert left_out.isdisjoint(reowned)
    names = ", ".join(str(root / name) for name in nested)
    assert (
        f"container-entrypoint: re-owning {root} from {ids} leaves out each mount"
        f" point below it and all it holds: {names}"
    ) in result.stderr.splitlines()
    assert "HOME=" + str(tmp_path / "home" / "dev") in result.stdout.splitlines()


@_needs("sh", "env", "find")
@pytest.mark.parametrize("walk", _WALKS)
def test_entrypoint_re_owns_no_file_mounted_below_a_walk(tmp_path, walk):
    # docker run -v ~/.gitconfig:/home/dev/.gitconfig binds a host file there.
    # find -xdev tests a mount point itself even on another file system, and
    # only keeps out of what is below it.
    result, root, reowned, ids = _remap_walk(tmp_path, walk, files=(".gitconfig",))
    assert result.returncode == 0, result.stderr
    bound = str(root / ".gitconfig")
    assert {path for path in reowned if path in _paths(root)} == _paths(root) - {bound}
    assert (
        f"container-entrypoint: re-owning {root} from {ids} leaves out each mount"
        f" point below it and all it holds: {bound}"
    ) in result.stderr.splitlines()


@_needs("sh", "env", "find")
@pytest.mark.parametrize("walk", _WALKS)
def test_entrypoint_takes_no_sibling_for_a_mount_point_below_a_walk(tmp_path, walk):
    # /workspace2 is no mount point below /workspace.
    result, root, reowned, _ = _remap_walk(tmp_path, walk, sibling=True)
    assert result.returncode == 0, result.stderr
    assert {path for path in reowned if path in _paths(root)} == _paths(root)
    assert "leaves out" not in result.stderr
    assert "mount table" not in result.stderr


@_needs("sh", "env", "find")
@pytest.mark.parametrize("walk", _WALKS)
def test_entrypoint_walks_as_before_without_a_mount_table(tmp_path, walk):
    # The start goes on, and so does the walk, as -xdev alone keeps it: into a
    # mount point of the same file system, which the table would have named.
    result, root, reowned, ids = _remap_walk(
        tmp_path, walk, nested=(".cache",), table=False
    )
    assert result.returncode == 0, result.stderr
    assert {path for path in reowned if path in _paths(root)} == _paths(root)
    assert (
        f"container-entrypoint: could not read the mount table"
        f" {tmp_path / 'mountinfo'}, so re-owning {root} from {ids} may go into a"
        " mount point below it of the same file system"
    ) in result.stderr.splitlines()


@_needs("sh", "env", "find")
def test_entrypoint_walks_the_home_with_reown_alone(tmp_path):
    # A1 (GPT's reviews): docker run -v ~/.gitconfig:/home/dev/.gitconfig.
    # usermod --uid/--gid would re-own it in its own walk of the home, before
    # reown left it out. The usermod that changes the IDs finds a home that
    # does not exist, the one that gives the home back has no --uid or
    # --gid, and the one walk of the home is reown's, which leaves it out.
    uid, gid = os.getuid(), os.getgid()
    result, root, reowned, _ = _remap_walk(tmp_path, "home", files=(".gitconfig",))
    assert result.returncode == 0, result.stderr
    calls = (tmp_path / "calls.log").read_text(encoding="utf-8")
    usermod = _usermod_calls(_other_id(uid), _other_id(gid), str(root))
    assert _calls(calls, "usermod") == usermod
    # gnuchown runs from find's -exec, and setpriv starts the command with
    # the home's tool directories in PATH.
    walks = [
        line
        for line in calls.splitlines()
        if str(root) in line
        and line.split(" ", 1)[0] not in {"gnuchown", "setpriv"}
        and line != usermod[1]
    ]
    assert len(walks) == 1, walks
    assert walks[0].startswith(
        f"find {root} -xdev ( -path {root}/.gitconfig ) -prune -o ("
    )
    assert str(root / ".gitconfig") not in reowned


@_needs("sh", "env", "find")
@pytest.mark.parametrize("walk", _WALKS)
def test_entrypoint_re_owns_nothing_in_a_walk_with_too_many_mount_points(
    tmp_path, walk
):
    # A2 (GPT's review): the operands that leave out 8000 mount points of
    # over 240 bytes each pass the 2 MiB that exec takes with an 8 MiB stack,
    # and find could not start, which stopped the start. There is no walk of
    # that directory now, and a warning says how many there are.
    names = tuple(f"m{i:04}_{'x' * 240}" for i in range(8000))
    result, root, reowned, ids = _remap_walk(tmp_path, walk, listed=names)
    assert result.returncode == 0, result.stderr
    assert not reowned & _paths(root)
    calls = (tmp_path / "calls.log").read_text(encoding="utf-8")
    assert [line for line in _calls(calls, "find") if f" {root} " in line] == []
    assert (
        f"container-entrypoint: re-owning {root} from {ids} would have to leave"
        " out 8000 mount points below it, too many for one find command, so"
        f" nothing in {root} is re-owned"
    ) in result.stderr.splitlines()
    assert "HOME=" + str(tmp_path / "home" / "dev") in result.stdout.splitlines()


@_needs("sh", "env", "find")
@pytest.mark.parametrize("walk", _WALKS)
def test_entrypoint_leaves_out_a_hundred_long_mount_points(tmp_path, walk):
    # Under the limit, which 100 of them stay well below, the walk goes on
    # around each one.
    names = tuple(f"m{i:03}_{'x' * 240}" for i in range(100))
    result, root, reowned, _ = _remap_walk(tmp_path, walk, nested=names)
    assert result.returncode == 0, result.stderr
    left_out = {str(root / name) for name in names}
    expected = {
        path
        for path in _paths(root)
        if not any(path == m or path.startswith(f"{m}/") for m in left_out)
    }
    assert {path for path in reowned if path in _paths(root)} == expected
    assert "would have to leave out" not in result.stderr


@_needs("sh", "env", "find")
@pytest.mark.parametrize("walk", _WALKS)
def test_entrypoint_gives_the_walk_none_of_the_environment(tmp_path, walk):
    # A2 (GPT's second review): an exec takes its arguments and its
    # environment from one limit. find, and the gnuchown it starts, get the
    # entrypoint's PATH and LC_ALL=C (with which -path matches bytes) alone,
    # whatever docker run -e or the image's ENV gave the start, and the walk
    # is the same when the environment has names the entrypoint uses for
    # itself. dash sets OPTIND to 1, and cannot unset it.
    own = ("mountinfo", "unescape_awk", "old_uid", "old_gid", "target_uid")
    result, root, reowned, ids = _remap_walk(
        tmp_path,
        walk,
        nested=(".cache",),
        env={
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
            "DEN_PROBE": "1",
            "OPTIND": "7",
            **dict.fromkeys(own, "/nonexistent"),
            "target_gid": "",
        },
    )
    assert result.returncode == 0, result.stderr
    found = sorted(tmp_path.glob("find-env-*"))
    # With FIX_WORKSPACE_OWNERSHIP=1, the home's walk runs too.
    assert len(found) == (2 if walk == "workspace" else 1)
    for path in found:
        lines = path.read_text(encoding="utf-8").splitlines()
        # The find stub's own sh adds PWD.
        kept = {line for line in lines if not line.startswith("PWD=")}
        assert sorted(kept - {"OPTIND=1"}) == [
            "LC_ALL=C",
            f"PATH={tmp_path / 'stubs'}:/usr/sbin:/usr/bin:/sbin:/bin",
        ]
    cache = str(root / ".cache")
    assert {path for path in reowned if path in _paths(root)} == {
        path for path in _paths(root) if not path.startswith(cache)
    }
    assert (
        f"container-entrypoint: re-owning {root} from {ids} leaves out each mount"
        f" point below it and all it holds: {cache}"
    ) in result.stderr.splitlines()


@_needs("sh", "env", "find")
@pytest.mark.parametrize("walk", _WALKS)
def test_entrypoint_walks_around_mount_points_with_a_large_environment(tmp_path, walk):
    # A2 (GPT's second review): with a stack limit of 512 KiB, exec gets the
    # 128 KiB it gets at the least. 100000 bytes of environment and the
    # operands for 150 mount points of over 200 bytes, under the 64 KiB they
    # may take, were more than that, and find could not start. With none of
    # the environment, the walk goes around each one.
    names = tuple(f"m{i:03}_{'x' * 200}" for i in range(150))
    result, root, reowned, _ = _remap_walk(
        tmp_path,
        walk,
        nested=names,
        env={"DEN_PADDING": "x" * 100000},
        stack_kib=512,
    )
    assert result.returncode == 0, result.stderr
    left_out = {str(root / name) for name in names}
    expected = {
        path
        for path in _paths(root)
        if not any(path == m or path.startswith(f"{m}/") for m in left_out)
    }
    assert {path for path in reowned if path in _paths(root)} == expected
    assert "would have to leave out" not in result.stderr


@_needs("sh", "env", "find")
def test_entrypoint_stops_when_the_workspace_walk_fails(tmp_path):
    result, _, _, _ = _remap_walk(tmp_path, "workspace", nested=(".cache",), fail=True)
    assert result.returncode == 2
    assert result.stderr.splitlines()[-1] == "Workspace ownership adjustment failed"
    assert "HOME=" not in result.stdout


def test_the_image_has_no_volume_instruction():
    # An image built FROM den's could never remove a VOLUME; /state is a
    # mount point the user owns instead.
    assert [kw for kw, _ in _instructions() if kw == "VOLUME"] == []
    _, _, body = _install_step("INSTALL_ENTRYPOINT")
    assert re.search(
        r'^install -d -o "\$USER_UID" -g "\$USER_GID" -m 0700 /state$',
        body,
        flags=re.MULTILINE,
    )


# --- state-link: the home's paths in the state volume --------------------------

_IMAGE_LIST = "/etc/denbox/state-paths.d/denbox.list"
# The file in the volume each run holds a lock on, so that runs take turns.
_LOCK = ".denbox-lock"


def _needs_linux() -> pytest.MarkDecorator:
    # state-link uses GNU mv -T and ln -T, which BSD's mv and ln lack.
    return pytest.mark.skipif(
        sys.platform != "linux" or shutil.which("sh") is None,
        reason="state-link runs on Linux",
    )


def _image_entries() -> list[tuple[str, str]]:
    return [
        (line[0], line[2:])
        for line in _appended_block(_IMAGE_LIST).splitlines()
        if line and not line.startswith("#")
    ]


class _Roots:
    """A home, a state volume, a list directory and a mount table under tmp_path.

    The mount table lists / alone until mount() adds to it, so the home and
    the volume are in one file system, as they are not in a container: these
    tests check what state-link decides, not how far mv or cp copy.
    """

    def __init__(self, tmp_path: Path, home: str = "home") -> None:
        self.tmp = tmp_path
        self.home = tmp_path / home
        self.state = tmp_path / "state"
        self.volume = self.state / "home"
        self.lists = tmp_path / "lists"
        for path in (self.home, self.volume, self.lists):
            path.mkdir(parents=True)
        self.script = tmp_path / "state-link"
        self.script.write_text(_appended_block(_STATE_LINK), encoding="utf-8")
        self.mountinfo = tmp_path / "mountinfo"
        self.mountinfo.write_text(
            "22 1 0:21 / / rw,relatime - overlay overlay rw\n", encoding="utf-8"
        )

    def mount(self, path: Path) -> None:
        """Add a mount point at PATH, escaped as /proc/self/mountinfo does."""
        escaped = _escaped_mount_point(path)
        with self.mountinfo.open("a", encoding="utf-8") as table:
            table.write(f"40 22 0:40 / {escaped} rw,relatime - ext4 /dev/sdb1 rw\n")

    def image_list(self, text: str, name: str = "denbox.list") -> Path:
        path = self.lists / name
        path.write_text(text, encoding="utf-8")
        return path

    def env_list(self, text: str) -> Path:
        path = self.volume / ".config" / "denbox" / "state-paths"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def env(self, **changes: str) -> dict[str, str]:
        return {
            "HOME": str(self.home),
            "DENBOX_STATE_ROOT": str(self.state),
            "DENBOX_STATE_LISTS": str(self.lists),
            "DENBOX_STATE_MOUNTINFO": str(self.mountinfo),
            "PATH": SYSTEM_PATH,
            **changes,
        }

    def run(
        self, *, home: Path | None = None, **changes: str
    ) -> subprocess.CompletedProcess[str]:
        if home is not None:
            changes["HOME"] = str(home)
        return subprocess.run(
            [_tool("sh"), str(self.script)],
            env=self.env(**changes),
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )

    def linked(self, rel: str) -> bool:
        path = self.home / rel
        return path.is_symlink() and path.readlink() == self.volume / rel

    def volume_names(self) -> list[str]:
        """The names in the volume but the lock file, which each run leaves."""
        return sorted(p.name for p in self.volume.iterdir() if p.name != _LOCK)

    def fake(self, name: str, body: str) -> str:
        """Put a NAME command running BODY first on PATH; return that PATH."""
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir(exist_ok=True)
        path = bin_dir / name
        path.write_text(f"#!{_tool('sh')}\n{body}", encoding="utf-8")
        path.chmod(0o755)
        return f"{bin_dir}:{SYSTEM_PATH}"


@_needs_linux()
def test_state_link_links_each_kind(tmp_path):
    roots = _Roots(tmp_path)
    roots.image_list("d .config/tool\nF .tool_history\nf .toolrc\n")
    result = roots.run()
    assert (result.returncode, result.stderr) == (0, "")
    # d: a new directory in the volume; F: a new empty file; parents made.
    assert roots.linked(".config/tool")
    assert (roots.volume / ".config/tool").is_dir()
    assert roots.linked(".tool_history")
    assert (roots.volume / ".tool_history").read_bytes() == b""
    # f: neither has one, so nothing is made or linked.
    assert not (roots.home / ".toolrc").exists()
    assert not (roots.home / ".toolrc").is_symlink()
    assert not (roots.volume / ".toolrc").exists()
    # The lock file each run holds is the user's alone, and stays.
    lock = roots.volume / _LOCK
    assert lock.is_file()
    assert not lock.is_symlink()
    assert stat.S_IMODE(lock.stat().st_mode) == 0o600


@_needs_linux()
def test_state_link_moves_what_the_home_has_into_an_empty_volume(tmp_path):
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\nF .zsh_history\nf .toolrc\n")
    (roots.home / ".ssh").mkdir()
    (roots.home / ".ssh" / "id_ed25519").write_text("key\n", encoding="utf-8")
    (roots.home / ".zsh_history").write_text("ls\n", encoding="utf-8")
    (roots.home / ".toolrc").write_text("x=1\n", encoding="utf-8")
    result = roots.run()
    assert (result.returncode, result.stderr) == (0, "")
    for rel in (".ssh", ".zsh_history", ".toolrc"):
        assert roots.linked(rel), rel
    assert (roots.volume / ".ssh" / "id_ed25519").read_text(encoding="utf-8") == "key\n"
    assert (roots.volume / ".zsh_history").read_text(encoding="utf-8") == "ls\n"
    assert (roots.volume / ".toolrc").read_text(encoding="utf-8") == "x=1\n"


@_needs_linux()
def test_state_link_links_an_f_entry_the_volume_has(tmp_path):
    roots = _Roots(tmp_path)
    roots.image_list("f .toolrc\n")
    (roots.volume / ".toolrc").write_text("kept\n", encoding="utf-8")
    result = roots.run()
    assert (result.returncode, result.stderr) == (0, "")
    assert roots.linked(".toolrc")


def _aside_dirs(roots: _Roots) -> list[Path]:
    return sorted((roots.volume / ".denbox-set-aside").iterdir())


@_needs_linux()
def test_state_link_sets_the_home_copy_aside_in_the_volume(tmp_path):
    # B7: the copy a new container's home has (the image's, or one that
    # replaced a link) goes into the volume, never into the container's
    # layer, which the next new container loses; and it is said.
    roots = _Roots(tmp_path)
    roots.image_list("F .zsh_history\nd .config/gh\n")
    (roots.volume / ".zsh_history").write_text("volume\n", encoding="utf-8")
    (roots.volume / ".config" / "gh").mkdir(parents=True)
    (roots.volume / ".config" / "gh" / "hosts.yml").write_text("v\n", encoding="utf-8")
    (roots.home / ".zsh_history").write_text("home\n", encoding="utf-8")
    (roots.home / ".config" / "gh").mkdir(parents=True)
    (roots.home / ".config" / "gh" / "hosts.yml").write_text("h\n", encoding="utf-8")
    (roots.home / ".config" / "gh" / "extra.yml").write_text("e\n", encoding="utf-8")
    result = roots.run()
    # A set-aside is a note: the entry is linked, so the exit status is 0.
    assert result.returncode == 0, result.stderr
    assert roots.linked(".zsh_history")
    assert roots.linked(".config/gh")
    assert (roots.volume / ".zsh_history").read_text(encoding="utf-8") == "volume\n"
    assert (roots.volume / ".config/gh/hosts.yml").read_text(encoding="utf-8") == "v\n"
    # Both have the directory: what only the home's holds moves into the
    # volume's, and only what both hold goes aside.
    assert (roots.volume / ".config/gh/extra.yml").read_text(encoding="utf-8") == "e\n"
    [aside] = _aside_dirs(roots)
    assert re.fullmatch(r"\d{8}T\d{6}Z", aside.name)
    assert (aside / ".zsh_history").read_text(encoding="utf-8") == "home\n"
    assert [p.name for p in (aside / ".config/gh").iterdir()] == ["hosts.yml"]
    assert (aside / ".config/gh/hosts.yml").read_text(encoding="utf-8") == "h\n"
    assert not (roots.volume / ".denbox-staging").exists()
    notes = result.stderr.splitlines()
    assert notes == [
        f"state-link: {roots.lists}/denbox.list:{line}: {roots.volume}/{rel} and"
        f" {roots.home}/{rel} both existed: kept {roots.volume}/{rel},"
        f" moved {roots.home}/{rel} to {aside}/{rel}"
        for line, rel in ((1, ".zsh_history"), (2, ".config/gh/hosts.yml"))
    ]


@_needs_linux()
def test_state_link_deletes_an_empty_home_directory_the_volume_has(tmp_path):
    roots = _Roots(tmp_path)
    roots.image_list("d .config/gh\n")
    (roots.volume / ".config" / "gh").mkdir(parents=True)
    (roots.home / ".config" / "gh").mkdir(parents=True)
    result = roots.run()
    assert (result.returncode, result.stderr) == (0, "")
    assert roots.linked(".config/gh")
    assert not (roots.volume / ".denbox-set-aside").exists()


@_needs_linux()
def test_state_link_changes_nothing_the_second_time(tmp_path):
    roots = _Roots(tmp_path)
    roots.image_list("".join(f"{kind} {rel}\n" for kind, rel in _image_entries()))
    (roots.home / ".zsh_history").write_text("ls\n", encoding="utf-8")
    first = roots.run()
    assert (first.returncode, first.stderr) == (0, "")
    before = {rel: (roots.home / rel).lstat().st_ino for _, rel in _image_entries()}
    second = roots.run()
    assert (second.returncode, second.stderr, second.stdout) == (0, "", "")
    for rel, inode in before.items():
        assert roots.linked(rel), rel
        assert (roots.home / rel).lstat().st_ino == inode, rel


@_needs_linux()
@pytest.mark.parametrize(
    ("rel", "mounted"),
    [
        (".ssh", ".ssh"),  # -v ~/.ssh:/home/dev/.ssh
        (".ssh", ".ssh/id_ed25519"),  # a file bound into it
        (".config/gh", ".config"),  # -v ~/.config:/home/dev/.config
        (".ssh", ""),  # the whole home
    ],
)
def test_state_link_moves_and_links_nothing_on_a_mount_point(tmp_path, rel, mounted):
    # A host directory bound into the home: a move into the volume, another
    # file system, would copy it and then delete it on the host. The entry is
    # skipped with a warning that names the mount point.
    roots = _Roots(tmp_path)
    roots.image_list(f"d {rel}\nF .after\n")
    (roots.home / rel).mkdir(parents=True)
    (roots.home / rel / "id_ed25519").write_text("key\n", encoding="utf-8")
    mount = roots.home / mounted if mounted else roots.home
    roots.mount(mount)
    result = roots.run()
    assert result.returncode == 1
    lines = result.stderr.splitlines()
    assert lines[0] == (
        f"state-link: {roots.lists}/denbox.list:1: skipped {rel}: mount point"
        f" {mount} is at, above or inside {roots.home}/{rel}"
    )
    assert (roots.home / rel / "id_ed25519").read_text(encoding="utf-8") == "key\n"
    assert not (roots.home / rel).is_symlink()
    assert not (roots.volume / rel).exists()
    assert not (roots.volume / ".denbox-staging").exists()
    if mounted:
        # Only that entry: the next line goes on.
        assert lines[1:] == []
        assert roots.linked(".after")


@_needs_linux()
def test_state_link_makes_no_link_in_a_mount_point(tmp_path):
    # Not even a new link: in a bound host directory it would dangle on the
    # host.
    roots = _Roots(tmp_path)
    roots.image_list("d .config/gh\n")
    (roots.home / ".config").mkdir()
    roots.mount(roots.home / ".config")
    result = roots.run()
    assert result.returncode == 1
    assert "skipped .config/gh: mount point" in result.stderr
    assert list((roots.home / ".config").iterdir()) == []
    assert not (roots.volume / ".config").exists()


@_needs_linux()
def test_state_link_reads_an_escaped_mount_point(tmp_path):
    # The mount table writes a space in a path as \040.
    roots = _Roots(tmp_path, home="my home")
    roots.image_list("d .ssh\n")
    (roots.home / ".ssh").mkdir()
    roots.mount(roots.home / ".ssh")
    assert "my\\040home" in roots.mountinfo.read_text(encoding="utf-8")
    result = roots.run()
    assert result.returncode == 1
    assert f"mount point {roots.home}/.ssh is at" in result.stderr
    assert not (roots.volume / ".ssh").exists()


@_needs_linux()
@pytest.mark.parametrize(
    ("rel", "mounted"),
    [
        (".ssh", ".ssh"),
        (".config/gh", ".config"),
        (".ssh", ".ssh/keys"),
        (".config", ".config/gh"),  # an environment entry above an image one
    ],
    ids=["at", "above", "inside", "parent-entry"],
)
def test_state_link_moves_and_makes_nothing_on_a_mount_point_in_the_volume(
    tmp_path, rel, mounted
):
    # A mount below /state/home is another file system: a move renames its
    # copy from the staging directory into place, and mv across file systems
    # copies again, straight into the live path, which a stop leaves part
    # done. The entry is skipped with a warning that names the mount point.
    roots = _Roots(tmp_path)
    roots.image_list(f"d {rel}\nF .after\n")
    (roots.home / rel).mkdir(parents=True)
    (roots.home / rel / "id_ed25519").write_text("key\n", encoding="utf-8")
    mount = roots.volume / mounted
    mount.mkdir(parents=True)
    roots.mount(mount)
    result = roots.run()
    assert result.returncode == 1
    assert result.stderr.splitlines() == [
        f"state-link: {roots.lists}/denbox.list:1: skipped {rel}: mount point"
        f" {mount} is at, above or inside {roots.volume}/{rel}"
    ]
    assert (roots.home / rel / "id_ed25519").read_text(encoding="utf-8") == "key\n"
    assert not (roots.home / rel).is_symlink()
    assert not (roots.volume / rel / "id_ed25519").exists()
    assert not (roots.volume / ".denbox-staging").exists()
    assert not (roots.volume / ".denbox-set-aside").exists()
    # Only that entry: the next line goes on.
    assert roots.linked(".after")


@_needs_linux()
def test_state_link_takes_the_volumes_own_mount_points_for_its_own(tmp_path):
    # /state is a mount point, and /state/home may be one too: neither is
    # below the volume, and the entries in it go on.
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\nF .zsh_history\n")
    (roots.home / ".ssh").mkdir()
    (roots.home / ".ssh" / "id_ed25519").write_text("key\n", encoding="utf-8")
    (roots.volume / ".zsh_history").write_text("volume\n", encoding="utf-8")
    (roots.home / ".zsh_history").write_text("home\n", encoding="utf-8")
    roots.mount(roots.state)
    roots.mount(roots.volume)
    result = roots.run()
    assert result.returncode == 0, result.stderr
    assert roots.linked(".ssh")
    assert roots.linked(".zsh_history")
    assert (roots.volume / ".ssh/id_ed25519").read_text(encoding="utf-8") == "key\n"
    [aside] = _aside_dirs(roots)
    assert (aside / ".zsh_history").read_text(encoding="utf-8") == "home\n"


@_needs_linux()
@pytest.mark.parametrize("mounted", [".denbox-staging", ".denbox-staging/old"])
def test_state_link_moves_nothing_through_a_staging_directory_on_a_mount_point(
    tmp_path, mounted
):
    # Each move renames its copy from the staging directory: on another file
    # system, that rename is a copy too. What is in it stays where it is,
    # and an entry that needs no move goes on.
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\nd .config/gh\nF .new\n")
    (roots.home / ".ssh").mkdir()
    (roots.home / ".ssh" / "id_ed25519").write_text("key\n", encoding="utf-8")
    (roots.home / ".config" / "gh").mkdir(parents=True)
    (roots.home / ".config" / "gh" / "hosts.yml").write_text("h\n", encoding="utf-8")
    (roots.volume / ".config" / "gh").mkdir(parents=True)
    staging = roots.volume / ".denbox-staging"
    mount = roots.volume / mounted
    mount.mkdir(parents=True)
    (mount / "left").write_text("k", encoding="utf-8")
    roots.mount(mount)
    result = roots.run()
    assert result.returncode == 1
    why = f"state-link: mount point {mount} is at, above or inside {staging}"
    assert result.stderr.splitlines() == [
        why,
        f"state-link: left {staging} as it is; nothing moves into {roots.volume}",
        why,
        f"state-link: {roots.lists}/denbox.list:1: skipped .ssh: could not move"
        f" {roots.home}/.ssh into {roots.volume}",
        why,
        f"state-link: {roots.lists}/denbox.list:2: skipped .config/gh: could not move"
        f" all of {roots.home}/.config/gh into {roots.volume}/.config/gh or aside",
    ]
    assert (roots.home / ".ssh" / "id_ed25519").read_text(encoding="utf-8") == "key\n"
    assert (roots.home / ".config/gh/hosts.yml").read_text(encoding="utf-8") == "h\n"
    assert list((roots.volume / ".config" / "gh").iterdir()) == []
    assert (mount / "left").read_text(encoding="utf-8") == "k"
    assert sorted(p.name for p in staging.iterdir()) == [
        "left" if mounted == ".denbox-staging" else "old"
    ]
    assert not (roots.volume / ".denbox-set-aside").exists()
    assert roots.linked(".new")


@_needs_linux()
@pytest.mark.parametrize("mounted", [".denbox-set-aside", ".denbox-set-aside/old"])
def test_state_link_sets_nothing_aside_into_a_mount_point(tmp_path, mounted):
    # A set-aside renames its copy from the staging directory as a move does.
    # A merge that may need one moves nothing; a leftover staging copy stays.
    roots = _Roots(tmp_path)
    roots.image_list("F .zsh_history\nd .config/gh\nF .new\n")
    (roots.volume / ".zsh_history").write_text("volume\n", encoding="utf-8")
    (roots.home / ".zsh_history").write_text("home\n", encoding="utf-8")
    (roots.volume / ".config" / "gh").mkdir(parents=True)
    (roots.volume / ".config" / "gh" / "hosts.yml").write_text("v\n", encoding="utf-8")
    (roots.home / ".config" / "gh").mkdir(parents=True)
    (roots.home / ".config" / "gh" / "hosts.yml").write_text("h\n", encoding="utf-8")
    (roots.home / ".config" / "gh" / "extra.yml").write_text("e\n", encoding="utf-8")
    staging = roots.volume / ".denbox-staging"
    (staging / ".gone").mkdir(parents=True)
    aside_root = roots.volume / ".denbox-set-aside"
    mount = roots.volume / mounted
    mount.mkdir(parents=True)
    roots.mount(mount)
    result = roots.run()
    assert result.returncode == 1
    why = f"state-link: mount point {mount} is at, above or inside {aside_root}"
    assert result.stderr.splitlines() == [
        why,
        f"state-link: could not set {staging} aside",
        why,
        f"state-link: {roots.lists}/denbox.list:1: skipped .zsh_history: could not"
        f" set {roots.home}/.zsh_history aside",
        why,
        f"state-link: {roots.lists}/denbox.list:2: skipped .config/gh: could not move"
        f" all of {roots.home}/.config/gh into {roots.volume}/.config/gh or aside",
    ]
    assert (roots.home / ".zsh_history").read_text(encoding="utf-8") == "home\n"
    assert not (roots.home / ".zsh_history").is_symlink()
    assert (roots.volume / ".zsh_history").read_text(encoding="utf-8") == "volume\n"
    # Nothing of the merge moved, not even the name only the home has.
    assert sorted(p.name for p in (roots.home / ".config/gh").iterdir()) == [
        "extra.yml",
        "hosts.yml",
    ]
    assert [p.name for p in (roots.volume / ".config/gh").iterdir()] == ["hosts.yml"]
    assert [p.name for p in staging.iterdir()] == [".gone"]
    assert [p.name for p in aside_root.iterdir()] == (
        [] if mounted == ".denbox-set-aside" else ["old"]
    )
    assert roots.linked(".new")


@_needs_linux()
@pytest.mark.parametrize("spelling", ["slash", "dot", "double-slash", "linked-parent"])
def test_state_link_finds_a_mount_point_whatever_the_spelling_of_home(
    tmp_path, spelling
):
    # The mount table names mount points by their physical paths: HOME with a
    # trailing slash, a '.', a '//' or a linked directory above it must not
    # hide a host directory bound into the home from that check.
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\n")
    (roots.home / ".ssh").mkdir()
    (roots.home / ".ssh" / "id_ed25519").write_text("key\n", encoding="utf-8")
    roots.mount(roots.home / ".ssh")
    (tmp_path / "alias").symlink_to(tmp_path)
    home = {
        "slash": f"{roots.home}/",
        "dot": f"{roots.home}/.",
        "double-slash": f"{tmp_path}//home",
        "linked-parent": f"{tmp_path}/alias/home",
    }[spelling]
    result = roots.run(HOME=home)
    assert result.returncode == 1
    assert result.stderr == (
        f"state-link: {roots.lists}/denbox.list:1: skipped .ssh: mount point"
        f" {roots.home}/.ssh is at, above or inside {roots.home}/.ssh\n"
    )
    assert (roots.home / ".ssh" / "id_ed25519").read_text(encoding="utf-8") == "key\n"
    assert not (roots.home / ".ssh").is_symlink()
    assert roots.volume_names() == []


@_needs_linux()
def test_state_link_links_to_the_physical_path_of_the_volume(tmp_path):
    # So the next run, given the usual spelling, finds the link right.
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\n")
    result = roots.run(DENBOX_STATE_ROOT=f"{roots.state}//")
    assert (result.returncode, result.stderr) == (0, "")
    # The link's text as it is: Path.readlink would fold a '//' away.
    target = os.readlink(roots.home / ".ssh")  # ruff: ignore[os-readlink]
    assert target == str(roots.volume / ".ssh")


@_needs_linux()
@pytest.mark.parametrize("home_has_it", [True, False])
def test_state_link_sets_aside_the_unfinished_copies_an_earlier_run_left(
    tmp_path, home_has_it
):
    # A run that KILL or a crash stopped while it copied ~/.ssh left part of
    # it in the staging directory. In a new container on the volume, the home
    # that held the only whole copy is gone, and a .ssh the image ships may
    # stand in its place: the part is never deleted, and never taken for the
    # volume's copy. It goes aside, named after its path, with what a list no
    # longer names.
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\n")
    if home_has_it:
        (roots.home / ".ssh").mkdir()
        (roots.home / ".ssh" / "id_ed25519").write_text("key\n", encoding="utf-8")
    staging = roots.volume / ".denbox-staging"
    (staging / ".ssh").mkdir(parents=True)
    (staging / ".ssh" / "id_ed25519").write_text("k", encoding="utf-8")
    (staging / ".gone").mkdir()
    result = roots.run()
    assert result.returncode == 0, result.stderr
    [aside] = _aside_dirs(roots)
    assert result.stderr == (
        f"state-link: moved {staging}, unfinished copies that an earlier run left,"
        f" to {aside}/.denbox-staging\n"
    )
    left = aside / ".denbox-staging"
    assert (left / ".ssh" / "id_ed25519").read_text(encoding="utf-8") == "k"
    assert (left / ".gone").is_dir()
    assert roots.linked(".ssh")
    if home_has_it:
        assert (roots.volume / ".ssh/id_ed25519").read_text(encoding="utf-8") == "key\n"
    else:
        assert list((roots.volume / ".ssh").iterdir()) == []
    assert not staging.exists()


@_needs_linux()
def test_state_link_copies_nothing_over_a_leftover_it_could_not_set_aside(tmp_path):
    # B2: with the set-aside root a link, the leftover stays where it is, and
    # no copy goes into its name or through the link.
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\n")
    (roots.home / ".ssh").mkdir()
    (roots.home / ".ssh" / "id_ed25519").write_text("key\n", encoding="utf-8")
    outside = tmp_path / "outside"
    outside.mkdir()
    aside_root = roots.volume / ".denbox-set-aside"
    aside_root.symlink_to(outside)
    staging = roots.volume / ".denbox-staging"
    slot = staging / ".ssh"
    slot.mkdir(parents=True)
    (slot / "id_ed25519").write_text("k", encoding="utf-8")
    result = roots.run()
    assert result.returncode == 1
    assert result.stderr.splitlines() == [
        f"state-link: {aside_root} is not a directory",
        f"state-link: could not set {staging} aside",
        f"state-link: {slot} is in the way",
        f"state-link: {roots.lists}/denbox.list:1: skipped .ssh: could not move"
        f" {roots.home}/.ssh into {roots.volume}",
    ]
    assert [p.name for p in slot.iterdir()] == ["id_ed25519"]
    assert (slot / "id_ed25519").read_text(encoding="utf-8") == "k"
    assert (roots.home / ".ssh" / "id_ed25519").read_text(encoding="utf-8") == "key\n"
    assert list(outside.iterdir()) == []


@_needs_linux()
def test_state_link_removes_the_copy_it_was_making_when_a_signal_stops_it(tmp_path):
    # The entrypoint's time limit sends TERM. The copy under way is part of
    # what the home still has whole, so it goes, and the next start starts
    # that path again instead of setting one more part aside.
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\n")
    (roots.home / ".ssh").mkdir()
    (roots.home / ".ssh" / "id_ed25519").write_text("key\n", encoding="utf-8")
    slot = roots.volume / ".denbox-staging" / ".ssh"
    stopping_cp = roots.fake(
        "cp",
        "for arg do last=$arg; done\n"
        'mkdir "$last" && : > "$last/part"\n'
        'kill -TERM "$PPID"\n'
        'kill -TERM "$$"\n',
    )
    result = roots.run(PATH=stopping_cp)
    assert result.returncode == 143
    assert result.stderr.splitlines()[-1] == (
        f"state-link: stopped by a signal; removed {slot}, the unfinished copy it"
        " was making"
    )
    assert not slot.exists()
    assert (roots.home / ".ssh" / "id_ed25519").read_text(encoding="utf-8") == "key\n"
    assert not (roots.home / ".ssh").is_symlink()
    again = roots.run()
    assert (again.returncode, again.stderr) == (0, "")
    assert roots.linked(".ssh")
    assert roots.volume_names() == [".ssh"]


@_needs_linux()
def test_state_link_takes_turns_with_another_run_on_the_volume(tmp_path):
    # Two runs at once (a second container's start, or a run by hand during
    # one) would each take the other's staging copy for a leftover. Each
    # holds a lock on a file in the volume; a run waits for it a while, and
    # then gives up and links nothing.
    # fcntl is Unix only, and this test runs on Linux alone.
    import fcntl

    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\n")
    (roots.home / ".ssh").mkdir()
    (roots.home / ".ssh" / "id_ed25519").write_text("key\n", encoding="utf-8")
    lock = roots.volume / _LOCK
    with lock.open("a", encoding="utf-8") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        result = roots.run(DENBOX_STATE_LOCK_WAIT="1")
        assert result.returncode == 1
        assert result.stderr == (
            f"state-link: another run of state-link holds {lock}; nothing is linked\n"
        )
        assert not (roots.home / ".ssh").is_symlink()
        assert roots.volume_names() == []
        # A run that waits goes on once the other run lets go.
        release = threading.Timer(1, fcntl.flock, (held, fcntl.LOCK_UN))
        release.start()
        result = roots.run(DENBOX_STATE_LOCK_WAIT="30")
        release.join()
    assert (result.returncode, result.stderr) == (0, "")
    assert roots.linked(".ssh")


@_needs_linux()
@pytest.mark.parametrize("kind", ["link", "directory"])
def test_state_link_takes_no_lock_but_on_a_regular_file(tmp_path, kind):
    roots = _Roots(tmp_path)
    roots.image_list("F .first\n")
    lock = roots.volume / _LOCK
    target = tmp_path / "elsewhere"
    target.write_text("kept\n", encoding="utf-8")
    if kind == "link":
        lock.symlink_to(target)
    else:
        lock.mkdir()
    result = roots.run()
    assert result.returncode == 1
    assert result.stderr == (
        f"state-link: {lock} is not a regular file; nothing is linked\n"
    )
    assert not (roots.home / ".first").exists()
    assert target.read_text(encoding="utf-8") == "kept\n"


@_needs_linux()
def test_state_link_removes_a_copy_that_failed_and_keeps_the_home_path(tmp_path):
    # A copy that stops part way (a full volume, say) is never renamed into
    # place: it is removed, and the home keeps the path for the next start.
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\n")
    (roots.home / ".ssh").mkdir()
    (roots.home / ".ssh" / "id_ed25519").write_text("key\n", encoding="utf-8")
    failing_cp = roots.fake(
        "cp",
        "for arg do last=$arg; done\n"
        'mkdir "$last" && : > "$last/part"\n'
        "echo 'cp: write error: No space left on device' >&2\n"
        "exit 1\n",
    )
    result = roots.run(PATH=failing_cp)
    assert result.returncode == 1
    assert result.stderr.splitlines() == [
        "cp: write error: No space left on device",
        f"state-link: {roots.lists}/denbox.list:1: skipped .ssh: could not move"
        f" {roots.home}/.ssh into {roots.volume}",
    ]
    assert (roots.home / ".ssh" / "id_ed25519").read_text(encoding="utf-8") == "key\n"
    assert not (roots.home / ".ssh").is_symlink()
    assert roots.volume_names() == []


@_needs_linux()
def test_state_link_copies_nothing_that_it_could_not_remove_from_the_home(tmp_path):
    # A path this user cannot remove whole (a directory in it another user
    # owns, or a read-only file system) would be copied at each start and
    # never moved; it is skipped before anything is copied.
    if os.geteuid() == 0:
        pytest.skip("root removes every file")
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\n")
    locked = roots.home / ".ssh" / "locked"
    locked.mkdir(parents=True)
    (locked / "id_ed25519").write_text("key\n", encoding="utf-8")
    locked.chmod(0o500)
    try:
        for _ in range(2):
            result = roots.run()
            assert result.returncode == 1
            assert result.stderr.splitlines() == [
                f"state-link: {roots.home}/.ssh: this user cannot read and remove"
                " all of it",
                f"state-link: {roots.lists}/denbox.list:1: skipped .ssh: could not move"
                f" {roots.home}/.ssh into {roots.volume}",
            ]
            assert roots.volume_names() == []
            assert (locked / "id_ed25519").read_text(encoding="utf-8") == "key\n"
    finally:
        locked.chmod(0o700)


@_needs_linux()
@pytest.mark.parametrize("where", ["inside", "above"])
def test_state_link_copies_nothing_that_a_sticky_directory_keeps(tmp_path, where):
    # In a sticky directory (mode 1000) that another user owns, only the
    # owner of a name may remove it, and access(2) does not say so: cp and mv
    # would succeed, rm would fail, and each start would add a copy. A fake
    # id names another user here, so the directories this user made stand
    # for another user's: one in the path, or the one the path is in.
    if os.geteuid() == 0:
        pytest.skip("root removes every file")
    roots = _Roots(tmp_path)
    rel = ".ssh" if where == "inside" else "shared/.ssh"
    sticky = (
        roots.home / ".ssh" / "shared" if where == "inside" else roots.home / "shared"
    )
    sticky.mkdir(parents=True)
    (roots.home / rel).mkdir(exist_ok=True)
    (roots.home / rel / "id_ed25519").write_text("key\n", encoding="utf-8")
    roots.image_list(f"d {rel}\n")
    other_user = roots.fake("id", "echo 4242\n")
    sticky.chmod(0o1700)
    try:
        result = roots.run(PATH=other_user)
    finally:
        sticky.chmod(0o700)
    assert result.returncode == 1
    assert result.stderr.splitlines() == [
        f"state-link: {roots.home}/{rel}: this user cannot read and remove all of it",
        f"state-link: {roots.lists}/denbox.list:1: skipped {rel}: could not move"
        f" {roots.home}/{rel} into {roots.volume}",
    ]
    assert (roots.home / rel / "id_ed25519").read_text(encoding="utf-8") == "key\n"
    assert not (roots.volume / rel).exists()


@_needs_linux()
def test_state_link_moves_a_parent_entry_into_the_volume_name_by_name(tmp_path):
    # An environment's `d .config` after the image's `d .config/gh`: the
    # volume's .config is there only for gh, so the home's .config moves into
    # it name by name instead of going aside whole (den's zsh plugins and pwsh
    # profile are in it), and gh needs nothing more once ~/.config is a link.
    roots = _Roots(tmp_path)
    roots.image_list("d .config/gh\n")
    plugins = roots.home / ".config" / "zsh" / "plugins"
    plugins.mkdir(parents=True)
    (plugins / "init.zsh").write_text("p\n", encoding="utf-8")
    first = roots.run()
    assert (first.returncode, first.stderr) == (0, "")
    roots.env_list("d .config\n")
    for _ in range(2):
        result = roots.run()
        assert (result.returncode, result.stderr) == (0, "")
        assert roots.linked(".config")
        assert (roots.volume / ".config/zsh/plugins/init.zsh").read_text(
            encoding="utf-8"
        ) == "p\n"
        assert (roots.volume / ".config/gh").is_dir()
        assert not (roots.volume / ".config/gh").is_symlink()
        assert not (roots.volume / ".denbox-set-aside").exists()
        assert not (roots.volume / ".denbox-staging").exists()


@_needs_linux()
def test_state_link_merges_nothing_unless_all_of_the_home_directory_can_move(
    tmp_path,
):
    # The same `d .config`, with a directory in ~/.config that this user
    # cannot move (an image built FROM den left it root's): nothing moves,
    # the link for gh stays, and the next start does the same, not another
    # half of the merge.
    if os.geteuid() == 0:
        pytest.skip("root removes every file")
    roots = _Roots(tmp_path)
    roots.image_list("d .config/gh\n")
    plugins = roots.home / ".config" / "zsh" / "plugins"
    plugins.mkdir(parents=True)
    (plugins / "init.zsh").write_text("p\n", encoding="utf-8")
    first = roots.run()
    assert (first.returncode, first.stderr) == (0, "")
    locked = roots.home / ".config" / "starship"
    locked.mkdir()
    (locked / "starship.toml").write_text("s\n", encoding="utf-8")
    env_list = roots.env_list("d .config\n")
    locked.chmod(0o500)
    try:
        for _ in range(2):
            result = roots.run()
            assert result.returncode == 1
            assert result.stderr.splitlines() == [
                f"state-link: {roots.home}/.config: this user cannot read and remove"
                " all of it",
                f"state-link: {env_list}:1: skipped .config: could not move all of"
                f" {roots.home}/.config into {roots.volume}/.config or aside",
            ]
            assert roots.linked(".config/gh")
            assert sorted(p.name for p in (roots.home / ".config").iterdir()) == [
                "gh",
                "starship",
                "zsh",
            ]
            assert (plugins / "init.zsh").read_text(encoding="utf-8") == "p\n"
            assert sorted(p.name for p in (roots.volume / ".config").iterdir()) == [
                "denbox",
                "gh",
            ]
            assert not (roots.volume / ".denbox-set-aside").exists()
    finally:
        locked.chmod(0o700)


@_needs_linux()
def test_state_link_keeps_the_links_in_a_directory_whose_merge_stops_part_way(
    tmp_path,
):
    # A copy that fails during the merge (a full volume, say) stops it. The
    # links that entries inside the directory made go only after all else
    # moved, so they still work until a later start finishes the merge.
    roots = _Roots(tmp_path)
    roots.image_list("d .config/gh\n")
    plugins = roots.home / ".config" / "zsh" / "plugins"
    plugins.mkdir(parents=True)
    (plugins / "init.zsh").write_text("p\n", encoding="utf-8")
    first = roots.run()
    assert (first.returncode, first.stderr) == (0, "")
    env_list = roots.env_list("d .config\n")
    failing_cp = roots.fake(
        "cp", "echo 'cp: write error: No space left on device' >&2\nexit 1\n"
    )
    result = roots.run(PATH=failing_cp)
    assert result.returncode == 1
    assert result.stderr.splitlines() == [
        "cp: write error: No space left on device",
        f"state-link: {env_list}:1: skipped .config: could not move all of"
        f" {roots.home}/.config into {roots.volume}/.config or aside",
    ]
    assert roots.linked(".config/gh")
    assert (plugins / "init.zsh").read_text(encoding="utf-8") == "p\n"
    again = roots.run()
    assert (again.returncode, again.stderr) == (0, "")
    assert roots.linked(".config")
    assert (roots.volume / ".config/zsh/plugins/init.zsh").read_text(
        encoding="utf-8"
    ) == "p\n"


@_needs_linux()
def test_state_link_merges_a_directory_both_have_at_any_depth(tmp_path):
    # `d .local` after the image's `d .local/share/zoxide`: ~/.local/share is
    # in both, and so is ~/.local/share/powershell. Each is merged name by
    # name, so uv's tools (den's own install among them) move into the volume
    # instead of going aside while ~/.local becomes a link to a volume without
    # them. A name both have, however deep, still goes aside to its own path.
    roots = _Roots(tmp_path)
    roots.image_list("d .local/share/zoxide\nd .local/share/powershell/PSReadLine\n")
    local = roots.home / ".local"
    (local / "bin").mkdir(parents=True)
    (local / "bin" / "den").write_text("bin\n", encoding="utf-8")
    (local / "share" / "uv" / "tools" / "den").mkdir(parents=True)
    (local / "share" / "uv" / "tools" / "den" / "x").write_text(
        "uv\n", encoding="utf-8"
    )
    (local / "share" / "powershell" / "Modules").mkdir(parents=True)
    (local / "share" / "powershell" / "Modules" / "m").write_text(
        "home\n", encoding="utf-8"
    )
    first = roots.run()
    assert (first.returncode, first.stderr) == (0, "")
    deep = ".local/share/powershell/Modules/m"
    (roots.volume / deep).parent.mkdir()
    (roots.volume / deep).write_text("volume\n", encoding="utf-8")
    env_list = roots.env_list("d .local\n")
    # Each copy is staged under its own path, with ':' for '/'.
    staged = tmp_path / "staged"
    logging_cp = roots.fake(
        "cp",
        "for arg do last=$arg; done\n"
        f'printf "%s\\n" "${{last##*/}}" >> {shlex.quote(str(staged))}\n'
        f'exec {shlex.quote(_tool("cp"))} "$@"\n',
    )
    result = roots.run(PATH=logging_cp)
    assert result.returncode == 0, result.stderr
    [aside] = _aside_dirs(roots)
    assert result.stderr == (
        f"state-link: {env_list}:1: {roots.volume}/{deep} and {roots.home}/{deep}"
        f" both existed: kept {roots.volume}/{deep}, moved {roots.home}/{deep}"
        f" to {aside}/{deep}\n"
    )
    assert roots.linked(".local")
    assert (roots.volume / ".local/bin/den").read_text(encoding="utf-8") == "bin\n"
    uv_file = roots.volume / ".local/share/uv/tools/den/x"
    assert uv_file.read_text(encoding="utf-8") == "uv\n"
    assert (roots.volume / deep).read_text(encoding="utf-8") == "volume\n"
    assert (aside / deep).read_text(encoding="utf-8") == "home\n"
    assert [p.name for p in aside.iterdir()] == [".local"]
    for rel in (".local/share/zoxide", ".local/share/powershell/PSReadLine"):
        assert (roots.volume / rel).is_dir(), rel
        assert not (roots.volume / rel).is_symlink(), rel
    assert staged.read_text(encoding="utf-8").split() == [
        ".local:bin",
        ".local:share:powershell:Modules:m",
        ".local:share:uv",
    ]
    again = roots.run()
    assert (again.returncode, again.stderr) == (0, "")
    assert not (roots.volume / ".denbox-staging").exists()


@_needs_linux()
def test_state_link_replaces_a_dangling_home_link(tmp_path):
    # B5: a link that points nowhere is replaced, without a word.
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\n")
    (roots.home / ".ssh").symlink_to(tmp_path / "missing")
    result = roots.run()
    assert (result.returncode, result.stderr) == (0, "")
    assert roots.linked(".ssh")
    assert list((roots.volume / ".ssh").iterdir()) == []


@_needs_linux()
def test_state_link_replaces_a_home_link_to_the_volume_path_spelled_otherwise(
    tmp_path,
):
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\n")
    (roots.volume / ".ssh").mkdir()
    (roots.home / ".ssh").symlink_to(Path("..", "state", "home", ".ssh"))
    result = roots.run()
    assert (result.returncode, result.stderr) == (0, "")
    assert roots.linked(".ssh")


@_needs_linux()
@pytest.mark.parametrize("volume_has_it", [False, True])
def test_state_link_leaves_a_home_link_to_an_existing_target_alone(
    tmp_path, volume_has_it
):
    # A link the user made, or one an image ships, to something that exists
    # stays as it is, with a warning that names its target; the volume gets
    # no empty entry for it.
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\nF .after\n")
    other = tmp_path / "elsewhere"
    other.mkdir()
    (other / "keep").write_text("", encoding="utf-8")
    (roots.home / ".ssh").symlink_to(other)
    if volume_has_it:
        (roots.volume / ".ssh").mkdir()
    result = roots.run()
    assert result.returncode == 1
    assert result.stderr == (
        f"state-link: {roots.lists}/denbox.list:1: left .ssh alone: {roots.home}/.ssh"
        f" is a link to {other}, not to {roots.volume}/.ssh\n"
    )
    assert (roots.home / ".ssh").readlink() == other
    assert [p.name for p in other.iterdir()] == ["keep"]
    assert (roots.volume / ".ssh").exists() == volume_has_it
    assert roots.linked(".after")


@_needs_linux()
def test_state_link_reads_every_image_list_and_the_environment_list(tmp_path):
    roots = _Roots(tmp_path)
    roots.image_list("d .config/denbox\n")
    roots.image_list("F .b_history\n", name="zz-layer.list")
    roots.image_list("F .ignored\n", name="not-a-list.txt")
    roots.env_list("# this environment's own\nd .cache/tool\n")
    result = roots.run()
    assert (result.returncode, result.stderr) == (0, "")
    assert roots.linked(".config/denbox")
    assert roots.linked(".b_history")
    assert roots.linked(".cache/tool")
    assert not (roots.home / ".ignored").exists()
    # The environment's list lives in the volume, reached from the home too.
    assert (roots.home / ".config/denbox/state-paths").is_file()


@_needs_linux()
def test_state_link_reads_the_image_lists_in_name_order_then_the_environment_list(
    tmp_path,
):
    # The first list to name a path makes it; a later one of another kind is
    # then skipped, naming its own file.
    roots = _Roots(tmp_path)
    roots.image_list("F .x\nd .y\n", name="b.list")
    roots.image_list("d .x\n", name="a.list")
    env_list = roots.env_list("F .y\n")
    result = roots.run()
    assert result.returncode == 1
    assert result.stderr.splitlines() == [
        f"state-link: {roots.lists}/b.list:1: skipped .x: {roots.volume}/.x"
        " is not a regular file",
        f"state-link: {env_list}:1: skipped .y: {roots.volume}/.y"
        " is not a regular file",
    ]
    assert roots.linked(".x")
    assert roots.linked(".y")


_BAD_LINES = [
    "d foo/",
    "d /abs",
    "d ../up",
    "d a/../b",
    "d a/./b",
    "d a//b",
    "d .",
    "d ..",
    "d sp ace",
    "d tab\tbed",
    "d st*r",
    "d new\rline",
    "d ",
    "d",
    "x foo",
    "D foo",
    "dfoo",
    " d foo",
    "d  foo",
    "d foo ",
]


@_needs_linux()
@pytest.mark.parametrize("line", _BAD_LINES)
@pytest.mark.parametrize("where", ["image", "environment"])
def test_state_link_skips_a_line_that_is_no_valid_entry(tmp_path, line, where):
    # B1: a path with a trailing slash once passed a check on its last
    # component and reached chown through a link; every rule holds for both
    # lists.
    roots = _Roots(tmp_path)
    text = f"F .first\n{line}\nF .last\n"
    listed = roots.image_list(text) if where == "image" else roots.env_list(text)
    (roots.home / "foo").symlink_to(tmp_path / "outside")
    result = roots.run()
    assert result.returncode == 1
    warnings = result.stderr.splitlines()
    assert len(warnings) == 1, result.stderr
    # A control character in the line shows as '?' in the log.
    shown = re.sub(r"[^ -~]", "?", line)
    assert warnings[0].startswith(f"state-link: {listed}:2: skipped '{shown}': ")
    # The lines around it still apply, and nothing went outside.
    assert roots.linked(".first")
    assert roots.linked(".last")
    assert not (tmp_path / "outside").exists()
    assert roots.volume_names() == sorted(
        [".first", ".last", *([".config"] if where == "environment" else [])]
    )


@_needs_linux()
@pytest.mark.parametrize("side", ["home", "volume"])
def test_state_link_skips_an_entry_with_a_link_on_its_way(tmp_path, side):
    # B1: nothing is made, moved or linked through a link that dev (or an
    # agent running as dev) planted on either side.
    roots = _Roots(tmp_path)
    roots.image_list("d .config/gh\nF .after\n")
    outside = tmp_path / "outside"
    outside.mkdir()
    root = roots.home if side == "home" else roots.volume
    (root / ".config").symlink_to(outside)
    result = roots.run()
    assert result.returncode == 1
    assert result.stderr.splitlines() == [
        f"state-link: {roots.lists}/denbox.list:1: skipped .config/gh: a symbolic link"
        f" or a file is on its way in {roots.home} or {roots.volume}"
    ]
    assert list(outside.iterdir()) == []
    assert roots.linked(".after")


@_needs_linux()
def test_state_link_skips_an_entry_whose_volume_path_is_a_link(tmp_path):
    roots = _Roots(tmp_path)
    roots.image_list("F .gitconfig\n")
    outside = tmp_path / "outside"
    outside.write_text("root's\n", encoding="utf-8")
    (roots.volume / ".gitconfig").symlink_to(outside)
    (roots.home / ".gitconfig").write_text("home\n", encoding="utf-8")
    result = roots.run()
    assert result.returncode == 1
    assert result.stderr == (
        f"state-link: {roots.lists}/denbox.list:1: skipped .gitconfig:"
        f" {roots.volume}/.gitconfig is a symbolic link\n"
    )
    assert (roots.home / ".gitconfig").read_text(encoding="utf-8") == "home\n"
    assert outside.read_text(encoding="utf-8") == "root's\n"


@_needs_linux()
def test_state_link_skips_an_entry_of_another_kind(tmp_path):
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\nF .zsh_history\nF .after\n")
    (roots.volume / ".ssh").write_text("", encoding="utf-8")
    (roots.home / ".zsh_history").mkdir()
    result = roots.run()
    assert result.returncode == 1
    assert result.stderr.splitlines() == [
        f"state-link: {roots.lists}/denbox.list:1: skipped .ssh:"
        f" {roots.volume}/.ssh is not a directory",
        f"state-link: {roots.lists}/denbox.list:2: skipped .zsh_history:"
        f" {roots.home}/.zsh_history is not a regular file",
    ]
    assert roots.linked(".after")


@_needs_linux()
def test_state_link_never_sets_aside_through_a_link(tmp_path):
    # B2: the set-aside directory is made fresh in the volume (mkdir fails on
    # anything there, a link included), so a planted link cannot send the
    # home's copy elsewhere.
    roots = _Roots(tmp_path)
    roots.image_list("F .zsh_history\nF .bash_history\n")
    outside = tmp_path / "outside"
    outside.mkdir()
    aside_root = roots.volume / ".denbox-set-aside"
    aside_root.mkdir()
    # A link under every name this run could take for a minute.
    now = datetime.datetime.now(datetime.UTC)
    for second in range(-5, 60):
        when = now + datetime.timedelta(seconds=second)
        (aside_root / when.strftime("%Y%m%dT%H%M%SZ")).symlink_to(outside)
    for rel in (".zsh_history", ".bash_history"):
        (roots.volume / rel).write_text("volume\n", encoding="utf-8")
        (roots.home / rel).write_text("home\n", encoding="utf-8")
    result = roots.run()
    assert result.returncode == 0, result.stderr
    assert list(outside.iterdir()) == []
    [aside] = [p for p in aside_root.iterdir() if not p.is_symlink()]
    assert aside.name.endswith(".1")
    assert (aside / ".zsh_history").read_text(encoding="utf-8") == "home\n"
    assert (aside / ".bash_history").read_text(encoding="utf-8") == "home\n"


@_needs_linux()
def test_state_link_does_not_set_aside_into_a_linked_set_aside_root(tmp_path):
    roots = _Roots(tmp_path)
    roots.image_list("F .zsh_history\n")
    outside = tmp_path / "outside"
    outside.mkdir()
    (roots.volume / ".denbox-set-aside").symlink_to(outside)
    (roots.volume / ".zsh_history").write_text("volume\n", encoding="utf-8")
    (roots.home / ".zsh_history").write_text("home\n", encoding="utf-8")
    result = roots.run()
    assert result.returncode == 1
    assert list(outside.iterdir()) == []
    assert (roots.home / ".zsh_history").read_text(encoding="utf-8") == "home\n"
    assert result.stderr.splitlines()[-1] == (
        f"state-link: {roots.lists}/denbox.list:1: skipped .zsh_history:"
        f" could not set {roots.home}/.zsh_history aside"
    )


def _unshare_root() -> list[str] | None:
    """The command that runs another as root of a new user and mount namespace.

    None where the system lets no unprivileged user make one, or this user is
    root already.
    """
    exe = shutil.which("unshare")
    if exe is None or sys.platform != "linux" or os.geteuid() == 0:
        return None
    probe = subprocess.run(
        [exe, "-rm", "true"], capture_output=True, check=False, timeout=30
    )
    return [exe, "-rm"] if probe.returncode == 0 else None


@_needs_linux()
@pytest.mark.parametrize("kind", ["fifo", "directory", "link", "unreadable"])
def test_state_link_skips_an_environment_list_that_is_no_file_of_the_users(
    tmp_path, kind
):
    # B5: a FIFO there once blocked every start; a link could make it read a
    # file of root's.
    roots = _Roots(tmp_path)
    roots.image_list("F .first\n")
    path = roots.volume / ".config" / "denbox" / "state-paths"
    path.parent.mkdir(parents=True)
    if kind == "fifo":
        os.mkfifo(path)
    elif kind == "directory":
        path.mkdir()
    elif kind == "link":
        target = tmp_path / "elsewhere"
        target.write_text("d .stolen\n", encoding="utf-8")
        path.symlink_to(target)
    else:
        if os.geteuid() == 0:
            pytest.skip("root reads every file")
        path.write_text("d .stolen\n", encoding="utf-8")
        path.chmod(0)
    result = roots.run()
    assert result.returncode == 1
    assert result.stderr == (
        f"state-link: skipped {path}: not a readable regular file of this"
        " user's, or a symbolic link is on its way\n"
    )
    assert roots.linked(".first")
    assert not (roots.home / ".stolen").exists()


@_needs_linux()
def test_state_link_skips_an_environment_list_another_user_owns(tmp_path):
    # B5: a readable list in the user's own volume that someone else owns is
    # not the user's. In a user namespace this user is root, and /etc/passwd,
    # which the real root owns, belongs to an unmapped user; bound over the
    # list, it passes every other check (root reads it).
    unshare = _unshare_root()
    if unshare is None:
        pytest.skip("needs an unprivileged user and mount namespace")
    roots = _Roots(tmp_path)
    roots.image_list("F .first\n")
    path = roots.env_list("")
    result = subprocess.run(
        [
            *unshare,
            _tool("sh"),
            "-c",
            'mount --bind /etc/passwd "$1" && exec sh "$2"',
            "sh",
            str(path),
            str(roots.script),
        ],
        env=roots.env(),
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert result.returncode == 1
    assert result.stderr == (
        f"state-link: skipped {path}: not a readable regular file of this"
        " user's, or a symbolic link is on its way\n"
    )
    assert roots.linked(".first")


@_needs_linux()
def test_state_link_skips_an_environment_list_behind_a_link(tmp_path):
    roots = _Roots(tmp_path)
    elsewhere = tmp_path / "elsewhere"
    (elsewhere / "denbox").mkdir(parents=True)
    (elsewhere / "denbox" / "state-paths").write_text("d .stolen\n", encoding="utf-8")
    (roots.volume / ".config").symlink_to(elsewhere)
    result = roots.run()
    assert result.returncode == 1
    assert "not a readable regular file" in result.stderr
    assert not (roots.home / ".stolen").exists()


@_needs_linux()
@pytest.mark.parametrize("where", ["image", "environment"])
def test_state_link_reads_a_last_line_without_a_newline(tmp_path, where):
    # B6: `while read` dropped the last line when it had no newline.
    roots = _Roots(tmp_path)
    text = "F .first\nd .last"
    _ = roots.image_list(text) if where == "image" else roots.env_list(text)
    result = roots.run()
    assert (result.returncode, result.stderr) == (0, "")
    assert roots.linked(".first")
    assert roots.linked(".last")


@_needs_linux()
@pytest.mark.parametrize(
    "bad",
    [
        "home-link",
        "home-missing",
        "home-of-root",
        "volume-missing",
        "volume-of-root",
        "no-mount-table",
    ],
)
def test_state_link_does_nothing_without_a_home_and_a_volume_of_the_users(
    tmp_path, bad
):
    # "of-root": / and /home, which root owns, stand in for a home or a
    # volume another user owns.
    if bad.endswith("-of-root") and os.geteuid() == 0:
        pytest.skip("root owns / and /home")
    roots = _Roots(tmp_path)
    roots.image_list("d .ssh\n")
    home = roots.home
    changes = {}
    if bad == "home-link":
        home = tmp_path / "home-link"
        home.symlink_to(roots.home)
    elif bad == "home-missing":
        home = tmp_path / "nohome"
    elif bad == "home-of-root":
        home = Path("/")
    elif bad == "volume-missing":
        roots.volume.rmdir()
    elif bad == "volume-of-root":
        changes["DENBOX_STATE_ROOT"] = "/"
    else:
        changes["DENBOX_STATE_MOUNTINFO"] = str(tmp_path / "no-mountinfo")
    result = roots.run(home=home, **changes)
    assert result.returncode == 1
    assert len(result.stderr.splitlines()) == 1, result.stderr
    assert "nothing is linked" in result.stderr
    assert not (roots.home / ".ssh").exists()
    assert not (roots.volume / ".ssh").exists()


def test_the_image_list_keeps_the_logins_and_histories():
    assert _image_entries() == [
        ("d", ".ssh"),
        ("F", ".gitconfig"),
        ("F", ".zsh_history"),
        ("F", ".bash_history"),
        ("d", ".config/gh"),
        ("d", ".config/rclone"),
        ("d", ".local/share/zoxide"),
        ("d", ".local/share/powershell/PSReadLine"),
        ("d", ".config/den"),
        ("d", ".config/denbox"),
    ]


@_needs_linux()
def test_the_image_list_is_valid(tmp_path):
    roots = _Roots(tmp_path)
    roots.image_list(_appended_block(_IMAGE_LIST))
    result = roots.run()
    assert (result.returncode, result.stderr) == (0, "")
    for _, rel in _image_entries():
        assert roots.linked(rel), rel


@_needs("zsh")
@pytest.mark.parametrize(
    ("euid", "same_user", "link", "by_copy"),
    [
        (1000, True, True, "off"),
        (1000, True, False, "on"),
        (1000, False, True, "on"),
        (0, True, True, "on"),
    ],
)
def test_zshenv_writes_a_linked_zsh_history_in_place(
    tmp_path, euid, same_user, link, by_copy
):
    # When zsh rewrites ~/.zsh_history (to trim it, or on fc -W), by default it
    # writes a new file beside it and renames that over the link into the
    # state volume: the history stays in the container's layer. Only the
    # container user's zsh with a linked history gives that up; elsewhere zsh
    # keeps its default.
    home = tmp_path / "home"
    home.mkdir()
    history = home / ".zsh_history"
    if link:
        history.symlink_to(tmp_path / "volume-history")
    me = _zsh_username()
    user_file = tmp_path / "container-user"
    user_file.write_text(f"{me if same_user else me + '-other'}\n", encoding="utf-8")
    library, _ = _dropin_files(tmp_path)
    block = tmp_path / "block"
    block.write_text(
        _patched(
            _appended_block("/etc/zsh/zshenv"),
            {
                "/etc/container-user": str(user_file),
                '"$EUID"': '"$FAKE_EUID"',
                "/usr/local/lib/denbox/dropins.sh": str(library),
            },
        ),
        encoding="utf-8",
    )
    # zsh reads the real /etc/zsh/zshenv even with -f: start from the default.
    probe = (
        f"setopt hist_save_by_copy; export HOME={shlex.quote(str(home))};"
        f" . {shlex.quote(str(block))};"
        " if [[ -o hist_save_by_copy ]]; then print on; else print off; fi"
    )
    result = subprocess.run(
        [_tool("zsh"), "-f", "-c", probe],
        env={"FAKE_EUID": str(euid), "PATH": SYSTEM_PATH},
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert (result.returncode, result.stderr) == (0, "")
    assert result.stdout == f"{by_copy}\n"


def test_the_image_workflow_runs_a_container_with_a_state_volume():
    steps = _workflow()["jobs"]["dev-image"]["steps"]
    step = next(s for s in steps if s.get("name") == "Check the state volume")
    run = step["run"]
    assert step.get("timeout-minutes", 0) > 0
    # Every path of the image's list, as the check names them.
    match = re.search(r"^paths='([^']*)'$", run, flags=re.MULTILINE)
    assert match, "the step names no paths"
    assert match.group(1).split() == [rel for _, rel in _image_entries()]
    assert re.search(
        r"docker run -d --init --name \S+ -v denbox-state:/state denbox", run
    )
    # zsh's history goes through a rewrite (fc -W), which a save at exit,
    # appending, never does: only the rewrite replaces the link without
    # no_hist_save_by_copy.
    assert (
        "printf '%s\\n' 'echo denbox-state-probe' 'fc -W' exit \\\n"
        "  | docker exec -i --user dev denbox-state zsh -i"
    ) in run
    assert (
        "-v denbox-state:/state denbox" in run.split("docker rm -f denbox-state", 1)[1]
    )
    # A host directory bound over ~/.ssh keeps its file.
    assert (
        'docker run --rm -v denbox-state:/state -v "$RUNNER_TEMP/ssh:/home/dev/.ssh"'
    ) in run
    assert '[ -f "$RUNNER_TEMP/ssh/id_test" ]' in run
    assert "docker run --rm -e DENBOX_STATE=0 -v denbox-state:/state denbox" in run


def test_test_helpers_see_the_whole_dockerfile():
    # The parser must reach the final stage, or the PATH test checks nothing.
    names = [name for name, _, _ in _stages()]
    assert names[0] == "system"
    assert names[-1] == "workspace"


# --- downloads -----------------------------------------------------------------

_INSTALL_TOOLS = ("bash", "awk", "install", "mktemp", "sha256sum", "tar")


def _is_operator(word: str) -> bool:
    return set(word) <= set("();<>|&")


def _curl_commands(script: str) -> list[list[str]]:
    """The arguments of each curl command in a shell script, comments left out.

    curl is a command where it starts the line or follows an operator (&&, |,
    the ( of $(...)); elsewhere it is an argument, such as apt's package name.
    """
    commands = []
    for line in re.sub(r"\\\n\s*", " ", script).splitlines():
        if line.lstrip().startswith("#") or not re.search(r"\bcurl\b", line):
            continue
        lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        words = list(lexer)
        for i, word in enumerate(words):
            if word != "curl" or (i and not _is_operator(words[i - 1])):
                continue
            args = []
            for arg in words[i + 1 :]:
                if _is_operator(arg):
                    break
                args.append(arg)
            commands.append(args)
    return commands


def _option(args: list[str], name: str) -> str | None:
    return args[args.index(name) + 1] if name in args[:-1] else None


def test_every_download_is_https_only_with_the_same_curl_options():
    # Without --proto '=https', curl -L follows a redirect to plain http: the
    # image ran the starship, uv, ty, ruff and nvm installers it got that way.
    checked = 0
    wrong = []
    for stage, _, _, _, script in _run_scripts():
        for args in _curl_commands(script):
            checked += 1
            if (
                _option(args, "--proto") != "=https"
                or "--tlsv1.2" not in args
                or _option(args, "--retry") != "3"
                or not any(
                    re.fullmatch(r"-[A-Za-z]+", arg) and set("fsSL") <= set(arg)
                    for arg in args
                )
                or any("://" in arg and not arg.startswith("https://") for arg in args)
            ):
                wrong.append(f"{stage}: curl {shlex.join(args)}")
    assert checked >= 15, "the scan no longer finds the image's downloads"
    assert not wrong, "\n".join(wrong)


def _apt_packages(script: str) -> list[str]:
    """What each apt-get install in a shell script installs, options left out."""
    packages = []
    for line in re.sub(r"\\\n\s*", " ", script).splitlines():
        if line.lstrip().startswith("#") or "apt-get install" not in line:
            continue
        lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        words = list(lexer)
        for i, word in enumerate(words[:-1]):
            if word != "apt-get" or words[i + 1] != "install":
                continue
            for arg in words[i + 2 :]:
                if _is_operator(arg):
                    break
                if not arg.startswith("-"):
                    packages.append(arg)
    return packages


def test_fzf_is_not_an_apt_package():
    # Ubuntu's fzf trails fzf's releases; the tools stage installs fzf's own.
    for stage, _, _, _, script in _run_scripts():
        assert "fzf" not in _apt_packages(script), stage


def test_rsync_is_ubuntus_package():
    # Ubuntu's rsync gets rsync's security fixes as package updates, which the
    # workspace stage's apt-get upgrade brings in. The image built the release
    # RSYNC_VERSION named from source instead, with a check of its own.
    scripts = _run_scripts()
    assert any("rsync" in _apt_packages(script) for *_, script in scripts)
    for stage, _, _, args, script in scripts:
        assert "RSYNC_VERSION" not in args, stage
        for curl in _curl_commands(script):
            assert not any("rsync" in arg for arg in curl), f"{stage}: {curl}"


def _tar_gz(members: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o755
            tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def _zip(members: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, data in members.items():
            info = zipfile.ZipInfo(name)
            info.external_attr = 0o755 << 16
            archive.writestr(info, data)
    return buffer.getvalue()


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _fake_program(output: str) -> bytes:
    return f"#!/bin/sh\necho {shlex.quote(output)}\n".encode()


# curl that serves https://HOST/PATH from $FAKE_WEB/HOST/PATH. It refuses a
# call without --proto =https and --tlsv1.2.
_CURL_STUB = """\
printf 'curl %s\\n' "$*" >> "$CALLS_LOG"
url='' out='' proto='' tls=''
while [ "$#" -gt 0 ]; do
    case $1 in
        --proto) proto=$2; shift ;;
        --tlsv1.2) tls=1 ;;
        --retry) shift ;;
        -o) out=$2; shift ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
if [ "$proto" != =https ] || [ "$tls" != 1 ]; then
    echo "curl stub: insecure call" >&2
    exit 2
fi
case $url in https://*) ;; *) echo "curl stub: $url" >&2; exit 2 ;; esac
file=$FAKE_WEB/${url#https://}
[ -f "$file" ] || { echo "curl: (22) HTTP 404: $url" >&2; exit 22; }
if [ -n "$out" ]; then cp "$file" "$out"; else cat "$file"; fi
"""
# The commands an install step runs after its download check: they only log
# their arguments, gh and pwsh print a version, and dpkg the target
# architecture.
_BUILD_STUBS = {
    "apt-get": "",
    "apt-mark": "",
    "dpkg": 'echo "$TARGETARCH"',
    "gh": "echo 'gh version 9.9.1'",
    "pwsh": "echo 'PowerShell 7.9.1'",
}


def _run_install(
    tmp_path: Path,
    marker: str,
    web: dict[str, bytes],
    *,
    arch: str = "amd64",
    env: dict[str, str] | None = None,
    paths: dict[str, str] | None = None,
    stubs: dict[str, str] | None = None,
) -> tuple[subprocess.CompletedProcess[str], str, Path]:
    """Run the RUN <<'marker' step against a fake web of ``web`` (URL -> body).

    It runs with the step's build args and ENV, as the Dockerfile's SHELL
    (bash -euo pipefail -c) does, but with HOME and TMPDIR in tmp_path and the
    stubs first on PATH; ``stubs`` adds more (name -> script after the line
    that logs the call). The apt lists it deletes are a directory in
    tmp_path, and ``paths`` replaces other paths in the step (old -> new).
    Returns the result, the call log and HOME.
    """
    bash = _tool("bash")
    _, step_env, body = _install_step(marker)
    apt_lists = tmp_path / "apt-lists"
    apt_lists.mkdir()
    if "/var/lib/apt/lists" in body:
        body = _patched(body, {"rm -rf /var/lib/apt/lists/*": f"rm -rf {apt_lists}/*"})
    body = _patched(body, paths or {})
    assert "/var/" not in body and "/etc/" not in body, (
        "the step writes outside tmp_path"
    )
    root = tmp_path / "web"
    for url, data in web.items():
        path = root / url.removeprefix("https://")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    stub_dir = tmp_path / "stubs"
    stub_dir.mkdir()
    log = tmp_path / "calls.log"
    log.touch()
    for name, stub in {"curl": _CURL_STUB, **_BUILD_STUBS, **(stubs or {})}.items():
        path = stub_dir / name
        path.write_text(
            f'#!{bash}\nprintf "{name} %s\\n" "$*" >> "$CALLS_LOG"\n{stub}\n'
            if name != "curl"
            else f"#!{bash}\n{stub}",
            encoding="utf-8",
        )
        path.chmod(0o755)
    home = tmp_path / "home"
    (home / ".local" / "bin").mkdir(parents=True)
    scratch = tmp_path / "tmp"
    scratch.mkdir()
    run_env = {
        **step_env,
        "HOME": str(home),
        "PATH": f"{stub_dir}:{SYSTEM_PATH}",
        "TMPDIR": str(scratch),
        "TARGETARCH": arch,
        "FAKE_WEB": str(root),
        "CALLS_LOG": str(log),
        **(env or {}),
    }
    result = subprocess.run(
        [bash, "-euo", "pipefail", "-c", body],
        env=run_env,
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    assert not any(scratch.iterdir()), "the step left its work directory behind"
    return result, log.read_text(encoding="utf-8"), home


# fzf

_FZF = "https://github.com/junegunn/fzf/releases"


def _fzf_web(*, served_arch: str = "", listed: bool = True) -> dict[str, bytes]:
    """fzf 0.99.1 for amd64 and arm64, with its checksums file.

    ``served_arch`` serves that architecture's archive with other contents
    than the checksums file lists; ``listed=False`` lists no amd64 archive.
    """
    web = {}
    sums = []
    for arch in ("amd64", "arm64"):
        name = f"fzf-0.99.1-linux_{arch}.tar.gz"
        archive = _tar_gz({"fzf": _fake_program(f"0.99.1 linux_{arch}")})
        if listed or arch != "amd64":
            sums.append(f"{_sha256(archive)}  {name}\n")
        if arch == served_arch:
            archive = _tar_gz({"fzf": _fake_program("0.99.1 tampered")})
        web[f"{_FZF}/download/v0.99.1/{name}"] = archive
    web[f"{_FZF}/download/v0.99.1/fzf_0.99.1_checksums.txt"] = "".join(sums).encode()
    return web


# The release the fake web serves, in place of the one the Dockerfile pins.
_FZF_RELEASE = {"FZF_VERSION": "0.99.1"}


@_needs(*_INSTALL_TOOLS)
@pytest.mark.parametrize("arch", ["amd64", "arm64"])
def test_fzf_comes_from_its_release_into_the_user_bin(tmp_path, arch):
    result, calls, home = _run_install(
        tmp_path, "INSTALL_FZF", _fzf_web(), env=_FZF_RELEASE, arch=arch
    )
    assert result.returncode == 0, result.stderr
    fzf = home / ".local" / "bin" / "fzf"
    assert f"0.99.1 linux_{arch}" in fzf.read_text(encoding="utf-8")
    assert f"{_FZF}/download/v0.99.1/fzf-0.99.1-linux_{arch}.tar.gz" in calls


@_needs(*_INSTALL_TOOLS)
@pytest.mark.parametrize(
    "web",
    [_fzf_web(served_arch="amd64"), _fzf_web(listed=False)],
    ids=["other-contents", "not-listed"],
)
def test_fzf_that_its_checksums_do_not_vouch_for_is_not_installed(tmp_path, web):
    result, _, home = _run_install(tmp_path, "INSTALL_FZF", web, env=_FZF_RELEASE)
    assert result.returncode != 0
    assert not (home / ".local" / "bin" / "fzf").exists()


# PowerShell

_PWSH = "https://github.com/PowerShell/PowerShell/releases"


def _pwsh_web(*, served_arch: str = "", listed: bool = True) -> dict[str, bytes]:
    """PowerShell 7.9.1 packages, with hashes.sha256 as the release writes it.

    That file is UTF-16 with a byte order mark and CRLF line ends. The
    arguments work as _fzf_web's do.
    """
    web = {}
    # Lines for other release files, as the real file has.
    others = (
        "powershell-lts_7.9.1-1.deb_amd64.deb",
        "powershell-7.9.1-linux-x64.tar.gz",
    )
    lines = [f"{_sha256(name.encode())} *{name}" for name in others]
    for arch in ("amd64", "arm64"):
        name = f"powershell_7.9.1-1.deb_{arch}.deb"
        package = f"package for {arch}".encode()
        if listed or arch != "amd64":
            lines.append(f"{_sha256(package)} *{name}")
        if arch == served_arch:
            package = b"tampered package"
        web[f"{_PWSH}/download/v7.9.1/{name}"] = package
    hashes = "".join(f"{line}\r\n" for line in lines).encode("utf-16")
    web[f"{_PWSH}/download/v7.9.1/hashes.sha256"] = hashes
    return web


_PWSH_RELEASE = {"PWSH_VERSION": "7.9.1"}


def test_powershell_is_installed_by_root():
    # A system package for every user; apt-get needs root.
    user, env, _ = _install_step("INSTALL_PWSH")
    assert user == "root"
    assert env["PATH"] == SYSTEM_PATH


@_needs(*_INSTALL_TOOLS, "iconv", "tr")
@pytest.mark.parametrize("arch", ["amd64", "arm64"])
def test_powershell_comes_from_its_release_as_a_package(tmp_path, arch):
    result, calls, _ = _run_install(
        tmp_path, "INSTALL_PWSH", _pwsh_web(), env=_PWSH_RELEASE, arch=arch
    )
    assert result.returncode == 0, result.stderr
    installs = [
        line for line in calls.splitlines() if line.startswith("apt-get install")
    ]
    assert len(installs) == 1, calls
    assert installs[0].endswith(f"/powershell_7.9.1-1.deb_{arch}.deb"), calls


@_needs(*_INSTALL_TOOLS, "iconv", "tr")
@pytest.mark.parametrize(
    "web",
    [_pwsh_web(served_arch="amd64"), _pwsh_web(listed=False)],
    ids=["other-contents", "not-listed"],
)
def test_powershell_that_its_hashes_do_not_vouch_for_is_not_installed(tmp_path, web):
    result, calls, _ = _run_install(tmp_path, "INSTALL_PWSH", web, env=_PWSH_RELEASE)
    assert result.returncode != 0
    assert "apt-get" not in calls


def test_powershell_telemetry_and_update_check_are_off_in_the_image_env():
    # Every docker exec, root's included, starts with the image's ENV, and
    # the build's own pwsh runs (its --version check, den's shell setup)
    # start with the ENV of their step.
    image_env = _stages()[-1][1]
    for name, value in PWSH_ENV.items():
        assert image_env.get(name) == value, name
    steps = _run_scripts()
    pwsh = next(
        i
        for i, (*_, script) in enumerate(steps)
        if script.startswith("<<'INSTALL_PWSH'")
    )
    for stage, _, env, _, _ in steps[pwsh:]:
        for name, value in PWSH_ENV.items():
            assert env.get(name) == value, (stage, name)


# gh

_GH = "https://github.com/cli/cli/releases"
_GH_RELEASE = {"GH_VERSION": "9.9.1"}


def _gh_web(*, served_arch: str = "", listed: bool = True) -> dict[str, bytes]:
    """gh 9.9.1 packages, with the release's checksums file.

    The arguments work as _fzf_web's do.
    """
    web = {}
    sums = [f"{_sha256(b'gh tarball')}  gh_9.9.1_linux_amd64.tar.gz\n"]
    for arch in ("amd64", "arm64"):
        name = f"gh_9.9.1_linux_{arch}.deb"
        package = f"gh package for {arch}".encode()
        if listed or arch != "amd64":
            sums.append(f"{_sha256(package)}  {name}\n")
        if arch == served_arch:
            package = b"tampered package"
        web[f"{_GH}/download/v9.9.1/{name}"] = package
    web[f"{_GH}/download/v9.9.1/gh_9.9.1_checksums.txt"] = "".join(sums).encode()
    return web


def test_gh_is_installed_by_root():
    # A system package for every user; apt-get needs root.
    user, env, _ = _install_step("INSTALL_GH")
    assert user == "root"
    assert env["PATH"] == SYSTEM_PATH


@_needs(*_INSTALL_TOOLS)
@pytest.mark.parametrize("arch", ["amd64", "arm64"])
def test_gh_comes_from_its_release_as_a_package(tmp_path, arch):
    # GitHub's apt repository lists only its newest gh, so `apt-get install
    # gh=<pinned>` failed once a newer gh was out.
    result, calls, _ = _run_install(
        tmp_path, "INSTALL_GH", _gh_web(), env=_GH_RELEASE, arch=arch
    )
    assert result.returncode == 0, result.stderr
    installs = [
        line for line in calls.splitlines() if line.startswith("apt-get install")
    ]
    assert len(installs) == 1, calls
    assert installs[0].endswith(f"/gh_9.9.1_linux_{arch}.deb"), calls


@_needs(*_INSTALL_TOOLS)
@pytest.mark.parametrize(
    "web",
    [_gh_web(served_arch="amd64"), _gh_web(listed=False)],
    ids=["other-contents", "not-listed"],
)
def test_gh_that_its_checksums_do_not_vouch_for_is_not_installed(tmp_path, web):
    result, calls, _ = _run_install(tmp_path, "INSTALL_GH", web, env=_GH_RELEASE)
    assert result.returncode != 0
    assert "apt-get" not in calls


def test_no_step_adds_githubs_apt_repository_or_holds_a_package():
    # Its index lists only the newest gh, so it cannot serve a pinned one, and
    # with no package from it there is nothing for apt-mark hold to keep.
    for stage, _, _, _, script in _run_scripts():
        assert "cli.github.com" not in script, stage
        assert "apt-mark" not in script, stage


# rclone

_RCLONE = "https://downloads.rclone.org"


def _fake_rclone(output: str) -> bytes:
    """A program that prints ``output``, or fails as rclone does on RCLONE_VERSION.

    rclone reads every RCLONE_<FLAG> environment variable as that flag's value,
    so the RCLONE_VERSION build arg, in the environment of the build steps, is
    its --version flag: the image build failed on RCLONE_VERSION=current.
    """
    return (
        "#!/bin/sh\n"
        'if [ -n "${RCLONE_VERSION+set}" ]; then\n'
        "    echo 'CRITICAL: Invalid value when setting --version from"
        " environment variable RCLONE_VERSION' >&2\n"
        "    exit 1\n"
        "fi\n"
        f"echo {shlex.quote(output)}\n"
    ).encode()


def _rclone_web(*, served_arch: str = "", listed: bool = True) -> dict[str, bytes]:
    """rclone v1.99.1, with its PGP-signed SHA256SUMS.

    The archives are also served under their rclone-current names, which the
    download used before it was checked. The arguments work as _fzf_web's do.
    """
    web = {}
    sums = ["-----BEGIN PGP SIGNED MESSAGE-----\n", "Hash: SHA1\n", "\n"]
    for arch in ("amd64", "arm64"):
        name = f"rclone-v1.99.1-linux-{arch}.zip"
        archive = _zip(
            {
                f"rclone-v1.99.1-linux-{arch}/rclone": _fake_rclone(
                    f"rclone linux-{arch}"
                )
            }
        )
        if listed or arch != "amd64":
            sums.append(f"{_sha256(archive)}  {name}\n")
        if arch == served_arch:
            archive = _zip(
                {f"rclone-v1.99.1-linux-{arch}/rclone": _fake_rclone("rclone tampered")}
            )
        web[f"{_RCLONE}/v1.99.1/{name}"] = archive
        web[f"{_RCLONE}/rclone-current-linux-{arch}.zip"] = archive
    sums += ["-----BEGIN PGP SIGNATURE-----\n", "\n", "c2lnbmF0dXJl\n"]
    sums.append("-----END PGP SIGNATURE-----\n")
    web[f"{_RCLONE}/v1.99.1/SHA256SUMS"] = "".join(sums).encode()
    return web


_RCLONE_RELEASE = {"RCLONE_VERSION": "v1.99.1"}


@_needs(*_INSTALL_TOOLS, "unzip")
@pytest.mark.parametrize("arch", ["amd64", "arm64"])
def test_rclone_comes_from_its_release_folder(tmp_path, arch):
    result, calls, home = _run_install(
        tmp_path, "INSTALL_RCLONE", _rclone_web(), env=_RCLONE_RELEASE, arch=arch
    )
    assert result.returncode == 0, result.stderr
    rclone = home / ".local" / "bin" / "rclone"
    assert f"rclone linux-{arch}" in rclone.read_text(encoding="utf-8")
    assert f"{_RCLONE}/v1.99.1/rclone-v1.99.1-linux-{arch}.zip" in calls
    # The step runs the installed rclone, with the build arg in its environment.
    assert f"rclone linux-{arch}" in result.stdout


@_needs(*_INSTALL_TOOLS, "unzip")
@pytest.mark.parametrize(
    "web",
    [_rclone_web(served_arch="amd64"), _rclone_web(listed=False)],
    ids=["other-contents", "not-listed"],
)
def test_rclone_that_its_sha256sums_do_not_vouch_for_is_not_installed(tmp_path, web):
    # Before the check, the image installed whatever the download gave.
    result, _, home = _run_install(tmp_path, "INSTALL_RCLONE", web, env=_RCLONE_RELEASE)
    assert result.returncode != 0
    assert not (home / ".local" / "bin" / "rclone").exists()


# apt


def test_the_last_stage_upgrades_apt_packages_before_it_changes_their_conffiles():
    # A refresh build (--no-cache-filter workspace) redoes only the last stage,
    # so the upgrade there brings the updates for every stage's packages. An
    # upgrade after the image appends to zshenv, bash.bashrc and zshrc (bash
    # and zsh conffiles) would stop at dpkg's question about keeping them.
    last = _stages()[-1][0]
    scripts = [
        (user, script) for stage, user, _, _, script in _run_scripts() if stage == last
    ]
    upgrades = [
        i
        for i, (user, script) in enumerate(scripts)
        if re.search(r"apt-get update && .*apt-get upgrade -y", script)
    ]
    assert len(upgrades) == 1, (
        "the last stage runs no apt-get update && apt-get upgrade -y"
    )
    user, script = scripts[upgrades[0]]
    assert user == "root"
    assert "DEBIAN_FRONTEND=noninteractive apt-get upgrade" in script
    appends = [
        i
        for i, (_, script) in enumerate(scripts)
        if re.search(r"cat >> /etc/(zsh/zshenv|bash\.bashrc|zsh/zshrc)\b", script)
    ]
    assert appends, "the parser no longer sees the startup files"
    assert upgrades[0] < min(appends)


# --- versions ------------------------------------------------------------------

# Renovate's customManagers:dockerfileVersions preset (renovate.json extends
# it): its regex, as https://docs.renovatebot.com/presets-customManagers/
# gives it, with Python's spelling of named groups. A comment it does not
# match is a version Renovate never updates.
_RENOVATE_DOCKERFILE_VERSIONS = re.compile(
    (
        r"# renovate: datasource=(?<datasource>[a-zA-Z0-9-._]+?)"
        r" depName=(?<depName>[^\s]+?)"
        r"(?: (lookupName|packageName)=(?<packageName>[^\s]+?))?"
        r"(?: versioning=(?<versioning>[^\s]+?))?"
        r"(?: extractVersion=(?<extractVersion>[^\s]+?))?"
        r"(?: registryUrl=(?<registryUrl>[^\s]+?))?"
        r"\s(?:ENV|ARG)\s+[A-Za-z0-9_]+?_VERSION[ =][\"']?(?<currentValue>.+?)[\"']?\s"
    ).replace("(?<", "(?P<")
)
# The datasources whose releases carry a publish date on the registries the
# image uses (https://docs.renovatebot.com/key-concepts/minimum-release-age/;
# npm's is the registry's `time` field, https://docs.renovatebot.com/modules/
# datasource/npm/). renovate.json's minimumReleaseAge requires one: without
# it, Renovate holds an update for good.
_DATED_DATASOURCES = {
    "crate",
    "github-releases",
    "github-tags",
    "node-version",
    "npm",
    "rust-version",
}
_EXACT_VERSION = re.compile(r"v?\d+\.\d+\.\d+")


def _version_args() -> dict[str, str]:
    """Each ARG *_VERSION in the Dockerfile and its default."""
    found = {}
    for line in _text().splitlines():
        match = re.fullmatch(r"ARG (\w+_VERSION)(?:=(\S*))?", line.strip())
        if match:
            assert match.group(1) not in found, f"{match.group(1)} is declared twice"
            found[match.group(1)] = match.group(2) or ""
    return found


def _renovate_deps() -> dict[str, dict[str, str | None]]:
    """What the preset reads from the Dockerfile, by build arg name."""
    deps = {}
    for match in _RENOVATE_DOCKERFILE_VERSIONS.finditer(_text()):
        name = re.search(r"(?:ENV|ARG)\s+(\w+?_VERSION)", match.group(0))
        assert name
        deps[name.group(1)] = match.groupdict()
    return deps


def test_every_version_build_arg_is_an_exact_release():
    # latest and current took whatever was newest on the day of the build.
    args = _version_args()
    assert len(args) > 20, "the scan no longer finds the version build args"
    for name, value in args.items():
        assert _EXACT_VERSION.fullmatch(value), f"{name}={value}"


def test_renovate_reads_every_version_build_arg_from_the_comment_above_it():
    # The preset's regex allows one whitespace character between the comment
    # and the ARG: a version whose comment is missing, misspelt or not on the
    # line right above it stays where it is.
    args = _version_args()
    deps = _renovate_deps()
    assert set(deps) == set(args), set(args) ^ set(deps)
    for name, dep in deps.items():
        assert dep["currentValue"] == args[name], name
        assert dep["datasource"] in _DATED_DATASOURCES, (name, dep["datasource"])
        assert dep["depName"], name


def test_the_base_image_and_the_syntax_image_are_pinned_by_digest():
    # A tag alone is whatever its registry serves today.
    lines = _text().splitlines()
    assert re.fullmatch(
        r"# syntax=docker/dockerfile:\d+\.\d+\.\d+@sha256:[0-9a-f]{64}", lines[0]
    ), lines[0]
    base = [line for line in lines if line.startswith("ARG BASE_IMAGE=")]
    assert len(base) == 1, base
    assert re.fullmatch(r"ARG BASE_IMAGE=ubuntu:\d+\.\d+@sha256:[0-9a-f]{64}", base[0])
    stages: list[str] = []
    for keyword, rest in _instructions():
        if keyword == "FROM":
            image, *alias = rest.split()
            assert image in {"${BASE_IMAGE}", "scratch", *stages}, rest
            stages += alias[-1:]
    assert _instructions()[0] == ("ARG", base[0].removeprefix("ARG "))


def test_every_version_build_arg_reaches_a_build_step():
    # A pin no step reads leaves its tool at whatever the step fetches.
    scripts = _run_scripts()
    for name in _version_args():
        assert any(
            name in args and re.search(rf"\$\{{?{name}\b", script)
            for _, _, _, args, script in scripts
        ), name


def test_every_download_url_is_built_from_a_version():
    # releases/latest, version.txt, sh.rustup.rs and the unversioned
    # installers each served whatever was newest on the day of the build.
    for stage, _, _, _, script in _run_scripts():
        for args in _curl_commands(script):
            assert not any(re.fullmatch(r"-\w*I\w*", arg) for arg in args), args
            urls = [arg for arg in args if "://" in arg or arg.startswith("$")]
            assert urls, f"{stage}: curl {shlex.join(args)}"
            for url in urls:
                assert "$" in url, f"{stage}: {url}"


# Rust

_RUSTUP = "https://static.rust-lang.org/rustup/archive"
_TRIPLES = {"amd64": "x86_64-unknown-linux-gnu", "arm64": "aarch64-unknown-linux-gnu"}
_RUST_RELEASE = {"RUSTUP_VERSION": "9.9.1", "RUST_VERSION": "1.999.0"}


def _rustup_web(*, served_arch: str = "", listed: bool = True) -> dict[str, bytes]:
    """rustup-init 9.9.1 for both architectures, each with its .sha256 file.

    The fake rustup-init logs its arguments. The arguments work as _fzf_web's
    do; ``listed=False`` gives amd64 a .sha256 file for another file.
    """
    web = {}
    for arch, triple in _TRIPLES.items():
        program = (
            f'#!/bin/sh\nprintf \'rustup-init {arch} %s\\n\' "$*" >> "$CALLS_LOG"\n'
        ).encode()
        name = "./rustup-init" if listed or arch != "amd64" else "./rustup-init.exe"
        web[f"{_RUSTUP}/9.9.1/{triple}/rustup-init.sha256"] = (
            f"{_sha256(program)} *{name}\n".encode()
        )
        if arch == served_arch:
            program += b"# tampered\n"
        web[f"{_RUSTUP}/9.9.1/{triple}/rustup-init"] = program
    return web


@_needs(*_INSTALL_TOOLS)
@pytest.mark.parametrize("arch", ["amd64", "arm64"])
def test_rustup_installs_the_pinned_rust_release(tmp_path, arch):
    result, calls, _ = _run_install(
        tmp_path, "INSTALL_RUST", _rustup_web(), env=_RUST_RELEASE, arch=arch
    )
    assert result.returncode == 0, result.stderr
    runs = [line for line in calls.splitlines() if line.startswith("rustup-init")]
    assert runs == [
        f"rustup-init {arch} -y --no-modify-path --profile minimal"
        " --default-toolchain 1.999.0 --component rustfmt,clippy"
    ], calls


@_needs(*_INSTALL_TOOLS)
@pytest.mark.parametrize(
    "web",
    [_rustup_web(served_arch="amd64"), _rustup_web(listed=False)],
    ids=["other-contents", "not-listed"],
)
def test_rustup_init_that_its_sha256_does_not_vouch_for_is_not_run(tmp_path, web):
    result, calls, _ = _run_install(tmp_path, "INSTALL_RUST", web, env=_RUST_RELEASE)
    assert result.returncode != 0
    assert "rustup-init" not in "".join(
        line for line in calls.splitlines() if not line.startswith("curl")
    )


# cargo

# A cargo that logs the parallel job limit it got and its arguments.
_CARGO_STUB = 'echo "CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS-unset}" >> "$CALLS_LOG"'


def _run_cargo_step(
    tmp_path: Path, marker: str, build_jobs: str
) -> tuple[subprocess.CompletedProcess[str], str]:
    """Run a cargo step with BUILD_JOBS, cargo, yazi and ya as stubs.

    yazi-build's leftovers it deletes from /tmp are a directory in tmp_path.
    """
    result, calls, _ = _run_install(
        tmp_path,
        marker,
        {},
        env={"BUILD_JOBS": build_jobs},
        paths=(
            {"rm -rf /tmp/yazi-build-": f"rm -rf {tmp_path}/yazi-build-"}
            if marker == "INSTALL_YAZI"
            else {}
        ),
        stubs={"cargo": _CARGO_STUB, "yazi": "", "ya": ""},
    )
    return result, calls


def _cargo_calls(calls: str) -> list[tuple[str, list[str]]]:
    """(CARGO_BUILD_JOBS, arguments) per cargo call in a call log."""
    lines = calls.splitlines()
    return [
        (lines[i + 1].partition("=")[2], line.split()[1:])
        for i, line in enumerate(lines)
        if line.startswith("cargo ")
    ]


@_needs("bash")
@pytest.mark.parametrize("marker", ["INSTALL_CRATES", "INSTALL_YAZI"])
@pytest.mark.parametrize(("build_jobs", "limit"), [("", "unset"), ("3", "3")])
def test_build_jobs_reaches_every_cargo_build(tmp_path, marker, build_jobs, limit):
    # Empty leaves cargo's own default (one job per logical CPU).
    result, calls = _run_cargo_step(tmp_path, marker, build_jobs)
    assert result.returncode == 0, result.stderr
    cargo = _cargo_calls(calls)
    assert len(cargo) == 1, calls
    assert cargo[0][0] == limit


@_needs("bash")
@pytest.mark.parametrize("marker", ["INSTALL_CRATES", "INSTALL_YAZI"])
@pytest.mark.parametrize("build_jobs", ["0", "-1", "four"])
def test_a_build_jobs_that_is_no_positive_number_stops_the_build(
    tmp_path, marker, build_jobs
):
    result, calls = _run_cargo_step(tmp_path, marker, build_jobs)
    assert result.returncode != 0
    assert "BUILD_JOBS" in result.stderr
    assert not _cargo_calls(calls)


@_needs("bash")
def test_cargo_installs_each_crate_at_the_release_its_comment_names(tmp_path):
    # cargo install takes name@1.2.3 as exactly that release; Renovate updates
    # the build arg under the crate its comment names.
    crates = {
        dep["depName"]: name
        for name, dep in _renovate_deps().items()
        if dep["datasource"] == "crate"
    }
    assert len(crates) > 10, crates
    installed: list[str] = []
    for marker in ("INSTALL_CRATES", "INSTALL_YAZI"):
        step_dir = tmp_path / marker
        step_dir.mkdir()
        result, calls = _run_cargo_step(step_dir, marker, "")
        assert result.returncode == 0, result.stderr
        (_, args), *_ = _cargo_calls(calls)
        assert args[:2] == ["install", "--locked"], args
        installed += args[2:]
    args = _version_args()
    assert sorted(installed) == sorted(
        f"{crate}@{args[name]}" for crate, name in crates.items()
    )


# Node.js and npm


def test_node_is_a_release_of_the_26_lts_line():
    # The image follows the Node.js line of the owner's own environment, 26
    # (Lithium, LTS since 2026-10-28). Renovate proposes its releases; a pull
    # request that moves the image to another line changes this test too.
    node = _renovate_deps()["NODE_VERSION"]
    assert (node["datasource"], node["depName"], node["versioning"]) == (
        "node-version",
        "node",
        "node",
    )
    assert node["currentValue"].split(".")[0] == "26", node["currentValue"]


def test_npm_is_pinned_to_a_release_of_the_npm_package():
    # npm's bundled dependencies get their fixes with npm releases, which the
    # npm that comes with Node.js trails. The version tests above check that
    # the pin is an exact release under a comment Renovate reads.
    npm = _renovate_deps()["NPM_VERSION"]
    assert (npm["datasource"], npm["depName"]) == ("npm", "npm")


def test_npm_is_installed_right_after_node_for_the_user():
    # The npm that dev's tool PATH finds first replaces the one nvm installed
    # with Node.js.
    scripts = _run_scripts()
    node = [i for i, (*_, script) in enumerate(scripts) if "nvm install" in script]
    assert len(node) == 1, node
    node_stage, node_user, *_ = scripts[node[0]]
    stage, user, env, _, script = scripts[node[0] + 1]
    assert script.startswith("<<'INSTALL_NPM'"), script
    assert (stage, user) == (node_stage, node_user)
    assert env["PATH"].split(":")[0] == f"{env['NVM_DIR']}/current/bin"


# An npm that reports $FAKE_NPM_VERSION as the release on PATH after the step
# installed one (_run_install logs every call).
_NPM_STUB = 'if [ "$1" = --version ]; then echo "$FAKE_NPM_VERSION"; fi'
# The release the step installs, in place of the one the Dockerfile pins.
_NPM_RELEASE = {"NPM_VERSION": "99.1.2"}


def _run_npm_step(
    tmp_path: Path, env: dict[str, str]
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    """Run the npm step with npm as a stub; returns the result and npm's calls."""
    result, calls, _ = _run_install(
        tmp_path, "INSTALL_NPM", {}, env=env, stubs={"npm": _NPM_STUB}
    )
    return result, [line for line in calls.splitlines() if line.startswith("npm ")]


@_needs("bash")
def test_npm_installs_the_pinned_release_globally(tmp_path):
    result, calls = _run_npm_step(
        tmp_path, {**_NPM_RELEASE, "FAKE_NPM_VERSION": "99.1.2"}
    )
    assert result.returncode == 0, result.stderr
    assert calls[0] == "npm install -g --no-audit --no-fund npm@99.1.2"
    assert "npm --version" in calls


@_needs("bash")
def test_a_build_whose_npm_on_path_is_another_release_fails(tmp_path):
    # The install went elsewhere, or did not replace the npm Node.js brought.
    result, _ = _run_npm_step(tmp_path, {**_NPM_RELEASE, "FAKE_NPM_VERSION": "11.20.0"})
    assert result.returncode != 0
    assert "11.20.0, not 99.1.2" in result.stderr


@_needs("bash")
@pytest.mark.parametrize("version", ["latest", "12", "^12.2.1", "12.2.1 --force"])
def test_an_npm_version_that_is_no_exact_release_stops_the_build(tmp_path, version):
    result, calls = _run_npm_step(
        tmp_path, {"NPM_VERSION": version, "FAKE_NPM_VERSION": version}
    )
    assert result.returncode != 0
    assert "Unexpected npm version" in result.stderr
    assert not calls


# apt

_NO_PIPELINING = 'Acquire::http::Pipeline-Depth "0";\n'


@_needs("bash")
@pytest.mark.parametrize(
    ("setting", "conf"), [("1", None), ("0", _NO_PIPELINING)], ids=["on", "off"]
)
def test_apt_http_pipelining_is_turned_off_only_on_request(tmp_path, setting, conf):
    # On some networks apt-get update fails with "Hash Sum mismatch" while the
    # same files download intact without pipelining.
    conf_dir = tmp_path / "apt.conf.d"
    conf_dir.mkdir()
    result, _, _ = _run_install(
        tmp_path,
        "CONFIGURE_APT",
        {},
        env={"APT_HTTP_PIPELINING": setting},
        paths={"/etc/apt/apt.conf.d/": f"{conf_dir}/"},
    )
    assert result.returncode == 0, result.stderr
    written = {
        path.name: path.read_text(encoding="utf-8") for path in conf_dir.iterdir()
    }
    assert written == ({} if conf is None else {"90-no-http-pipelining": conf})


@_needs("bash")
def test_an_apt_http_pipelining_other_than_0_or_1_stops_the_build(tmp_path):
    conf_dir = tmp_path / "apt.conf.d"
    conf_dir.mkdir()
    result, _, _ = _run_install(
        tmp_path,
        "CONFIGURE_APT",
        {},
        env={"APT_HTTP_PIPELINING": "off"},
        paths={"/etc/apt/apt.conf.d/": f"{conf_dir}/"},
    )
    assert result.returncode != 0
    assert "APT_HTTP_PIPELINING" in result.stderr
    assert not any(conf_dir.iterdir())


def test_apt_http_pipelining_is_set_before_any_apt_get():
    # Every later stage starts from the first one's files, so the setting there
    # reaches every apt-get of the build.
    scripts = _run_scripts()
    first_apt = next(i for i, (*_, script) in enumerate(scripts) if "apt-get" in script)
    configure = [
        i
        for i, (*_, script) in enumerate(scripts)
        if script.startswith("<<'CONFIGURE_APT'")
    ]
    assert configure, "no RUN <<'CONFIGURE_APT' step"
    assert configure[0] < first_apt
    stage, user, _, _, _ = scripts[configure[0]]
    assert (stage, user) == (_stages()[0][0], "root")


# --- the CI workflow that builds the image -------------------------------------


def _workflow() -> dict:
    data = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    # YAML 1.1 reads the bare key `on` as true; GitHub reads it as "on".
    data["on"] = data.pop(True)
    return data


def test_the_image_workflow_runs_when_the_image_or_the_workflow_changes():
    on = _workflow()["on"]
    own = WORKFLOW.relative_to(ROOT).as_posix()
    for event in ("push", "pull_request"):
        assert {"docker/**", own} <= set(on[event]["paths"]), event
    assert "workflow_dispatch" in on


def _gha_scopes(step: dict) -> set[str]:
    """The GitHub Actions cache scopes a build step reads or writes."""
    scopes = set()
    for key in ("cache-from", "cache-to"):
        value = step.get("with", {}).get(key, "")
        attrs = dict(part.split("=", 1) for part in value.split(",") if "=" in part)
        if attrs.get("type") == "gha":
            scopes.add(attrs.get("scope", "buildkit"))
    return scopes


def test_the_image_build_cache_has_a_scope_of_its_own():
    # Builds of two images in one gha cache scope overwrite each other's cache
    # (the default scope, buildkit, is what ci.yml's shell test image uses), so
    # the next run of either would start cold.
    steps = _workflow()["jobs"]["dev-image"]["steps"]
    build = next(step for step in steps if step.get("name") == "Build the dev image")
    scopes = _gha_scopes(build)
    assert len(scopes) == 1, scopes
    for path in sorted(WORKFLOW.parent.glob("*.yml")):
        if path == WORKFLOW:
            continue
        for job in yaml.safe_load(path.read_text(encoding="utf-8"))["jobs"].values():
            for step in job.get("steps", []):
                shared = scopes & _gha_scopes(step)
                assert not shared, f"{path.name}: {step.get('name')}"


def test_the_image_workflow_budget_covers_its_steps():
    # A job cancelled mid-build exports no layer cache, and the next run starts
    # cold again, so the job's budget covers every step's.
    job = _workflow()["jobs"]["dev-image"]
    steps = {step.get("name"): step for step in job["steps"]}
    assert steps["Build the dev image"].get("timeout-minutes", 0) > 0
    total = sum(step.get("timeout-minutes", 0) for step in job["steps"])
    assert job["timeout-minutes"] >= total


def test_the_image_workflow_runs_fzf_and_pwsh_in_the_image():
    # Both come from their releases, not from apt: the checks find fzf on
    # dev's PATH and pwsh for root and dev in the built image.
    steps = _workflow()["jobs"]["dev-image"]["steps"]
    checks = next(
        step
        for step in steps
        if step.get("name") == "Check HOME and PATH for root and dev"
    )
    assert re.search(
        r"docker exec --user dev denbox zsh -lc '[^']*\bfzf --version", checks["run"]
    )
    assert re.search(r"docker exec denbox pwsh --version\b", checks["run"])
    assert "docker exec --user dev denbox zsh -lc 'pwsh --version'" in checks["run"]


# --- image drop-ins ------------------------------------------------------------


def _hook(tmp_path: Path, kind: str, name: str, body: str) -> Path:
    directory = tmp_path / "denbox" / kind
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text(f"#!{_tool('sh')}\n{body}\n")
    path.chmod(0o755)
    return path


@_needs("sh", "env")
def test_image_hooks_run_in_order_with_arguments_and_minimal_env(tmp_path):
    log = tmp_path / "hook-log"
    for kind in ("init.d", "user-init.d"):
        for name in ("20-z", "10-a"):
            _hook(
                tmp_path, kind, name,
                f"printf '%s\\n' '{kind}/{name}' >> {shlex.quote(str(log))}\n"
                + (f"printf '%s\\n' \"$@\" >> {shlex.quote(str(log))}"
                   if kind == "init.d" else
                   '[ "$HOME" = /home/dev ] && '
                   '[ "$PATH" = /usr/sbin:/usr/bin:/sbin:/bin ] && '
                   '[ "${SECRET-unset}" = unset ]'),
            )
    result, calls = _run_entrypoint(tmp_path, uid=0, env={"SECRET": "probe"})
    assert result.returncode == 0, result.stderr
    assert log.read_text().splitlines() == [
        "init.d/10-a", "/home/dev", "1000", "1000",
        "init.d/20-z", "/home/dev", "1000", "1000",
        "user-init.d/10-a", "user-init.d/20-z",
    ]
    assert calls.count("gnutimeout -k 10 300") == 2
    assert result.stderr == ""


@_needs("sh", "env")
@pytest.mark.parametrize("kind", ["init.d", "user-init.d"])
@pytest.mark.parametrize("status", [1, 124, 137])
def test_hook_failure_stops_only_root_hooks(tmp_path, kind, status):
    hook = _hook(tmp_path, kind, "10-fail", f"exit {status}")
    result, _ = _run_entrypoint(tmp_path, uid=0, env={})
    assert (result.returncode != 0) == (kind == "init.d")
    assert str(hook) in result.stderr
    assert str(status) in result.stderr


@_needs("sh", "env")
@pytest.mark.parametrize("kind", ["init.d", "user-init.d"])
@pytest.mark.parametrize("bad", ["writable", "link", "non-root", "directory", "fifo"])
def test_untrusted_hooks_are_never_executed(tmp_path, kind, bad):
    hook = _hook(tmp_path, kind, bad, "echo unsafe")
    if bad == "writable":
        hook.chmod(0o775)
    elif bad == "link":
        target = hook.with_name("target")
        hook.rename(target)
        target.chmod(0o644)
        hook.symlink_to(target)
    elif bad in {"directory", "fifo"}:
        hook.unlink()
        if bad == "directory":
            hook.mkdir()
        else:
            os.mkfifo(hook)
    result, _ = _run_entrypoint(tmp_path, uid=0, env={})
    assert (result.returncode != 0) == (kind == "init.d")
    assert str(hook) in result.stderr
    assert "unsafe" not in result.stdout


@_needs("sh", "env")
def test_non_root_start_skips_all_hooks(tmp_path):
    for kind in ("init.d", "user-init.d"):
        _hook(tmp_path, kind, "fail", "exit 1")
    result, calls = _run_entrypoint(tmp_path, uid=1000, env={})
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert "gnutimeout" not in calls


@_needs("sh", "env")
@pytest.mark.parametrize("uid", [0, 1000])
def test_entrypoint_sources_env_as_user_after_setting_path(tmp_path, uid):
    _hook(tmp_path, "user-env.d", "10-env.sh", 'export DROPIN=first')
    _hook(tmp_path, "user-env.d", "20-env.sh", 'export DROPIN="$DROPIN:second"')
    result, _ = _run_entrypoint(tmp_path, uid=uid, env={})
    # The root branch's setpriv stub records the user wrapper's argv.
    # The non-root branch executes it; CI checks the real privilege drop.
    if uid == 0:
        assert str(tmp_path / "user-exec") in result.stdout
    else:
        assert "DROPIN=first:second" in result.stdout.splitlines()


@_needs("sh", "bash", "zsh", "id")
@pytest.mark.parametrize(
    ("shell", "target"),
    [("sh", "/etc/profile.d/00-container-home.sh"),
     ("bash", "/etc/bash.bashrc"), ("zsh", "/etc/zsh/zshenv")],
)
@pytest.mark.parametrize("root", [False, True])
def test_each_shell_sources_env_only_for_container_user(tmp_path, shell, target, root):
    _hook(tmp_path, "user-env.d", "env.sh", "export DROPIN=yes")
    me = _zsh_username() if shell == "zsh" else _login_name()
    out = _source_block(
        tmp_path, shell, target, euid=0 if root else 1000,
        home="/home/" + me, user=me, extra=("DROPIN",),
    )
    assert out[-1] == ("unset" if root else "yes")


@_needs("sh", "env")
@pytest.mark.parametrize("bad", ["writable", "link", "non-root", "unsafe-dir"])
def test_env_and_path_lists_reject_untrusted_files_or_parents(tmp_path, bad):
    library, _ = _dropin_files(tmp_path)
    for kind, name, body in (
        ("user-env.d", "bad.sh", "export DROPIN=unsafe"),
        ("user-path.d", "bad.list", "/unsafe"),
    ):
        path = tmp_path / "denbox" / kind / name
        path.write_text(body)
        if bad == "writable":
            path.chmod(0o666)
        elif bad == "link":
            target = tmp_path / name
            path.rename(target)
            path.symlink_to(target)
        elif bad == "non-root":
            metadata = tmp_path / "metadata"
            metadata.write_text(
                metadata.read_text().replace(
                    "path.endswith('non-root')",
                    "os.path.basename(path) in ('bad.sh', 'bad.list')",
                )
            )
        else:
            directory = path.parent
            unsafe = directory / "unsafe-dir"
            unsafe.mkdir(mode=0o777)
            unsafe.chmod(0o777)
            path.rename(unsafe / name)
            library.write_text(library.read_text().replace(
                str(directory) + "/*", str(unsafe) + "/*",
            ))
    result = subprocess.run(
        [_tool("sh"), "-c",
         f'. {shlex.quote(str(library))}; denbox_user_path; denbox_user_env; '
         'printf "%s\\n" "$PATH" "${DROPIN-unset}"'],
        env={"HOME": "/home/dev", "PATH": SYSTEM_PATH},
        capture_output=True, text=True, check=False, timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert "/unsafe" not in result.stdout
    assert result.stdout.splitlines()[-1] == "unset"
    assert result.stderr.count("untrusted") == 2


@_needs("sh", "env")
def test_path_lists_preserve_order_literals_and_last_line(tmp_path):
    library, _ = _dropin_files(tmp_path)
    lists = tmp_path / "denbox/user-path.d"
    (lists / "10-extra.list").write_text("# comment\n\nmy tools\n/opt/bin\n")
    (lists / "20-extra.list").write_text("/opt/bin\n/invalid:entry\n$(false)")
    result = subprocess.run(
        [_tool("sh"), "-c",
         f'. {shlex.quote(str(library))}; denbox_user_path; denbox_user_path; '
         'printf "%s\\n" "$PATH"'],
        env={"HOME": "/home/dev", "PATH": SYSTEM_PATH},
        capture_output=True, text=True, check=False, timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == (
        "/home/dev/my tools:/opt/bin:/home/dev/$(false):" + _user_path("/home/dev")
    )
    assert "invalid PATH entry" in result.stderr


def test_ci_exercises_a_derived_image_within_the_job_budget():
    steps = _workflow()["jobs"]["dev-image"]["steps"]
    step = next(step for step in steps if step.get("name") == "Check image drop-ins")
    assert step["timeout-minutes"] > 0
    assert "FROM denbox" in step["run"]
    assert "--pull" not in step["run"]
    for directory in (
        "init.d", "user-init.d", "user-env.d", "user-path.d", "state-paths.d",
    ):
        assert f"/etc/denbox/{directory}" in step["run"]


@_needs("sh", "env")
def test_hooks_surround_state_link_after_state_root_preparation(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    log = shlex.quote(str(tmp_path / "calls.log"))
    _hook(tmp_path, "init.d", "root", f"echo root-hook >> {log}")
    _hook(tmp_path, "user-init.d", "user", f"echo user-hook >> {log}")
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={}, mounts=("/workspace", str(state)),
    )
    assert result.returncode == 0, result.stderr
    prepared = calls.index(f"gnuchown -h 1000:1000 {state} {state}/home")
    root = calls.index("root-hook")
    linked = calls.index(_STATE_LINK)
    user = calls.index("user-hook")
    assert prepared < root < linked < user


@_needs("sh", "env")
def test_root_hooks_receive_final_remapped_ids(tmp_path):
    hook = _hook(tmp_path, "init.d", "ids", '[ "$1:$2:$3" = /home/dev:501:20 ]')
    result, _ = _run_entrypoint(
        tmp_path, uid=0, env={"HOST_UID": "501", "HOST_GID": "20"},
    )
    assert result.returncode == 0, result.stderr
    assert str(hook) not in result.stderr


@_needs("sh", "env")
def test_trusted_non_executable_hooks_are_ignored(tmp_path):
    for kind in ("init.d", "user-init.d"):
        _hook(tmp_path, kind, "disabled", "exit 1").chmod(0o644)
    result, _ = _run_entrypoint(tmp_path, uid=0, env={})
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""


@_needs("sh", "bash", "zsh", "id")
@pytest.mark.parametrize(
    ("shell", "target"),
    [("sh", "/etc/profile.d/00-container-home.sh"),
     ("bash", "/etc/bash.bashrc"), ("zsh", "/etc/zsh/zshenv")],
)
def test_other_shell_users_do_not_source_container_env(tmp_path, shell, target):
    _hook(tmp_path, "user-env.d", "env.sh", "export DROPIN=unsafe")
    out = _source_block(
        tmp_path, shell, target, euid=1000, home=str(tmp_path / "home"),
        user="another-user", extra=("DROPIN",),
    )
    assert out[-1] == "unset"


@_needs("sh", "env")
@pytest.mark.parametrize(
    "body", ['false && export NEVER=yes', 'export OPTIONAL="$NOT_SET"'],
)
def test_user_exec_env_files_do_not_enable_errexit_or_nounset(tmp_path, body):
    _, wrapper = _dropin_files(tmp_path)
    hook = _hook(tmp_path, "user-env.d", "10-env.sh", body)
    result = subprocess.run(
        [str(wrapper), _tool("sh"), "-c", "echo command-ran"],
        env={"HOME": "/home/dev", "PATH": SYSTEM_PATH},
        capture_output=True, text=True, check=False, timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == "command-ran\n"
    if body.startswith("false"):
        assert str(hook) in result.stderr
    else:
        assert result.stderr == ""


@_needs("sh", "bash", "zsh", "id")
@pytest.mark.parametrize(
    ("shell", "target"),
    [("sh", "/etc/profile.d/00-container-home.sh"),
     ("bash", "/etc/bash.bashrc"), ("zsh", "/etc/zsh/zshenv")],
)
def test_nested_shell_preserves_activated_path(tmp_path, shell, target):
    me = _zsh_username() if shell == "zsh" else _login_name()
    home = "/home/" + me
    inherited = f"/venv/bin:{_user_path(home)}::/duplicate:/duplicate:"
    out = _source_block(
        tmp_path, shell, target, euid=1000, home=home, user=me,
        inherited_path=inherited,
    )
    assert out[1] == inherited


@_needs("sh", "env")
def test_root_hook_pins_home_and_cwd_but_keeps_operator_settings(tmp_path):
    _hook(
        tmp_path, "init.d", "context",
        '[ "$PWD:$HOME:$SETTING" = /:/root:operator ]',
    )
    result, _ = _run_entrypoint(
        tmp_path, uid=0, env={"HOME": "/home/dev", "SETTING": "operator"},
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""


@_needs("sh", "env")
@pytest.mark.parametrize("kind", ["init.d", "user-init.d"])
@pytest.mark.parametrize("name", ["10-probe", "10-name=value"])
def test_hook_names_with_equals_run_and_stdin_is_eof(tmp_path, kind, name):
    marker = tmp_path / "ran"
    _hook(
        tmp_path, kind, name,
        f"if read -r line; then exit 9; fi\n"
        f"echo ran > {shlex.quote(str(marker))}",
    )
    result, _ = _run_entrypoint(tmp_path, uid=0, env={})
    assert result.returncode == 0, result.stderr
    assert result.stderr == ""
    assert marker.read_text() == "ran\n"


@_needs("sh", "env")
@pytest.mark.parametrize("kind", ["init.d", "user-init.d", "user-env.d"])
@pytest.mark.parametrize("bad", ["other-writable", "parent-link", "parent-owner", "hidden"])
def test_dropin_trust_boundaries(tmp_path, kind, bad):
    _, wrapper = _dropin_files(tmp_path)
    marker = tmp_path / "ran"
    name = "probe.sh" if kind == "user-env.d" else "probe"
    if bad == "hidden":
        name = "." + name
    hook = _hook(
        tmp_path, kind, name, f"echo ran > {shlex.quote(str(marker))}",
    )
    if bad == "other-writable":
        hook.chmod(0o757)
    elif bad == "parent-link":
        directory = hook.parent
        target = directory.with_name("real-" + kind)
        directory.rename(target)
        directory.symlink_to(target, target_is_directory=True)
    elif bad == "parent-owner":
        # The metadata stub models ownership without requiring chown/root.
        (hook.parent / ".non-root-owner").touch()
    if kind == "user-env.d":
        result = subprocess.run(
            [str(wrapper), _tool("env")],
            env={"HOME": "/home/dev", "PATH": SYSTEM_PATH},
            capture_output=True, text=True, check=False, timeout=30,
        )
    else:
        result, _ = _run_entrypoint(tmp_path, uid=0, env={})
    assert not marker.exists()
    assert (result.returncode != 0) == (kind == "init.d" and bad != "hidden")
    if bad == "hidden":
        assert result.stderr == ""
    else:
        assert str(hook) in result.stderr


@_needs("sh", "bash", "zsh")
@pytest.mark.parametrize("shell", ["sh", "bash", "zsh"])
def test_shell_trust_batches_candidates_in_one_process(tmp_path, shell):
    library, _ = _dropin_files(tmp_path)
    log = tmp_path / "trust-calls"
    find = tmp_path / "find"
    find.write_text(f"#!{_tool('sh')}\necho find >> {shlex.quote(str(log))}\n")
    find.chmod(0o755)
    metadata = tmp_path / "metadata"
    metadata.write_text(
        f"#!{_tool('sh')}\necho stat >> {shlex.quote(str(log))}\nexit 1\n",
    )
    for name in ("10-first.sh", "20-second.sh"):
        _hook(tmp_path, "user-env.d", name, "export DROPIN=yes")
    library.write_text(library.read_text().replace("/usr/bin/find", str(find)))
    result = subprocess.run(
        [_tool(shell), "-c",
         f". {shlex.quote(str(library))}; denbox_shell_trust; "
         'denbox_user_path; denbox_user_env; printf "%s\\n" "$DROPIN"'],
        env={"HOME": "/home/dev", "PATH": SYSTEM_PATH},
        capture_output=True, text=True, check=False, timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == "yes\n"
    assert result.stderr == ""
    assert log.read_text().splitlines() == ["find"]


def test_ci_pins_base_and_derived_paths_literally():
    steps = _workflow()["jobs"]["dev-image"]["steps"]
    base = next(
        step["run"] for step in steps
        if step.get("name") == "Check HOME and PATH for root and dev"
    )
    derived = next(
        step["run"] for step in steps if step.get("name") == "Check image drop-ins"
    )
    expected = _user_path("/home/dev")
    assert f"expected_path={expected}\n" in base
    assert f'[ "$PATH" = /opt/hook-bin:{expected} ]' in derived
