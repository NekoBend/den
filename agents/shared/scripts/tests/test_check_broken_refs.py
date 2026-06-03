"""Subprocess tests for check-broken-refs.py.

The script compares a git working tree against a base ref, so each test
builds a throwaway git repository under tmp_path. git is required; if it
is absent the script is expected to skip cleanly (exit 0), which one test
asserts directly by pointing at a non-repo directory.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-broken-refs.py"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    """Run check-broken-refs.py with `args`; return the completed process."""
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
    )


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
