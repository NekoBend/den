"""Subprocess tests for find-references.py.

The script lives one directory up. It is invoked as a child process
(not imported) because its filename contains a hyphen and because the
public contract under test is its CLI: argv in, stdout + exit code out.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "find-references.py"


def run(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    """Run find-references.py with `args`; return the completed process."""
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
    )


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
