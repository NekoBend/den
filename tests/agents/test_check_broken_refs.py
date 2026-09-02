"""Subprocess tests for check-broken-refs.py.

The script compares a git working tree against a base ref, so each test
builds a throwaway git repository under tmp_path. git is required; if it
is absent the script is expected to skip cleanly (exit 0), which one test
asserts directly by pointing at a non-repo directory.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = (
    Path(__file__).resolve().parents[2]
    / "agents"
    / "src"
    / "shared"
    / "scripts"
    / "check-broken-refs.py"
)


def run(
    *args: str, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    """Run check-broken-refs.py with `args`; return the completed process."""
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


@pytest.fixture
def backends(tmp_path_factory: pytest.TempPathFactory) -> list[dict[str, str] | None]:
    """The two environments the check must report the same references in.

    `None` keeps the ambient PATH, which must have ripgrep on it; the second
    replaces PATH with a directory holding nothing but a link to git (the
    script needs git, not rg), so rg cannot be found and the walk fallback is
    the only option. Dropping only the PATH entries that contain rg would take
    git with it wherever the two live in the same directory, and the test
    would skip instead of checking anything - all three assertions below pin
    one half each.

    The directory is a sibling of the test's own tmp_path, never inside it, so
    it cannot show up in the tree being searched.
    """
    assert shutil.which("rg") is not None, (
        "these parity tests need ripgrep on PATH: without it BOTH legs below "
        "run the walk fallback and the comparison proves nothing. Install it "
        "(apt-get install ripgrep / brew install ripgrep); CI installs it in "
        "the job that runs tests/agents."
    )
    bin_dir = tmp_path_factory.mktemp("no-rg-bin")
    git_exe = shutil.which("git")
    assert git_exe is not None, "these tests need git on PATH"
    link = bin_dir / Path(git_exe).name
    try:
        link.symlink_to(git_exe)
    except (OSError, NotImplementedError):  # Windows without privileges
        shutil.copy2(git_exe, link)
    env = dict(os.environ)
    env["PATH"] = str(bin_dir)
    assert shutil.which("rg", path=env["PATH"]) is None
    assert shutil.which("git", path=env["PATH"]) is not None
    return [None, env]


def git(repo: Path, *args: str) -> None:
    """Run a git command inside `repo`, raising on failure."""
    subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )


def init_repo(root: Path) -> None:
    """Initialise a git repo with a deterministic identity and one commit base."""
    git(root, "init", "-q")
    git(root, "config", "user.email", "t@example.com")
    git(root, "config", "user.name", "Test")


def write(root: Path, rel: str, body: str) -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path


def test_removed_def_with_remaining_usage_is_reported(tmp_path: Path) -> None:
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "from lib import widget\nwidget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    # Working-tree change: delete the definition but keep the usage.
    write(tmp_path, "lib.py", "# widget removed\n")

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    out = proc.stdout
    assert "broken_ref:widget" in out
    assert "app.py" in out


def test_same_file_mention_is_not_reported(tmp_path: Path) -> None:
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    # Remove the definition but leave the name in a comment in the SAME file.
    # That leftover mention must NOT be reported as a broken reference.
    write(tmp_path, "lib.py", "# widget is now gone\n")

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert "broken_ref:widget" not in proc.stdout


def test_no_removal_produces_no_output(tmp_path: Path) -> None:
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    # Change the body but keep the def name -> nothing removed.
    write(tmp_path, "lib.py", "def widget():\n    return 2\n")

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == ""


def test_file_deleted_entirely_reports_remaining_usages(tmp_path: Path) -> None:
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "from lib import widget\nwidget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    # Delete the whole defining file in the working tree. Every def it held
    # at base counts as removed, so its external usages become broken refs.
    (tmp_path / "lib.py").unlink()

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert "broken_ref:widget" in proc.stdout
    assert "app.py" in proc.stdout


def test_not_a_git_repo_skips_cleanly(tmp_path: Path) -> None:
    # No `git init` here.
    proc = run("--root", str(tmp_path))
    assert proc.returncode == 0
    assert "SKIPPED" in proc.stderr


def test_missing_root_exits_1(tmp_path: Path) -> None:
    proc = run("--root", str(tmp_path / "nope"))
    assert proc.returncode == 1
    assert "not a directory" in proc.stderr


def test_lang_filter_limits_to_extension(tmp_path: Path) -> None:
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "lib.go", "func Widget() int { return 1 }\n")
    write(tmp_path, "app.py", "widget()\n")
    write(tmp_path, "app.go", "Widget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "# gone\n")
    write(tmp_path, "lib.go", "// gone\n")

    proc = run("--base", "HEAD", "--root", str(tmp_path), "--lang", ".py")
    assert proc.returncode == 0, proc.stderr
    # Only the .py removal is considered, so only `widget` is reported.
    assert "broken_ref:widget" in proc.stdout
    assert "broken_ref:Widget" not in proc.stdout


def test_powershell_names_survive_the_hyphen(tmp_path: Path) -> None:
    # The discovery capture must anchor the WHOLE Verb-Noun name. With the
    # default \w+ capture, "function New-Wrapper" defines "New": deleting
    # New-Wrapper stayed invisible behind New-WrapperSuffix (false negative),
    # and deleting a Test-* symbol collided with every Test-Path call
    # (false-positive flood). Measured on this repo's own shell/pwsh tree.
    init_repo(tmp_path)
    write(
        tmp_path,
        "helpers.ps1",
        "function New-Wrapper {\n    param()\n}\n"
        "function New-WrapperSuffix {\n    param()\n}\n",
    )
    write(tmp_path, "caller.ps1", "New-Wrapper\nNew-WrapperSuffix\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")
    write(
        tmp_path,
        "helpers.ps1",
        "function New-WrapperSuffix {\n    param()\n}\n",
    )
    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    out = proc.stdout
    assert "broken_ref:New-Wrapper:" in out.replace("caller.ps1:1:", "x:") or (
        "New-Wrapper" in out
    ), f"full name not reported: {out!r}"
    # the surviving suffix symbol must NOT be flagged
    assert "New-WrapperSuffix" not in [
        ln.split(":")[3] for ln in out.splitlines() if ln.count(":") >= 3
    ]


def test_subdirectory_root_does_not_invent_broken_refs(tmp_path: Path) -> None:
    # `git diff --name-only` prints paths relative to the REPOSITORY top-level,
    # not to --root. Joining them onto a sub-directory root made every changed
    # file look deleted, so every symbol it defined was reported as broken -
    # including at its own surviving definition line.
    init_repo(tmp_path)
    write(tmp_path, "pkg/lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "pkg/app.py", "from lib import widget\nwidget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    # Body-only change: the def survives, so nothing is broken.
    write(tmp_path, "pkg/lib.py", "def widget():\n    return 2\n")

    proc = run("--base", "HEAD", "--root", str(tmp_path / "pkg"))
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "", proc.stdout


def test_subdirectory_root_still_reports_a_real_removal(tmp_path: Path) -> None:
    init_repo(tmp_path)
    write(tmp_path, "pkg/lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "pkg/app.py", "from lib import widget\nwidget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "pkg/lib.py", "# widget removed\n")

    proc = run("--base", "HEAD", "--root", str(tmp_path / "pkg"))
    assert proc.returncode == 0, proc.stderr
    assert "broken_ref:widget" in proc.stdout
    assert "app.py" in proc.stdout
    # the defining file is the one the removal is part of: not a broken ref
    assert "lib.py" not in proc.stdout, proc.stdout


def test_non_ascii_paths_are_resolved_not_quoted(tmp_path: Path) -> None:
    # `git diff --name-only` renders café.py as "caf\303\251.py" - quotes and
    # octal escapes included - which resolves to no file, so the script called
    # the file DELETED and reported every symbol it defined at base.
    init_repo(tmp_path)
    write(tmp_path, "café.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "widget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    # A body-only change removes nothing, so nothing may be reported.
    write(tmp_path, "café.py", "def widget():\n    return 2\n")
    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "", proc.stdout

    # ...and a real removal in the same file is still reported.
    write(tmp_path, "café.py", "# widget removed\n")
    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert "broken_ref:widget" in proc.stdout
    assert "app.py" in proc.stdout


def test_a_path_with_leading_whitespace_is_not_lost(tmp_path: Path) -> None:
    # The line used to be .strip()ed, which turned " lead.py" into "lead.py".
    # `git show HEAD:lead.py` then failed too, so the script concluded the
    # file did not exist at base and a real removal inside it was reported as
    # nothing at all: the silent false negative that mirrors the non-ASCII
    # false positive above.
    init_repo(tmp_path)
    try:
        write(tmp_path, " lead.py", "def gadget():\n    return 1\n")
    except OSError as exc:  # a filesystem that forbids the name
        pytest.skip(f"cannot create a file name starting with a space: {exc}")
    write(tmp_path, "app.py", "gadget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, " lead.py", "# gadget removed\n")
    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert "broken_ref:gadget" in proc.stdout, proc.stdout
    assert "app.py" in proc.stdout, proc.stdout


def test_changed_files_outside_the_root_are_ignored(tmp_path: Path) -> None:
    init_repo(tmp_path)
    write(tmp_path, "pkg/keep.py", "def kept():\n    return 1\n")
    write(tmp_path, "other/lib.py", "def outside():\n    return 1\n")
    write(tmp_path, "pkg/app.py", "outside()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "other/lib.py", "# outside removed\n")

    # The removal happened outside --root, so it is not this run's blast radius.
    proc = run("--base", "HEAD", "--root", str(tmp_path / "pkg"))
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "", proc.stdout


def test_the_ripgrep_backend_is_really_invoked(
    tmp_path: Path, tmp_path_factory: pytest.TempPathFactory
) -> None:
    # As in test_find_references: prove the with-rg leg of the parity tests
    # actually shells out to rg, and pin this script's own flag list (it was
    # missing --no-ignore/--hidden, which is what let the two backends
    # disagree) on the real command line.
    if sys.platform == "win32":
        pytest.skip("the stub rg is a /bin/sh script")
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "widget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")
    write(tmp_path, "lib.py", "# gone\n")

    bin_dir = tmp_path_factory.mktemp("stub-rg-bin")
    record = bin_dir / "argv.txt"
    stub = bin_dir / "rg"
    stub.write_text(
        f'#!/bin/sh\nprintf "%s\\n" "$@" > "{record}"\nexit 1\n', encoding="utf-8"
    )
    stub.chmod(0o755)
    git_exe = shutil.which("git")
    assert git_exe is not None, "these tests need git on PATH"
    (bin_dir / Path(git_exe).name).symlink_to(git_exe)
    env = dict(os.environ)
    env["PATH"] = str(bin_dir)

    proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
    assert proc.returncode == 0, proc.stderr
    assert record.is_file(), "rg was on PATH but the script never ran it"
    argv = record.read_text(encoding="utf-8").splitlines()
    assert "--no-config" in argv, argv
    assert "--null" in argv, argv
    assert "--text" in argv, argv
    assert "--no-ignore" in argv, argv
    assert "--hidden" in argv, argv
    assert "!.git" in argv, argv


def test_hidden_and_ignored_usages_are_reported_by_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # The walk fallback reads dotfiles and git-ignored files, so rg is given
    # --no-ignore/--hidden to match: a dangling reference in .github/ or in an
    # untracked file is still a dangling reference, and the report must not
    # depend on whether rg is installed.
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, ".gitignore", "ignored.py\n")
    write(tmp_path, ".github/workflows/ci.yml", "run: widget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "# gone\n")
    write(tmp_path, "ignored.py", "widget()\n")

    for env in backends:
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "ci.yml" in proc.stdout, proc.stdout
        assert "ignored.py" in proc.stdout, proc.stdout


def test_binary_files_are_searched_as_text_by_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # Same policy as in find-references: every regular file is searched as
    # text by both backends, so a dangling reference sitting in a blob is
    # reported the same way whether or not rg is installed.
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "widget()\n")
    (tmp_path / "early.bin").write_bytes(b"\x00\x00widget()\n")
    (tmp_path / "late.bin").write_bytes(b"x" * 20000 + b"\nwidget()\n" + b"\x00")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "# gone\n")

    outputs = []
    for env in backends:
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "early.bin" in proc.stdout, proc.stdout
        assert "late.bin" in proc.stdout, proc.stdout
        assert "app.py" in proc.stdout, proc.stdout
        outputs.append(sorted(proc.stdout.splitlines()))
    assert outputs[0] == outputs[1], outputs


def test_undecodable_bytes_do_not_forge_a_broken_ref(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # Same parity point as find-references: rg searches raw bytes and never
    # matches `widget` in b"wid\xffget()", so the walk fallback must not
    # decode the 0xff away and call it a dangling reference.
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "widget()\n")
    (tmp_path / "bad.txt").write_bytes(b"wid\xffget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "# gone\n")

    for env in backends:
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "bad.txt" not in proc.stdout, proc.stdout
        assert "app.py" in proc.stdout, proc.stdout


def test_a_ripgrep_config_cannot_change_what_is_searched(
    tmp_path: Path,
    tmp_path_factory: pytest.TempPathFactory,
    backends: list[dict[str, str] | None],
) -> None:
    # A user config carrying --follow or extra globs would make the rg backend
    # read files the walker never sees (here: a symlink out of the tree), so a
    # "broken reference" would depend on the machine's ripgrep configuration.
    # --no-config keeps both backends on the same files.
    config = tmp_path_factory.mktemp("rg-config") / "rgrc"
    config.write_text("--follow\n--text\n", encoding="utf-8")
    secret = tmp_path_factory.mktemp("outside") / "credentials"
    secret.write_text("widget = 'SENTINEL-SECRET'\n", encoding="utf-8")
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "widget()\n")
    (tmp_path / "blob.bin").write_bytes(b"\x00\x00widget()\n")
    try:
        (tmp_path / "creds").symlink_to(secret)
    except (OSError, NotImplementedError) as exc:  # Windows without privileges
        pytest.skip(f"symlinks unavailable: {exc}")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "# gone\n")

    outputs = []
    for env in backends:
        full = dict(os.environ if env is None else env)
        full["RIPGREP_CONFIG_PATH"] = str(config)
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=full)
        assert proc.returncode == 0, proc.stderr
        assert "SENTINEL-SECRET" not in proc.stdout, proc.stdout
        assert "app.py" in proc.stdout, proc.stdout
        outputs.append(sorted(proc.stdout.splitlines()))
    assert outputs[0] == outputs[1], outputs


def test_a_file_named_like_a_skipped_directory_is_not_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # Same point as in test_find_references: the `.git` of a linked worktree
    # is a regular file, and rg excludes it by name while the walker used to
    # prune directory names only.
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "widget()\n")
    write(tmp_path, "worktree/.git", "gitdir: /elsewhere/.git/worktrees/x\nwidget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "# gone\n")

    for env in backends:
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert ".git" not in proc.stdout, proc.stdout
        assert "app.py" in proc.stdout, proc.stdout


def test_the_git_directory_is_never_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # .git carries the whole history (and credentials in .git/config), and
    # --no-ignore/--hidden must not bring it into the search.
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "widget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "# gone\n")
    (tmp_path / ".git" / "leak.txt").write_text("widget()\n", encoding="utf-8")

    for env in backends:
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert ".git" not in proc.stdout, proc.stdout
        assert "app.py" in proc.stdout, proc.stdout


def test_symlinked_files_are_not_followed(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # rg does not follow links without -L; the fallback walk must not either,
    # or a link committed in the repo turns the usage search into a read of a
    # file outside the tree, printed verbatim as a "broken reference".
    outside = tmp_path / "outside"
    outside.mkdir()
    secret = outside / "credentials"
    secret.write_text("widget = 'SENTINEL-SECRET'\n", encoding="utf-8")
    repo = tmp_path / "repo"
    repo.mkdir()
    init_repo(repo)
    write(repo, "lib.py", "def widget():\n    return 1\n")
    write(repo, "app.py", "widget()\n")
    try:
        (repo / "creds").symlink_to(secret)
    except (OSError, NotImplementedError) as exc:  # Windows without privileges
        pytest.skip(f"symlinks unavailable: {exc}")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "base")

    write(repo, "lib.py", "# gone\n")

    for env in backends:
        proc = run("--base", "HEAD", "--root", str(repo), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "SENTINEL-SECRET" not in proc.stdout, proc.stdout
        assert "creds" not in proc.stdout, proc.stdout
        assert "app.py" in proc.stdout, proc.stdout
