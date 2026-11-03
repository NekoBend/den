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

import hashlib
import io
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
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

    The environment is what the step runs with: its build args and the ENV,
    which wins over a build arg of the same name.
    """
    for _, user, env, args, script in _run_scripts():
        if script.startswith(f"<<'{marker}'\n"):
            return user, {**args, **env}, script.partition("\n")[2]
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
    # there (an apt-get, an ls) ran as root on the next `docker exec den-dev ...`.
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
) -> list[str]:
    """Source the block twice in ``shell``.

    Returns HOME, PATH, skip_global_compinit, HISTFILE and USER. ``histfile``
    stands in for the HISTFILE bash sets from HOME before it reads its startup
    files.
    """
    user_file = tmp_path / "container-user"
    user_file.write_text(f"{user}\n", encoding="utf-8")
    text = _appended_block(target)
    # bash and zsh blocks read $EUID; the POSIX sh profile script runs id -u.
    euid_ref = '"$(id -u)"' if '"$(id -u)"' in text else '"$EUID"'
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
        f"export HOME={shlex.quote(home)} PATH={SYSTEM_PATH}; "
        "unset skip_global_compinit HISTFILE USER LOGNAME; "
        + (f"HISTFILE={shlex.quote(histfile)}; " if histfile else "")
        + f". {shlex.quote(str(block))}; . {shlex.quote(str(block))}; "
        'printf "%s\\n" "$HOME" "$PATH" "${skip_global_compinit-unset}" '
        '"${HISTFILE-unset}" "${USER-unset}"'
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
    # A root `docker exec -it den-dev bash` kept HOME=/home/dev and so read
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
    # A root `docker exec den-dev bash -lc ...` or `sh -lc ...` is not
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
    assert out[:2] == [f"/home/{me}", SYSTEM_PATH]
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
    assert out[:2] == [home, SYSTEM_PATH]


# --- the entrypoint ------------------------------------------------------------


def _run_entrypoint(
    tmp_path: Path, *, uid: int, env: dict[str, str]
) -> tuple[subprocess.CompletedProcess[str], str]:
    """Run the entrypoint as ``uid`` with stubs; return the result and the call log.

    The account is dev, 1000:1000, home /home/dev. setpriv prints its
    arguments and the HOME it got; the commands that change accounts or files
    only log theirs.
    """
    sh = _tool("sh")
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    log = tmp_path / "calls.log"
    log.touch()

    def stub(name: str, body: str) -> None:
        path = stubs / name
        path.write_text(f"#!{sh}\n{body}\n", encoding="utf-8")
        path.chmod(0o755)

    stub("id", f'case "$1" in -u|-g) echo {uid} ;; *) exit 1 ;; esac')
    stub(
        "getent",
        'case "$1 $2" in\n'
        '  "passwd dev") echo "dev:x:1000:1000::/home/dev:/bin/zsh" ;;\n'
        '  "group "*) exit 0 ;;\n'
        "  *) exit 2 ;;\n"
        "esac",
    )
    for name in ("usermod", "groupadd", "find", "mountpoint", "gnuchown"):
        stub(name, f'echo "{name} $*" >> {shlex.quote(str(log))}')
    stub("setpriv", 'printf "%s\\n" "$@" "HOME=$HOME"')
    user_file = tmp_path / "container-user"
    user_file.write_text("dev\n", encoding="utf-8")
    system = "/usr/sbin:/usr/bin:/sbin:/bin"  # the entrypoint's own PATH
    script = tmp_path / "container-entrypoint"
    script.write_text(
        _patched(
            _entrypoint_script(),
            {
                "/etc/container-user": str(user_file),
                f"PATH={system}": f"PATH={stubs}:{system}",
                "/usr/bin/setpriv": str(stubs / "setpriv"),
                "/usr/bin/gnuchown": str(stubs / "gnuchown"),
            },
        ),
        encoding="utf-8",
    )
    result = subprocess.run(
        [sh, str(script), _tool("env")],
        env={"PATH": SYSTEM_PATH, **env},
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
def test_entrypoint_says_once_that_a_remap_copies_the_home(tmp_path):
    # A UID other than the build's re-owns all of /home/dev, which overlayfs
    # copies into each new container; the build args avoid it.
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={"HOST_UID": "501", "HOST_GID": "20"}
    )
    assert result.returncode == 0, result.stderr
    assert "usermod --uid 501 --gid 20 dev" in calls
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


def test_test_helpers_see_the_whole_dockerfile():
    # The parser must reach the final stage, or the PATH test checks nothing.
    names = [name for name, _, _ in _stages()]
    assert names[0] == "system"
    assert names[-1] == "workspace"


# --- downloads -----------------------------------------------------------------

# The agent CLI installers keep their own curl lines: the change that removes
# them from the image owns those lines.
_AGENT_INSTALLERS = {
    "https://claude.ai/install.sh",
    "https://chatgpt.com/codex/install.sh",
    "https://x.ai/cli/install.sh",
    "https://dev.meta.ai/install.sh",
    "https://antigravity.google/cli/install.sh",
}
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
            if _AGENT_INSTALLERS & set(args):
                continue
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


# curl that serves https://HOST/PATH from $FAKE_WEB/HOST/PATH. A HEAD request
# (-I) writes the URL that $FAKE_WEB/HOST/PATH.redirect names for -w
# '%{url_effective}'. It refuses a call without --proto =https and --tlsv1.2.
_CURL_STUB = """\
printf 'curl %s\\n' "$*" >> "$CALLS_LOG"
url='' out='' head='' write='' proto='' tls=''
while [ "$#" -gt 0 ]; do
    case $1 in
        --proto) proto=$2; shift ;;
        --tlsv1.2) tls=1 ;;
        --retry) shift ;;
        -o) out=$2; shift ;;
        -w) write=$2; shift ;;
        -*I*) head=1 ;;
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
if [ -n "$head" ]; then
    target=$url
    [ ! -f "$file.redirect" ] || target=$(cat "$file.redirect")
    [ "$write" != '%{url_effective}' ] || printf '%s' "$target"
    exit 0
fi
[ -f "$file" ] || { echo "curl: (22) HTTP 404: $url" >&2; exit 22; }
if [ -n "$out" ]; then cp "$file" "$out"; else cat "$file"; fi
"""
# The commands an install step runs after its download check: they only log
# their arguments, pwsh prints a version, and dpkg the target architecture.
_BUILD_STUBS = {
    "apt-get": "",
    "apt-mark": "",
    "dpkg": 'echo "$TARGETARCH"',
    "pwsh": "echo 'PowerShell 7.9.1'",
}


def _run_install(
    tmp_path: Path,
    marker: str,
    web: dict[str, bytes],
    *,
    redirects: dict[str, str] | None = None,
    arch: str = "amd64",
    env: dict[str, str] | None = None,
    paths: dict[str, str] | None = None,
) -> tuple[subprocess.CompletedProcess[str], str, Path]:
    """Run the RUN <<'marker' step against a fake web of ``web`` (URL -> body).

    It runs with the step's build args and ENV, as the Dockerfile's SHELL
    (bash -euo pipefail -c) does, but with HOME and TMPDIR in tmp_path and the
    stubs first on PATH; the apt lists it deletes are a directory in tmp_path,
    and ``paths`` replaces other paths in the step (old -> new).
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
    for url, target in (redirects or {}).items():
        path = root / (url.removeprefix("https://") + ".redirect")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(target, encoding="utf-8")
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    log = tmp_path / "calls.log"
    log.touch()
    for name, stub in {"curl": _CURL_STUB, **_BUILD_STUBS}.items():
        path = stubs / name
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
        "PATH": f"{stubs}:{SYSTEM_PATH}",
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


_FZF_LATEST = {f"{_FZF}/latest": f"{_FZF}/tag/v0.99.1"}


@_needs(*_INSTALL_TOOLS)
@pytest.mark.parametrize("arch", ["amd64", "arm64"])
def test_fzf_comes_from_its_release_into_the_user_bin(tmp_path, arch):
    result, calls, home = _run_install(
        tmp_path, "INSTALL_FZF", _fzf_web(), redirects=_FZF_LATEST, arch=arch
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
    result, _, home = _run_install(tmp_path, "INSTALL_FZF", web, redirects=_FZF_LATEST)
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


_PWSH_LATEST = {f"{_PWSH}/latest": f"{_PWSH}/tag/v7.9.1"}


def test_powershell_is_installed_by_root():
    # A system package for every user; apt-get needs root.
    user, env, _ = _install_step("INSTALL_PWSH")
    assert user == "root"
    assert env["PATH"] == SYSTEM_PATH


@_needs(*_INSTALL_TOOLS, "iconv", "tr")
@pytest.mark.parametrize("arch", ["amd64", "arm64"])
def test_powershell_comes_from_its_release_as_a_package(tmp_path, arch):
    result, calls, _ = _run_install(
        tmp_path, "INSTALL_PWSH", _pwsh_web(), redirects=_PWSH_LATEST, arch=arch
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
    result, calls, _ = _run_install(
        tmp_path, "INSTALL_PWSH", web, redirects=_PWSH_LATEST
    )
    assert result.returncode != 0
    assert "apt-get" not in calls


# gh

_GH_KEYRING = "https://cli.github.com/packages/githubcli-archive-keyring.gpg"


@_needs("bash", "install", "sed")
@pytest.mark.parametrize(
    ("gh_version", "package", "held"),
    [("latest", "gh", False), ("2.99.0", "gh=2.99.0", True)],
    ids=["latest-upgrades", "exact-is-held"],
)
def test_gh_at_an_exact_version_is_held_against_the_upgrade(
    tmp_path, gh_version, package, held
):
    # The workspace stage's apt-get upgrade moves every package that is not
    # held to the newest version in its repository, and GitHub's repository
    # stays enabled: gh at an exact GH_VERSION came out of the image at the
    # newest version. latest is left to the upgrade.
    sysconf = tmp_path / "sysconf" / "apt"
    (sysconf / "sources.list.d").mkdir(parents=True)
    (sysconf / "sources.list.d" / "ubuntu.sources").write_text(
        "URIs: http://archive.ubuntu.com/ubuntu/\n", encoding="utf-8"
    )
    result, calls, _ = _run_install(
        tmp_path,
        "INSTALL_UTILITIES_DEPS",
        {_GH_KEYRING: b"keyring"},
        env={"GH_VERSION": gh_version},
        paths={"/etc/apt/": f"{sysconf}/"},
    )
    assert result.returncode == 0, result.stderr
    apt = [line for line in calls.splitlines() if line.startswith("apt-")]
    gh = next(
        i
        for i, line in enumerate(apt)
        if line.startswith("apt-get install") and package in line.split()
    )
    holds = [line for line in apt if line.startswith("apt-mark")]
    if held:
        assert holds == ["apt-mark hold gh"], calls
        assert apt.index("apt-mark hold gh") > gh, calls
    else:
        assert holds == [], calls


# rclone

_RCLONE = "https://downloads.rclone.org"


def _rclone_web(*, served_arch: str = "", listed: bool = True) -> dict[str, bytes]:
    """rclone v1.99.1 as the current release, with its PGP-signed SHA256SUMS.

    The archives are also served under their rclone-current names, which the
    download used before it was checked. The arguments work as _fzf_web's do.
    """
    web = {f"{_RCLONE}/version.txt": b"rclone v1.99.1\n"}
    sums = ["-----BEGIN PGP SIGNED MESSAGE-----\n", "Hash: SHA1\n", "\n"]
    for arch in ("amd64", "arm64"):
        name = f"rclone-v1.99.1-linux-{arch}.zip"
        archive = _zip(
            {
                f"rclone-v1.99.1-linux-{arch}/rclone": _fake_program(
                    f"rclone linux-{arch}"
                )
            }
        )
        if listed or arch != "amd64":
            sums.append(f"{_sha256(archive)}  {name}\n")
        if arch == served_arch:
            archive = _zip(
                {
                    f"rclone-v1.99.1-linux-{arch}/rclone": _fake_program(
                        "rclone tampered"
                    )
                }
            )
        web[f"{_RCLONE}/v1.99.1/{name}"] = archive
        web[f"{_RCLONE}/rclone-current-linux-{arch}.zip"] = archive
    sums += ["-----BEGIN PGP SIGNATURE-----\n", "\n", "c2lnbmF0dXJl\n"]
    sums.append("-----END PGP SIGNATURE-----\n")
    web[f"{_RCLONE}/v1.99.1/SHA256SUMS"] = "".join(sums).encode()
    return web


@_needs(*_INSTALL_TOOLS, "unzip")
@pytest.mark.parametrize("arch", ["amd64", "arm64"])
def test_rclone_comes_from_the_current_release_folder(tmp_path, arch):
    result, calls, home = _run_install(
        tmp_path, "INSTALL_RCLONE", _rclone_web(), arch=arch
    )
    assert result.returncode == 0, result.stderr
    rclone = home / ".local" / "bin" / "rclone"
    assert f"rclone linux-{arch}" in rclone.read_text(encoding="utf-8")
    assert f"{_RCLONE}/v1.99.1/rclone-v1.99.1-linux-{arch}.zip" in calls


@_needs(*_INSTALL_TOOLS, "unzip")
@pytest.mark.parametrize(
    "web",
    [_rclone_web(served_arch="amd64"), _rclone_web(listed=False)],
    ids=["other-contents", "not-listed"],
)
def test_rclone_that_its_sha256sums_do_not_vouch_for_is_not_installed(tmp_path, web):
    # Before the check, the image installed whatever the download gave.
    result, _, home = _run_install(tmp_path, "INSTALL_RCLONE", web)
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
        r"docker exec --user dev den-dev zsh -lc '[^']*\bfzf --version", checks["run"]
    )
    assert re.search(r"docker exec den-dev pwsh --version\b", checks["run"])
    assert "docker exec --user dev den-dev zsh -lc 'pwsh --version'" in checks["run"]
