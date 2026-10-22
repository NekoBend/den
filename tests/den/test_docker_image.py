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

import re
import shlex
import shutil
import subprocess
import sys
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


def _instructions() -> list[tuple[str, str]]:
    """(KEYWORD, arguments) per instruction, without comments or heredoc bodies."""
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
        heredoc = re.search(r"<<-?['\"]?(\w+)['\"]?", line)
        if heredoc:
            while i < len(lines) and lines[i] != heredoc.group(1):
                i += 1
            i += 1
        keyword, _, rest = line.strip().partition(" ")
        out.append((keyword.upper(), rest.strip()))
    return out


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
    # rustup, cargo, the installers, nvm, npm and den write under the user's
    # home, so ENV HOME=/root must come after the last of them.
    as_user = [
        (stage, env, args)
        for stage, user, env, args in _run_steps()
        if user.partition(":")[0] not in {"root", "0"}
    ]
    assert len(as_user) > 10, "the parser no longer sees the user's build steps"
    for stage, env, args in as_user:
        assert env["HOME"] == f"/home/{args['USERNAME']}", stage


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
    # den's init.zsh runs its own compinit; Ubuntu's /etc/zsh/zshrc ran an
    # extra full one before it (about 12 ms) unless skip_global_compinit is set.
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
    # copies into each new container (about 2 GB); the build args avoid it.
    result, calls = _run_entrypoint(
        tmp_path, uid=0, env={"HOST_UID": "501", "HOST_GID": "20"}
    )
    assert result.returncode == 0, result.stderr
    assert "usermod --uid 501 --gid 20 dev" in calls
    lines = result.stderr.splitlines()
    assert len(lines) == 1, result.stderr
    # The copy is an overlayfs cost; other storage drivers re-own in place.
    assert "on overlayfs copies about 2 GB" in lines[0]
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
