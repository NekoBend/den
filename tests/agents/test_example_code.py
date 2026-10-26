"""The coding skill's worked examples behave as their prose says when run.

A model copies these blocks into real scripts, so each test runs the block
itself, cut from the markdown, not a copy that could drift from it. What each
test guards against, as an outside review (2026-10) found it in the old text:

- examples/shell-cleanup-main.md Example 4 set `trap ... RETURN` in a plain
  function. The trap stayed set after the call and ran again as each calling
  function returned: under set -u that exited 1 on `tmp_file: unbound
  variable`, and a caller's own tmp_file was deleted. When set -e stopped the
  function, the trap did not run and the temp file stayed behind.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = ROOT / "agents" / "src" / "skills" / "coding" / "examples"
BASH = shutil.which("bash")

needs_bash = pytest.mark.skipif(
    sys.platform == "win32" or BASH is None, reason="runs the examples under bash"
)


def _section(path: Path, number: str) -> str:
    """The `## <number> ...` section of `path`, up to the next `## ` heading."""
    text = path.read_text(encoding="utf-8")
    parts = re.split(r"(?m)^(?=## )", text)
    found = [p for p in parts if p.startswith(f"## {number} ")]
    assert len(found) == 1, f"{path.name}: no single '## {number}' section"
    return found[0]


def _fenced(text: str, lang: str) -> list[str]:
    """The bodies of the ```lang blocks in `text`."""
    return re.findall(rf"(?ms)^```{lang}\n(.*?)^```$", text)


def _bash(
    cwd: Path, *args: str, stdin: str | None = None
) -> subprocess.CompletedProcess[str]:
    """Run bash in `cwd`, with cwd/tmp as an empty TMPDIR of its own and no
    startup file or exported shell options from the calling environment."""
    assert BASH is not None
    tmp = cwd / "tmp"
    tmp.mkdir(exist_ok=True)
    env = {
        k: v
        for k, v in os.environ.items()
        if k not in {"BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS"}
    }
    env["TMPDIR"] = str(tmp)
    return subprocess.run(
        [BASH, *args],
        cwd=cwd,
        input=stdin,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )


# --- Example 4: cleanup with trap ---------------------------------------------

# fetch_order stands in for Example 2's: it prints one line per order, fails
# for "bad" (a set -e stop) and calls die for "gone" (an exit). The caller
# holds a trap and a file of its own that report_orders must leave alone.
_CALLER = r"""set -euo pipefail
die() { echo "error: $*" >&2; exit 1; }
fetch_order() {
  case "$1" in
    bad) return 7 ;;
    gone) die "failed to fetch order $1" ;;
  esac
  printf 'order %s\n' "$1"
}
source ./report_orders.sh
trap 'echo "caller EXIT trap"' EXIT
"""

_CLEANUP_CASES = {
    # report_orders two calls deep, with a local tmp_file in its caller
    "caller-local-tmp_file": (
        r"""process_orders() {
  local tmp_file="$PWD/keep.txt"
  echo keep >"$tmp_file"
  report_orders o1 o2
}
main() {
  process_orders
  echo "main finished"
}
main
""",
        0,
    ),
    "global-tmp_file": (
        r"""tmp_file="$PWD/keep.txt"
echo keep >"$tmp_file"
wrapper() { report_orders o1 o2; }
wrapper
echo "main finished"
""",
        0,
    ),
    "set-e-stops-it": (
        r"""tmp_file="$PWD/keep.txt"
echo keep >"$tmp_file"
report_orders o1 bad o2
echo "main finished"
""",
        7,
    ),
    "die-exits-it": (
        r"""tmp_file="$PWD/keep.txt"
echo keep >"$tmp_file"
report_orders o1 gone
echo "main finished"
""",
        1,
    ),
}


@needs_bash
@pytest.mark.parametrize("case", list(_CLEANUP_CASES))
def test_example_4_cleans_up_and_leaves_the_caller_alone(tmp_path, case):
    (block,) = _fenced(_section(EXAMPLES / "shell-cleanup-main.md", "4."), "bash")
    (tmp_path / "report_orders.sh").write_text(block, encoding="utf-8")
    body, rc = _CLEANUP_CASES[case]
    (tmp_path / "run.sh").write_text(_CALLER + body, encoding="utf-8")
    proc = _bash(tmp_path, "run.sh")
    out = proc.stdout.splitlines()
    assert proc.returncode == rc, proc.stdout + proc.stderr
    assert (tmp_path / "keep.txt").is_file(), "the caller's tmp_file was deleted"
    assert not list((tmp_path / "tmp").iterdir()), "the temp file was left behind"
    # The caller's EXIT trap runs once, at the end: report_orders kept its own.
    assert out[-1:] == ["caller EXIT trap"], out
    assert out.count("caller EXIT trap") == 1, out
    assert ("main finished" in out) == (rc == 0), out
    if rc == 0:
        assert re.fullmatch(r"fetched\s+2 orders", out[0]), out
