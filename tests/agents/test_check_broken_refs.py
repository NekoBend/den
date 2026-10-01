"""Subprocess tests for check-broken-refs.py.

The script compares a git working tree against a base ref, so each test
builds a throwaway git repository under tmp_path. git is required; if it
is absent the script is expected to skip cleanly (exit 0), which one test
asserts directly by pointing at a non-repo directory.
"""

from __future__ import annotations

import json
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


def run_bytes(
    *args: str, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[bytes]:
    """Run check-broken-refs.py capturing stdout as raw bytes.

    A POSIX file name is bytes, so a test that checks how a name is PRINTED
    cannot let subprocess decode the stream for it.
    """
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        check=False,
        env=env,
    )


def git(repo: Path, *args: str) -> None:
    """Run a git command inside `repo`, raising on failure."""
    exe = shutil.which("git")
    assert exe is not None, "these tests build git repositories: install git"
    subprocess.run(
        [exe, *args],
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


def test_a_repo_root_ending_in_a_space_is_not_trimmed(tmp_path: Path) -> None:
    # `git rev-parse --show-toplevel` was .strip()ed, so a repository whose
    # top-level directory ends in a space resolved to a different path and
    # every changed file failed the "is it under --root" test: the check then
    # reported nothing at all, whatever had been removed.
    if sys.platform == "win32":
        pytest.skip("Windows trims trailing spaces from directory names")
    repo = tmp_path / "repo "
    repo.mkdir()
    init_repo(repo)
    write(repo, "lib.py", "def widget():\n    return 1\n")
    write(repo, "app.py", "widget()\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "base")

    write(repo, "lib.py", "# widget removed\n")

    proc = run("--base", "HEAD", "--root", str(repo))
    assert proc.returncode == 0, proc.stderr
    assert "broken_ref:widget" in proc.stdout, proc.stdout
    assert "app.py" in proc.stdout, proc.stdout


def test_a_non_utf8_file_name_is_not_mangled(tmp_path: Path) -> None:
    # A file name that is not valid UTF-8 is legal on POSIX. Decoding git's
    # output with errors="replace" turned it into a name with U+FFFD in it, so
    # `git show BASE:<name>` failed, the file looked as if it had not existed
    # at base, and a removal inside it was missed entirely.
    if sys.platform == "win32":
        pytest.skip("Windows file names are UTF-16, not bytes")
    name = os.fsdecode(b"bad\xff.py")
    try:
        write(tmp_path, name, "def widget():\n    return 1\n")
    except OSError as exc:  # a filesystem that insists on valid UTF-8
        pytest.skip(f"cannot create a non-UTF-8 file name: {exc}")
    init_repo(tmp_path)
    write(tmp_path, "app.py", "widget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, name, "# widget removed\n")

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert "broken_ref:widget" in proc.stdout, proc.stdout
    assert "app.py" in proc.stdout, proc.stdout


def test_the_self_exclusion_holds_for_a_non_utf8_file_name(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # A mention left behind in the file the symbol was REMOVED from is not a
    # dangling reference, and that test compares resolved paths. While rg's
    # output was decoded as text, the rg backend spelled this file's name with
    # U+FFFD, the comparison never matched, and the leftover comment was
    # reported as a broken reference under rg and not under the walker.
    if sys.platform == "win32":
        pytest.skip("Windows file names are UTF-16, not bytes")
    name = os.fsdecode(b"bad\xff.py")
    try:
        write(tmp_path, name, "def widget():\n    return 1\n")
    except OSError as exc:  # a filesystem that insists on valid UTF-8
        pytest.skip(f"cannot create a non-UTF-8 file name: {exc}")
    init_repo(tmp_path)
    write(tmp_path, "app.py", "widget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    # the definition goes; the name stays in a comment in the SAME file
    write(tmp_path, name, "# widget is gone\n")

    outputs = []
    for env in backends:
        proc = run_bytes("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert b"broken_ref:widget" in proc.stdout, proc.stdout
        assert b"app.py" in proc.stdout, proc.stdout
        # the leftover mention in the defining file is excluded by BOTH
        # backends, and no lossy spelling of the name appears either
        assert b"bad\xff.py" not in proc.stdout, proc.stdout
        assert b"\xef\xbf\xbd" not in proc.stdout, proc.stdout
        outputs.append(sorted(proc.stdout.split(b"\n")))
    assert outputs[0] == outputs[1], outputs


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
    # rg is handed the file list itself, after `--`: the same list the
    # fallback reads, so neither ignore rules nor globs of rg's own apply
    files = argv[argv.index("--") + 1 :]
    assert files == [str(tmp_path / "app.py"), str(tmp_path / "lib.py")], argv


def test_hidden_and_untracked_usages_are_reported_and_ignored_ones_are_not(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # The search covers what `git ls-files --cached --others
    # --exclude-standard` lists, on both backends: a dangling reference in
    # .github/ or in an untracked file is still a dangling reference, while a
    # virtual environment under any name (uv writes a `*` .gitignore into its
    # own) and every other ignored file is not searched. Before, the .4win uv
    # venv on the owner's checkout put 17,602 false lines into one run.
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, ".gitignore", "ignored.py\n")
    write(tmp_path, ".github/workflows/ci.yml", "run: widget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "# gone\n")
    write(tmp_path, "ignored.py", "widget()\n")
    write(tmp_path, "untracked.py", "widget()\n")
    write(tmp_path, ".4win/.gitignore", "*\n")
    write(tmp_path, ".4win/pyvenv.cfg", "home = /usr/bin\n")
    write(tmp_path, ".4win/Lib/site-packages/pkg.py", "widget()\n")

    outputs = []
    for env in backends:
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        found = sorted(
            ln[len(f"{tmp_path}{os.sep}") :].split(":", 1)[0]
            for ln in proc.stdout.splitlines()
        )
        assert found == [
            str(Path(".github", "workflows", "ci.yml")),
            "untracked.py",
        ], proc.stdout
        outputs.append(proc.stdout)
    assert outputs[0] == outputs[1], outputs


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


def test_a_very_long_line_is_clamped_identically_by_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # Same clamp, same place: one dangling reference inside a minified bundle
    # must not print the whole bundle, and both backends must print it alike.
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "widget()\n")
    long_line = "x" * 2000 + " widget() " + "y" * 3000
    write(tmp_path, "bundle.min.js", long_line + "\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "# gone\n")
    expected = long_line[:300] + f" [...+{len(long_line) - 300} chars]"

    outputs = []
    for env in backends:
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        contexts = {}
        for ln in proc.stdout.splitlines():
            file, _lineno, _kind, _symbol, context = ln.split(":", 4)
            contexts[Path(file).name] = context
        assert contexts["bundle.min.js"] == expected, contexts["bundle.min.js"][:120]
        # a short line keeps every character and gains no marker
        assert contexts["app.py"] == "widget()", contexts["app.py"]
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


def test_odd_characters_in_lines_and_file_names_survive_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # Same record-framing point at this script's own rg call site: a form feed
    # or U+2028 inside the line, and a newline inside the file name, must not
    # cut a record in half.
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "odd.txt", "head \x0c mid \u2028 widget() tail\n")
    newline_name = True
    try:
        write(tmp_path, "new\nline.txt", "widget()\n")
    except OSError:  # a filesystem that refuses the name
        newline_name = False
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "# gone\n")

    outputs = []
    for env in backends:
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "odd.txt" in proc.stdout, proc.stdout
        assert any("\x0c" in ln and "\u2028" in ln for ln in proc.stdout.split("\n")), (
            proc.stdout
        )
        if newline_name:
            assert "new\nline.txt" in proc.stdout, proc.stdout
        outputs.append(sorted(proc.stdout.split("\n")))
    assert outputs[0] == outputs[1], outputs


def test_repeated_uses_on_one_line_are_one_broken_ref_in_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # Same point at this script's own fallback: a line using the removed
    # symbol three times is one dangling reference, not three, whether or not
    # ripgrep is installed.
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "widget(); widget(); widget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "# gone\n")

    outputs = []
    for env in backends:
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        rows = [ln for ln in proc.stdout.split("\n") if ln]
        assert len(rows) == 1, rows
        assert "app.py" in rows[0], rows
        outputs.append(sorted(rows))
    assert outputs[0] == outputs[1], outputs


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


def report(proc: subprocess.CompletedProcess[str], root: Path) -> list[str]:
    """Output lines with the `<root>/` prefix removed."""
    prefix = f"{root}{os.sep}"
    out = []
    for ln in proc.stdout.splitlines():
        assert ln.startswith(prefix), ln
        out.append(ln[len(prefix) :])
    return out


# ---------- what counts as a removed definition ----------


def test_locals_and_keyword_arguments_are_not_removed_definitions(
    tmp_path: Path,
) -> None:
    # The .py assignment pattern accepted any indentation, so a function-local
    # `path = ...` and a keyword argument on its own line (`path=path,`) were
    # "top-level definitions". Rewriting the body removed them, and every
    # `path` in the tree was then reported: 22,851 lines for one real commit.
    init_repo(tmp_path)
    write(
        tmp_path,
        "lib.py",
        "def helper(src):\n"
        "    path = src + '/'\n"
        "    return dict(\n"
        "        path=path,\n"
        "    )\n",
    )
    write(tmp_path, "app.py", "import os\npath = os.getcwd()\nprint(path)\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.py", "def helper(src):\n    return src\n")

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "", proc.stdout


def test_a_deleted_file_reports_module_names_and_methods_as_attributes_only(
    tmp_path: Path,
) -> None:
    # Deleting a file made every local and every method a removed symbol,
    # each searched as a bare word: `git rm den/_board.py` printed 6,195
    # lines, 96% of them for nested names such as n, r and line. Now only
    # module-level names are searched as words; a method is searched only as
    # `.name` attribute access, and dunder methods not at all.
    init_repo(tmp_path)
    write(
        tmp_path,
        "lib.py",
        "LIMIT = 3\n"
        "def helper():\n"
        "    n = 1\n"
        "    return n\n"
        "class Box:\n"
        "    def __init__(self):\n"
        "        self.n = 0\n"
        "    def run(self):\n"
        "        return self.n\n",
    )
    write(
        tmp_path,
        "app.py",
        "from lib import helper, Box\n"
        "n = 3\n"
        "run = 4\n"
        "helper()\n"
        "Box().run()\n"
        "print(n, run)\n",
    )
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    (tmp_path / "lib.py").unlink()

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == [
        "app.py:1:broken_ref:Box:from lib import helper, Box",
        "app.py:5:broken_ref:Box:Box().run()",
        "app.py:1:broken_ref:helper:from lib import helper, Box",
        "app.py:4:broken_ref:helper:helper()",
        "app.py:5:broken_ref:run:Box().run()",
    ]


def test_conditionally_defined_functions_are_module_level(tmp_path: Path) -> None:
    # Every indented def was taken for a method, so deleting a module whose
    # helper is defined under `if os.name == "nt":`/`else:` reported neither
    # `from lib import helper` nor `helper()`: a false "zero broken refs".
    # A def in a module-level block is module-level, except under the main
    # guard; a function nested in a function is not a definition at all.
    init_repo(tmp_path)
    write(
        tmp_path,
        "lib.py",
        "import os\n"
        "if os.name == 'nt':\n"
        "    def helper():\n"
        "        def inner():\n"
        "            return 1\n"
        "        return inner()\n"
        "else:\n"
        "    def helper():\n"
        "        return 2\n"
        "try:\n"
        "    class Helper:\n"
        "        def run(self):\n"
        "            return 3\n"
        "except ImportError:\n"
        "    Helper = None\n"
        "if __name__ == '__main__':\n"
        "    def root():\n"
        "        return 4\n",
    )
    write(
        tmp_path,
        "app.py",
        "from lib import helper, Helper\nhelper()\nroot()\ninner()\nobj.run()\n",
    )
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    (tmp_path / "lib.py").unlink()

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == [
        "app.py:1:broken_ref:Helper:from lib import helper, Helper",
        "app.py:1:broken_ref:helper:from lib import helper, Helper",
        "app.py:2:broken_ref:helper:helper()",
        "app.py:5:broken_ref:run:obj.run()",
    ]


def test_a_definition_behind_a_byte_order_mark_is_seen(tmp_path: Path) -> None:
    # A UTF-8 byte-order mark (what Windows editors often write to a .ps1) was
    # read as part of line 1, so `^function` missed a definition there and
    # removing it was never reported.
    init_repo(tmp_path)
    (tmp_path / "Tools.ps1").write_bytes(
        b"\xef\xbb\xbffunction Get-Widget {\n}\nfunction Set-Thing {\n}\n"
    )
    write(tmp_path, "run.ps1", "Get-Widget\nSet-Thing\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    (tmp_path / "Tools.ps1").write_bytes(b"\xef\xbb\xbffunction Set-Thing {\n}\n")

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == ["run.ps1:1:broken_ref:Get-Widget:Get-Widget"]


def test_bash_function_keyword_form_removal_is_reported(tmp_path: Path) -> None:
    # `function name {` (no parentheses) was never a definition, so removing
    # one while callers remain printed nothing: a false "zero broken refs".
    init_repo(tmp_path)
    write(tmp_path, "lib.sh", "function deploy_app {\n  echo x\n}\n")
    write(tmp_path, "run.sh", "deploy_app\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "lib.sh", "# deploy moved away\n")

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == ["run.sh:1:broken_ref:deploy_app:deploy_app"]


def test_powershell_names_are_case_insensitive(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # `Function` (capitalised) was not a definition and a `get-widget` call
    # was not a use, so this removal went unreported. A change of case alone
    # removes nothing in PowerShell, and is not reported either.
    init_repo(tmp_path)
    write(tmp_path, "Tools.psm1", "Function Get-Widget {\n}\nfunction Set-Thing {\n}\n")
    write(tmp_path, "run.ps1", "get-widget\nSet-Thing\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "Tools.psm1", "function set-thing {\n}\n")

    for env in backends:
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert report(proc, tmp_path) == ["run.ps1:1:broken_ref:Get-Widget:get-widget"]


def test_a_removed_typescript_enum_is_reported(tmp_path: Path) -> None:
    init_repo(tmp_path)
    write(tmp_path, "status.ts", "export enum OrderStatus { Open }\n")
    write(tmp_path, "app.ts", "use(OrderStatus.Open);\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    write(tmp_path, "status.ts", "export {};\n")

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == [
        "app.ts:1:broken_ref:OrderStatus:use(OrderStatus.Open);"
    ]


def test_go_and_rust_methods_are_searched_as_members_only(tmp_path: Path) -> None:
    # A Go receiver method, every fn of a Rust impl and a fn nested in a fn
    # were "top-level" names, so deleting their file searched `String`,
    # `len` and `build` as bare words: a type alias, an unrelated function
    # and its own definition line were all reported. A method is now looked
    # for as `.name` (in Rust also `Type::name`), a nested fn not at all.
    init_repo(tmp_path)
    write(
        tmp_path,
        "lib.go",
        "package lib\n\n"
        "type Box struct{}\n\n"
        'func (b *Box) String() string { return "" }\n\n'
        "func Helper() int { return 1 }\n",
    )
    write(
        tmp_path,
        "app.go",
        "package app\n\n"
        "type String = string\n\n"
        "func show(b *lib.Box) string { return b.String() }\n",
    )
    write(
        tmp_path,
        "lib.rs",
        "pub struct Widget;\n"
        "impl Widget {\n"
        "    pub fn new() -> Self {\n"
        "        fn build() -> Widget { Widget }\n"
        "        build()\n"
        "    }\n"
        "    pub fn len(&self) -> usize { 0 }\n"
        "}\n",
    )
    write(
        tmp_path,
        "app.rs",
        "fn build() -> u8 { 1 }\n"
        "fn len(n: usize) -> usize { n }\n"
        "fn main() {\n"
        "    let w = Widget::new();\n"
        "    let n = w.len();\n"
        "}\n",
    )
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    (tmp_path / "lib.go").unlink()
    (tmp_path / "lib.rs").unlink()

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == [
        "app.go:5:broken_ref:Box:func show(b *lib.Box) string { return b.String() }",
        "app.go:5:broken_ref:String:func show(b *lib.Box) string { return b.String() }",
        "app.rs:4:broken_ref:Widget:let w = Widget::new();",
        "app.rs:5:broken_ref:len:let n = w.len();",
        "app.rs:4:broken_ref:new:let w = Widget::new();",
    ]


def test_keywords_and_the_blank_identifier_are_not_removed_names(
    tmp_path: Path,
) -> None:
    # The capture took the word after `const`/`static`/`var`/`record` for the
    # name: `pub const fn build` defined `fn`, `static mut COUNTER` defined
    # `mut` (and hid COUNTER), Go's `var _ io.Reader = ...` and Rust's
    # `const _` defined the blank identifier, and C#'s `record struct Pt`
    # defined `struct`. Deleting such a file reported every `fn`, `mut`, `_`
    # and `struct` in the tree.
    init_repo(tmp_path)
    write(
        tmp_path,
        "lib.rs",
        "pub const fn build() -> u8 { 0 }\n"
        "static mut COUNTER: u32 = 0;\n"
        "const _: () = ();\n",
    )
    write(
        tmp_path,
        "app.rs",
        "fn main() {\n"
        "    let _ = build();\n"
        "    unsafe { COUNTER += 1 }\n"
        "    let mut x = 1;\n"
        "}\n",
    )
    write(
        tmp_path,
        "lib.go",
        "package lib\n\nvar _ io.Reader = (*Box)(nil)\n\nfunc Helper() {}\n",
    )
    write(
        tmp_path,
        "app.go",
        "package app\n\nfunc run() {\n\tfor _, v := range xs { lib.Helper() }\n}\n",
    )
    write(tmp_path, "Lib.cs", "public record struct Pt(int X);\n")
    write(tmp_path, "Use.cs", "struct Other {}\nclass Use { Pt p; }\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    for name in ("lib.rs", "lib.go", "Lib.cs"):
        (tmp_path / name).unlink()

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == [
        "app.rs:3:broken_ref:COUNTER:unsafe { COUNTER += 1 }",
        "app.go:4:broken_ref:Helper:for _, v := range xs { lib.Helper() }",
        "Use.cs:2:broken_ref:Pt:class Use { Pt p; }",
        "app.rs:2:broken_ref:build:let _ = build();",
    ]


def test_lifetimes_raw_pointers_and_const_generics_are_not_rust_names(
    tmp_path: Path,
) -> None:
    # The word after `const`/`static` was taken for a definition wherever
    # the keyword stood: `&'static str` defined `str`, `*const u8` defined
    # `u8`, and a const generic parameter (`<const N: usize>`, or one on its
    # own line of a generic list rustfmt broke up) defined `N`. Deleting
    # such a file reported every `str`, `u8` and `N` in the tree, and in an
    # impl `std::str::from_utf8` as a use of the removed member `str`.
    init_repo(tmp_path)
    write(
        tmp_path,
        "lib.rs",
        'pub const NAME: &\'static str = "w";\n'
        "pub fn as_ptr(b: &[u8]) -> *const u8 { b.as_ptr() }\n"
        "pub fn first<const N: usize>(a: [u8; N]) -> u8 { a[0] }\n"
        "pub struct Grid<\n"
        "    T,\n"
        "    const ROWS: usize,\n"
        "> {\n"
        "    cells: [T; ROWS],\n"
        "}\n"
        "impl<const N: usize> Grid<u8, N> {\n"
        "    pub fn label(&self) -> &'static str { NAME }\n"
        "}\n",
    )
    write(
        tmp_path,
        "app.rs",
        "const N: usize = 2;\n"
        "const ROWS: usize = 3;\n"
        "fn main() {\n"
        "    let s: &str = NAME;\n"
        "    let u = std::str::from_utf8(&[]);\n"
        "    let b: u8 = first([1u8; N]);\n"
        "    let l = g.label();\n"
        "}\n",
    )
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    (tmp_path / "lib.rs").unlink()

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == [
        "app.rs:4:broken_ref:NAME:let s: &str = NAME;",
        "app.rs:6:broken_ref:first:let b: u8 = first([1u8; N]);",
        "app.rs:7:broken_ref:label:let l = g.label();",
    ]


def test_java_and_csharp_nested_types_are_searched_as_members_only(
    tmp_path: Path,
) -> None:
    # A type nested in a Java or C# class was a "top-level" name, so another
    # class's own nested type of the same name was reported when it was
    # removed. A top-level type inside a C# namespace block is still one.
    init_repo(tmp_path)
    write(
        tmp_path, "Outer.java", "public class Outer {\n    static class Inner {}\n}\n"
    )
    write(
        tmp_path,
        "App.java",
        "class App {\n    static class Inner {}\n    Outer.Inner a;\n}\n",
    )
    write(
        tmp_path,
        "Lib.cs",
        "namespace Lib {\n    public class Shell {\n        public class Nested {}\n"
        "    }\n}\n",
    )
    write(
        tmp_path,
        "Use.cs",
        "class Use {\n    class Nested {}\n    Lib.Shell.Nested n;\n}\n",
    )
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    (tmp_path / "Outer.java").unlink()
    (tmp_path / "Lib.cs").unlink()

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == [
        "App.java:3:broken_ref:Inner:Outer.Inner a;",
        "Use.cs:3:broken_ref:Nested:Lib.Shell.Nested n;",
        "App.java:3:broken_ref:Outer:Outer.Inner a;",
        "Use.cs:3:broken_ref:Shell:Lib.Shell.Nested n;",
    ]


# ---------- renames ----------


def test_a_renamed_file_keeps_its_removed_definitions_checked(tmp_path: Path) -> None:
    # `git diff --name-only` names a renamed file by its NEW path alone, where
    # nothing existed at base, so the file was skipped and every definition
    # removed from it went unchecked.
    init_repo(tmp_path)
    others = "".join(f"def f{i}():\n    return {i}\n" for i in range(20))
    write(tmp_path, "util.py", "def helper():\n    return 1\n" + others)
    write(tmp_path, "main.py", "from util import helper\nhelper()\nf3()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    git(tmp_path, "mv", "util.py", "helpers.py")
    write(tmp_path, "helpers.py", "# helper went away\n" + others)
    git(tmp_path, "add", "-A")

    expected = [
        "main.py:1:broken_ref:helper:from util import helper",
        "main.py:2:broken_ref:helper:helper()",
    ]
    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    # f3 survived the move; the comment in the renamed file itself is not
    # an external reference
    assert report(proc, tmp_path) == expected

    git(tmp_path, "commit", "-q", "-m", "rename")
    proc = run("--base", "HEAD~1", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == expected


def test_a_pure_rename_reports_nothing(tmp_path: Path) -> None:
    init_repo(tmp_path)
    write(tmp_path, "util.py", "def helper():\n    return 1\n")
    write(tmp_path, "main.py", "helper()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")
    git(tmp_path, "mv", "util.py", "helpers.py")

    proc = run("--base", "HEAD", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout == "", proc.stdout


# ---------- cost ----------


def counting_rg(bin_dir: Path) -> Path:
    """A `rg` in `bin_dir` that logs one line per run, then runs the real one.

    Returns the log file. git is linked next to it, so PATH=bin_dir is enough.
    """
    real = shutil.which("rg")
    git_exe = shutil.which("git")
    assert real is not None, "this test needs ripgrep on PATH"
    assert git_exe is not None, "these tests need git on PATH"
    log = bin_dir / "rg-runs.log"
    stub = bin_dir / "rg"
    stub.write_text(
        f'#!/bin/sh\necho run >> "{log}"\nexec "{real}" "$@"\n', encoding="utf-8"
    )
    stub.chmod(0o755)
    (bin_dir / Path(git_exe).name).symlink_to(git_exe)
    return log


def test_all_removed_symbols_are_found_in_one_search(
    tmp_path: Path, tmp_path_factory: pytest.TempPathFactory
) -> None:
    # One full-tree search per removed symbol (173 rg processes for one
    # deleted stdlib module, or 173 tree walks without rg) became one search
    # whose hits are attributed to the symbols each line names.
    if sys.platform == "win32":
        pytest.skip("the counting rg is a /bin/sh script")
    log = counting_rg(tmp_path_factory.mktemp("counting-rg"))
    env = dict(os.environ)
    env["PATH"] = str(log.parent)
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "".join(f"def f{i}():\n    pass\n" for i in range(5)))
    write(tmp_path, "app.py", "f0()\nf4()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")
    (tmp_path / "lib.py").unlink()

    proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == [
        "app.py:1:broken_ref:f0:f0()",
        "app.py:2:broken_ref:f4:f4()",
    ]
    assert log.read_text(encoding="utf-8").count("run") == 1


def test_each_hit_file_is_resolved_once(tmp_path: Path) -> None:
    # Every hit was resolved (realpath: one lstat per path component) on its
    # own, which was 85% of the run time on the owner's drvfs checkout.
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    app = write(tmp_path, "app.py", "widget()\n" * 60)
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")
    write(tmp_path, "lib.py", "# gone\n")

    probe = (
        "import json, pathlib, runpy, sys\n"
        "calls = []\n"
        "orig = pathlib.Path.resolve\n"
        "def counting(self, *a, **k):\n"
        "    calls.append(str(self))\n"
        "    return orig(self, *a, **k)\n"
        "pathlib.Path.resolve = counting\n"
        "script = sys.argv[1]\n"
        "sys.path.insert(0, str(pathlib.Path(script).parent))\n"
        "sys.argv = sys.argv[1:]\n"
        "try:\n"
        "    runpy.run_path(script, run_name='__main__')\n"
        "except SystemExit:\n"
        "    pass\n"
        "sys.stderr.write('CALLS=' + json.dumps(calls) + '\\n')\n"
    )
    proc = subprocess.run(
        [sys.executable, "-c", probe, str(SCRIPT), "--root", str(tmp_path)],
        capture_output=True,
        text=True,
        check=True,
    )
    assert proc.stdout.count("broken_ref:widget") == 60, proc.stdout
    line = next(ln for ln in proc.stderr.splitlines() if ln.startswith("CALLS="))
    calls = json.loads(line.removeprefix("CALLS="))
    assert calls.count(str(app)) == 1, calls.count(str(app))


# ---------- the base is reported ----------


def test_the_base_and_the_changed_file_count_go_to_stderr(tmp_path: Path) -> None:
    # The default base HEAD covers uncommitted changes only. A review of a
    # committed branch got an empty diff, printed nothing and exited 0, which
    # read as "no dangling references".
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")

    proc = run("--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert "base=HEAD: 0 changed files examined" in proc.stderr, proc.stderr
    assert "--base" in proc.stderr, proc.stderr
    assert "merge-base" in proc.stderr, proc.stderr

    write(tmp_path, "lib.py", "def widget():\n    return 2\n")
    proc = run("--root", str(tmp_path))
    assert "base=HEAD: 1 changed file examined" in proc.stderr, proc.stderr
    assert "merge-base" not in proc.stderr, proc.stderr


def test_code_audit_tells_the_model_to_pass_a_base_for_committed_changes() -> None:
    skills = SCRIPT.parents[2] / "skills" / "code-audit"
    step3 = (skills / "SKILL.md").read_text(encoding="utf-8")
    step3 = step3[step3.index("### Step 3") : step3.index("### Step 4")]
    correctness = (skills / "reference" / "dimensions" / "correctness.md").read_text(
        encoding="utf-8"
    )
    for text in (step3, correctness):
        assert "--base" in text, text
        assert "git merge-base" in text, text


# ---------- git and rg are never taken from the checkout ----------


def test_the_repositorys_fsmonitor_program_never_runs(
    tmp_path: Path, tmp_path_factory: pytest.TempPathFactory
) -> None:
    # git starts whatever program the repository's own .git/config names as
    # core.fsmonitor, and `git diff` / `git ls-files` ask it which files
    # changed: a checkout that came with its .git (an archive, a shared
    # folder) ran it on every check.
    if sys.platform == "win32":
        pytest.skip("the fsmonitor program is a /bin/sh script")
    scratch = tmp_path_factory.mktemp("fsmonitor")
    marker = scratch / "fsmonitor-ran"
    hook = scratch / "hook"
    hook.write_text(f'#!/bin/sh\necho ran >> "{marker}"\n', encoding="utf-8")
    hook.chmod(0o755)
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "widget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")
    write(tmp_path, "lib.py", "# gone\n")
    git(tmp_path, "config", "core.fsmonitor", str(hook))

    proc = run("--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert report(proc, tmp_path) == ["app.py:1:broken_ref:widget:widget()"]
    assert not marker.exists(), marker.read_text(encoding="utf-8")


def test_a_git_or_rg_planted_in_the_checkout_never_runs(
    tmp_path: Path, tmp_path_factory: pytest.TempPathFactory
) -> None:
    # A bare "git"/"rg" is looked up through every PATH entry, and an empty or
    # relative entry means the working directory: a checkout that ships its
    # own git or rg (git.exe / rg.exe on Windows, where the cwd is searched
    # even without such an entry) had it run. Tools now come from absolute
    # PATH entries only, by absolute path.
    if sys.platform == "win32":
        pytest.skip("the planted tools are /bin/sh scripts")
    init_repo(tmp_path)
    write(tmp_path, "lib.py", "def widget():\n    return 1\n")
    write(tmp_path, "app.py", "widget()\n")
    git(tmp_path, "add", "-A")
    git(tmp_path, "commit", "-q", "-m", "base")
    write(tmp_path, "lib.py", "# gone\n")
    marker = tmp_path_factory.mktemp("marker") / "planted-ran"
    for tool in ("git", "rg"):
        planted = tmp_path / tool
        planted.write_text(f'#!/bin/sh\necho {tool} >> "{marker}"\nexit 1\n')
        planted.chmod(0o755)
    bin_dir = tmp_path_factory.mktemp("git-only-bin")
    git_exe = shutil.which("git")
    assert git_exe is not None
    (bin_dir / "git").symlink_to(git_exe)
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([".", str(bin_dir)])

    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "--root", "."],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    assert proc.returncode == 0, proc.stderr
    assert not marker.exists(), marker.read_text()
    assert report(proc, tmp_path) == ["app.py:1:broken_ref:widget:widget()"]
