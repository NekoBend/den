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


def without_rg() -> dict[str, str]:
    """A copy of os.environ whose PATH holds no `rg`, forcing the walk fallback.

    The script must report the same broken references either way, and the CI
    runners have ripgrep installed, so parity tests run it in both.
    """
    env = dict(os.environ)
    kept = [
        entry
        for entry in env.get("PATH", "").split(os.pathsep)
        if entry and shutil.which("rg", path=entry) is None
    ]
    env["PATH"] = os.pathsep.join(kept)
    if shutil.which("git", path=env["PATH"]) is None:
        pytest.skip("git and rg share a PATH entry; cannot force the fallback")
    return env


def both_backends() -> list[dict[str, str] | None]:
    """The two environments the check must behave identically in."""
    return [None, without_rg()]


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


def test_hidden_and_ignored_usages_are_reported_by_both_backends(
    tmp_path: Path,
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

    for env in both_backends():
        proc = run("--base", "HEAD", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "ci.yml" in proc.stdout, proc.stdout
        assert "ignored.py" in proc.stdout, proc.stdout


def test_symlinked_files_are_not_followed(tmp_path: Path) -> None:
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

    for env in both_backends():
        proc = run("--base", "HEAD", "--root", str(repo), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "SENTINEL-SECRET" not in proc.stdout, proc.stdout
        assert "creds" not in proc.stdout, proc.stdout
        assert "app.py" in proc.stdout, proc.stdout
