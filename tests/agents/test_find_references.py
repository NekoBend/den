"""Subprocess tests for find-references.py.

The script lives one directory up. It is invoked as a child process
(not imported) because its filename contains a hyphen and because the
public contract under test is its CLI: argv in, stdout + exit code out.
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
    / "find-references.py"
)

# The scripts share their search plumbing through _common.py, which is importable
# (find-references.py itself is not: its filename has a hyphen).
sys.path.insert(0, str(SCRIPT.parent))

from _common import parse_rg_line  # ruff: ignore[module-import-not-at-top-of-file]


def run(
    *args: str, cwd: Path | None = None, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    """Run find-references.py with `args`; return the completed process."""
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


@pytest.fixture
def backends(tmp_path_factory: pytest.TempPathFactory) -> list[dict[str, str] | None]:
    """The two environments a search must return the same files in.

    `None` keeps the ambient PATH, which must have ripgrep on it; the second
    replaces PATH with one empty directory, so the script cannot find rg and
    has to walk the tree itself. BOTH halves are asserted, because either one
    failing quietly turns every parity test into the same backend run twice.
    Dropping only the PATH entries that contain rg is not enough: where rg
    sits in /usr/bin that removes every other tool with it.

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
    env = dict(os.environ)
    env["PATH"] = str(bin_dir)
    assert shutil.which("rg", path=env["PATH"]) is None
    return [None, env]


def symlink_or_skip(link: Path, target: Path) -> None:
    """Create `link` -> `target`, skipping the test where that is not allowed."""
    try:
        link.symlink_to(target)
    except (OSError, NotImplementedError) as exc:  # Windows without privileges
        pytest.skip(f"symlinks unavailable: {exc}")


def write(root: Path, rel: str, body: str) -> Path:
    """Create `root/rel` (with parents) containing `body`. Return the path."""
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path


# ---------- --def ----------


def test_def_finds_python_function(tmp_path: Path) -> None:
    write(tmp_path, "mod.py", "def widget():\n    return 1\n")
    proc = run("--def", "widget", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    lines = [ln for ln in proc.stdout.splitlines() if ln]
    assert len(lines) == 1
    file, lineno, kind, _context = lines[0].split(":", 3)
    assert file.endswith("mod.py")
    assert lineno == "1"
    assert kind == "def"


def test_def_finds_class(tmp_path: Path) -> None:
    write(tmp_path, "mod.py", "class CustomerOrder:\n    pass\n")
    proc = run("--def", "CustomerOrder", "--root", str(tmp_path))
    assert proc.returncode == 0
    assert any(":def:" in ln for ln in proc.stdout.splitlines())


def test_def_no_match_is_empty_and_succeeds(tmp_path: Path) -> None:
    write(tmp_path, "mod.py", "def other():\n    pass\n")
    proc = run("--def", "missing", "--root", str(tmp_path))
    assert proc.returncode == 0
    assert proc.stdout.strip() == ""


# ---------- --uses ----------


def test_uses_excludes_the_definition_line(tmp_path: Path) -> None:
    write(tmp_path, "def_site.py", "def widget():\n    return 1\n")
    write(tmp_path, "call_site.py", "from def_site import widget\nwidget()\n")
    proc = run("--uses", "widget", "--root", str(tmp_path))
    assert proc.returncode == 0
    uses = [ln for ln in proc.stdout.splitlines() if ln]
    # The `def widget` line must NOT appear; only the two references do.
    assert all(":use:" in ln for ln in uses)
    assert not any("def_site.py:1:" in ln for ln in uses)
    assert any("call_site.py" in ln for ln in uses)


# ---------- --in ----------


def test_in_lists_symbols_defined_in_file(tmp_path: Path) -> None:
    target = write(
        tmp_path, "lib.py", "def alpha():\n    pass\n\n\ndef beta():\n    pass\n"
    )
    write(tmp_path, "user.py", "from lib import alpha\nalpha()\n")
    proc = run("--in", str(target), "--root", str(tmp_path))
    assert proc.returncode == 0
    out = proc.stdout
    assert ":def:" in out
    assert "alpha" in out and "beta" in out
    # alpha is used externally -> a use:alpha row should appear.
    assert "use:alpha" in out


# ---------- language filter ----------


def test_lang_filter_restricts_extension(tmp_path: Path) -> None:
    write(tmp_path, "a.py", "def shared():\n    pass\n")
    write(tmp_path, "b.go", "func shared() {}\n")
    proc = run("--def", "shared", "--lang", ".py", "--root", str(tmp_path))
    assert proc.returncode == 0
    lines = [ln for ln in proc.stdout.splitlines() if ln]
    assert lines and all(".py:" in ln for ln in lines)
    assert not any(".go:" in ln for ln in lines)


# ---------- errors ----------


def test_missing_root_exits_1(tmp_path: Path) -> None:
    proc = run("--def", "x", "--root", str(tmp_path / "does_not_exist"))
    assert proc.returncode == 1
    assert "not a directory" in proc.stderr


def test_requires_a_mode(tmp_path: Path) -> None:
    proc = run("--root", str(tmp_path))
    # argparse mutually-exclusive required group -> exit 2.
    assert proc.returncode == 2


def test_skip_dirs_are_not_searched(tmp_path: Path) -> None:
    write(tmp_path, "real.py", "def widget():\n    pass\n")
    write(tmp_path, "node_modules/pkg.py", "def widget():\n    pass\n")
    proc = run("--def", "widget", "--root", str(tmp_path))
    assert proc.returncode == 0
    assert not any("node_modules" in ln for ln in proc.stdout.splitlines())


def test_def_finds_powershell_function(tmp_path: Path) -> None:
    # Verb-Noun names contain a hyphen; the pattern must still anchor on the
    # function keyword and the whole name, not the first \w+ run.
    write(tmp_path, "mod.ps1", "function Get-Widget {\n    param()\n}\n")
    proc = run("--def", "Get-Widget", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    lines = [ln for ln in proc.stdout.splitlines() if ln]
    assert len(lines) == 1
    file, lineno, kind, _context = lines[0].split(":", 3)
    assert file.endswith("mod.ps1")
    assert lineno == "1"
    assert kind == "def"


def test_uses_finds_powershell_call_sites(tmp_path: Path) -> None:
    write(tmp_path, "mod.psm1", "function Get-Widget {\n    param()\n}\n")
    write(tmp_path, "caller.ps1", "$w = Get-Widget\n")
    proc = run("--uses", "Get-Widget", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    out = proc.stdout
    assert "caller.ps1" in out


def test_in_reports_full_powershell_names(tmp_path: Path) -> None:
    # --in discovers definitions with a capturing group; the capture must not
    # stop at the hyphen (New-Wrapper reported as "New" made two symbols
    # sharing a verb indistinguishable).
    write(
        tmp_path,
        "mod.ps1",
        "function New-Wrapper {\n    param()\n}\nenum WidgetKind {\n    A\n}\n",
    )
    write(tmp_path, "caller.ps1", "New-Wrapper\n")
    proc = run("--in", str(tmp_path / "mod.ps1"), "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert "New-Wrapper" in proc.stdout
    assert "WidgetKind" in proc.stdout
    # Every line is `<file>:<line>:<kind>:<context>` and <file> is the absolute
    # path, so strip that prefix first instead of splitting the line blindly:
    # both the kind (`use:<owner>`) and the context can contain colons.
    prefix = f"{tmp_path}{os.sep}"
    rows: list[tuple[str, str]] = []
    for ln in proc.stdout.splitlines():
        if not ln:
            continue
        assert ln.startswith(prefix), ln
        name, _lineno, kind_and_context = ln[len(prefix) :].split(":", 2)
        rows.append((name, kind_and_context))
    assert [n for n, kc in rows if kc.startswith("def:")] == ["mod.ps1", "mod.ps1"]
    # The external call site is attributed to the whole Verb-Noun name, never
    # to the verb alone: `use:New` is the regression this test exists for.
    owners = [kc.split(":", 2)[1] for _n, kc in rows if kc.startswith("use:")]
    assert owners == ["New-Wrapper"], proc.stdout


# ---------- rg output parsing ----------


def test_rg_line_parser_keeps_the_windows_drive_letter() -> None:
    # On Windows every rg hit starts with `C:\`, so the FIRST colon belongs to
    # the drive and the line number is in the last field. Parsed directly
    # because tests/agents runs on ubuntu only, where no rg output looks
    # like this.
    assert parse_rg_line(r"C:\repo\mod.py:12:def widget():") == (
        r"C:\repo\mod.py",
        12,
        "def widget():",
    )
    assert parse_rg_line("C:/repo/mod.py:12:def widget():") == (
        "C:/repo/mod.py",
        12,
        "def widget():",
    )


def test_rg_line_parser_reads_posix_paths_and_rejects_junk() -> None:
    assert parse_rg_line("/repo/mod.py:12:def widget():") == (
        "/repo/mod.py",
        12,
        "def widget():",
    )
    assert parse_rg_line("no separators here") is None
    assert parse_rg_line("/repo/mod.py:twelve:x") is None
    assert parse_rg_line(r"C:\repo\mod.py:no-line-number") is None


# ---------- the two backends must see the same tree ----------


def test_the_ripgrep_backend_is_really_invoked(
    tmp_path: Path, tmp_path_factory: pytest.TempPathFactory
) -> None:
    # The `backends` fixture asserts rg is reachable on the ambient PATH; this
    # observes the call itself, which is the only direct evidence that the
    # first leg of every parity test runs ripgrep and not the fallback. A stub
    # `rg` records its argv, so the flags that keep the two backends in
    # agreement are pinned on the real command line too.
    if sys.platform == "win32":
        pytest.skip("the stub rg is a /bin/sh script")
    bin_dir = tmp_path_factory.mktemp("stub-rg-bin")
    record = bin_dir / "argv.txt"
    stub = bin_dir / "rg"
    stub.write_text(
        f'#!/bin/sh\nprintf "%s\\n" "$@" > "{record}"\nexit 1\n', encoding="utf-8"
    )
    stub.chmod(0o755)
    env = dict(os.environ)
    env["PATH"] = str(bin_dir)
    write(tmp_path, "mod.py", "def widget():\n    return 1\n")

    proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
    assert proc.returncode == 0, proc.stderr
    assert record.is_file(), "rg was on PATH but the script never ran it"
    argv = record.read_text(encoding="utf-8").splitlines()
    assert "--no-ignore" in argv, argv
    assert "--hidden" in argv, argv
    assert "!.git" in argv, argv


def test_root_under_a_skipped_directory_is_still_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # SKIP_DIRS applies BELOW the root; a checkout that happens to live under a
    # directory called build/ (or dist/, target/, out/) is not itself skipped.
    root = tmp_path / "build" / "proj"
    write(root, "mod.py", "def widget():\n    return 1\n")
    for env in backends:
        proc = run("--def", "widget", "--root", str(root), env=env)
        assert proc.returncode == 0, proc.stderr
        lines = [ln for ln in proc.stdout.splitlines() if ln]
        assert len(lines) == 1, proc.stdout
        assert lines[0].endswith("mod.py:1:def:def widget():"), proc.stdout


def test_hidden_and_ignored_files_are_searched_by_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # The walk fallback knows nothing about .gitignore or dotfiles, so rg is
    # given --no-ignore/--hidden to match it. Pinned because dropping either
    # flag makes the output depend on whether rg is installed.
    (tmp_path / ".git").mkdir()  # makes rg honour .gitignore at all
    write(tmp_path, ".gitignore", "ignored.py\n")
    write(tmp_path, "ignored.py", "widget()\n")
    write(tmp_path, ".github/workflows/ci.yml", "run: widget()\n")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "ignored.py" in proc.stdout, proc.stdout
        assert "ci.yml" in proc.stdout, proc.stdout


def test_binary_files_are_not_searched_by_either_backend(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # ripgrep gives up on a file as soon as it sees a NUL byte and reports
    # nothing for it, while the walk fallback decoded every file with
    # errors="ignore" and matched the text inside it: an object file, a .pyc
    # or a PDF produced hits under one backend only.
    (tmp_path / "early.bin").write_bytes(b"\x00\x00widget()\n")
    (tmp_path / "late.bin").write_bytes(b"x" * 20000 + b"\nwidget()\n" + b"\x00")
    write(tmp_path, "real.py", "widget()\n")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert ".bin" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout


def test_the_git_directory_is_never_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # .git holds the whole history (and credentials in .git/config); it is in
    # SKIP_DIRS, and --no-ignore/--hidden must not bring it back.
    write(tmp_path, ".git/config", "widget()\n")
    write(tmp_path, "real.py", "widget()\n")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert ".git" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout


def test_symlinked_files_are_not_followed(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # rg does not follow links without -L; the fallback walk must not either,
    # or a link committed in a repo turns a search into a read of a file
    # outside it, printed verbatim.
    outside = tmp_path / "outside"
    outside.mkdir()
    secret = outside / "credentials"
    secret.write_text("widget = 'SENTINEL-SECRET'\n", encoding="utf-8")
    root = tmp_path / "repo"
    write(root, "real.py", "widget()\n")
    symlink_or_skip(root / "creds", secret)
    for env in backends:
        proc = run("--uses", "widget", "--root", str(root), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "SENTINEL-SECRET" not in proc.stdout, proc.stdout
        assert "creds" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout
