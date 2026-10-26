"""The coding skill's worked examples behave as their prose says when run.

A model copies these blocks into real scripts, so each test runs the block
itself, cut from the markdown, not a copy that could drift from it. What each
test guards against, as an outside review (2026-10) found it in the old text:

- examples/shell-cleanup-main.md Example 4 set `trap ... RETURN` in a plain
  function. The trap stayed set after the call and ran again as each calling
  function returned: under set -u that exited 1 on `tmp_file: unbound
  variable`, and a caller's own tmp_file was deleted. When set -e stopped the
  function, the trap did not run and the temp file stayed behind.
- Example 5 and shell-structure.md section 9 ended the script with a bare
  `main "$@"` and said the script could be sourced: sourcing it ran main.
- examples/powershell.md's Pester mock of curl returned the JSON but left
  $LASTEXITCODE alone, so Get-Order read whatever the session held: nothing
  (a StrictMode error) or an earlier native command's exit code.
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
REFERENCE = ROOT / "agents" / "src" / "shared" / "reference"
BASH = shutil.which("bash")
PWSH = shutil.which("pwsh")

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


# --- Example 5 and shell-structure.md section 9: main "$@" --------------------

# die and process_orders stand in for Example 2's and Example 3's.
_STUBS = r"""set -euo pipefail
die() { echo "error: $*" >&2; exit 1; }
process_orders() { echo "process_orders ran with: $*"; }
"""


def _example_5() -> str:
    (block,) = _fenced(_section(EXAMPLES / "shell-cleanup-main.md", "5."), "bash")
    return _STUBS + block


def _section_9_item_7() -> str:
    """A script whose last line is the code item 7 of section 9 puts at the
    bottom: the last code span in the item that calls `main "$@"`."""
    section = _section(REFERENCE / "shell-structure.md", "9.")
    item = re.search(r"(?ms)^7\. (.*?)(?=\n\n|\n\d+\. )", section)
    assert item, "shell-structure.md section 9 has no item 7"
    spans = [s for s in re.findall(r"`([^`\n]+)`", item[1]) if 'main "$@"' in s]
    assert spans, f"item 7 shows no main call: {item[1]!r}"
    return _STUBS + 'main() { process_orders "$@"; }\n' + spans[-1] + "\n"


_SCRIPTS = {"example-5": _example_5, "shell-structure-9": _section_9_item_7}

# How the script is started, and what it must print: sourcing defines the
# functions and runs nothing, also from a function that has arguments of its
# own; executing it runs main with the script's arguments, also when bash
# reads it from stdin (curl ... | bash), where BASH_SOURCE is empty.
_DEFINED = 'echo "defined: $(type -t main)"'
_STARTS = {
    "sourced": ["-c", f"source ./orders.sh; {_DEFINED}"],
    "sourced-in-a-function": ["-c", f"f() {{ source ./orders.sh; }}; f o1; {_DEFINED}"],
    "executed": ["orders.sh", "o1", "o2"],
    "read-from-stdin": ["-s", "o1", "o2"],
}


@needs_bash
@pytest.mark.parametrize("script", list(_SCRIPTS))
@pytest.mark.parametrize("start", list(_STARTS))
def test_main_runs_when_executed_and_not_when_sourced(tmp_path, script, start):
    text = _SCRIPTS[script]()
    (tmp_path / "orders.sh").write_text(text, encoding="utf-8")
    stdin = text if start == "read-from-stdin" else None
    proc = _bash(tmp_path, *_STARTS[start], stdin=stdin)
    assert (proc.returncode, proc.stderr) == (0, ""), proc.stdout + proc.stderr
    if start.startswith("sourced"):
        assert proc.stdout == "defined: function\n"
    else:
        assert proc.stdout == "process_orders ran with: o1 o2\n"


# --- examples/powershell.md: the Pester test -----------------------------------

# Stand-ins for the Pester 5 commands the example uses (Pester is not a test
# dependency). Mock makes a command of the mocked name that runs the mock's
# body, as Pester's alias to its bootstrap function does: neither touches
# $LASTEXITCODE. Each It runs once per state the session can be in before it:
# no native command run yet (unset), an earlier one failed (1) or passed (0).
# Before each It, curl is a function that throws, so an unmocked call fails
# the test instead of reaching the network.
_PESTER = r"""param([string]$Code, [string]$Tests)
$ErrorActionPreference = 'Stop'
$script:state = ''

function Describe([string]$Name, [scriptblock]$Fixture) { & $Fixture }

function Mock([string]$CommandName, [scriptblock]$MockWith) {
    Set-Item -Path "function:global:$CommandName" -Value $MockWith
}

function It([string]$Name, [scriptblock]$Test) {
    Set-Item -Path function:global:curl -Value { throw 'curl ran without a mock' }
    if ($script:state -eq 'unset') {
        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
    } else {
        $global:LASTEXITCODE = [int]$script:state
    }
    try {
        & $Test
        "PASS [$script:state] $Name"
    } catch {
        "FAIL [$script:state] $Name :: $_"
    }
}

function Should {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(ValueFromPipeline)] $ActualValue,
        $BeOfType,
        [switch] $Throw,
        [Parameter(Position = 0)] [string] $ExpectedMessage = '*'
    )
    process {
        if ($Throw) {
            try { & $ActualValue } catch {
                if ($_.Exception.Message -notlike $ExpectedMessage) {
                    throw "threw '$($_.Exception.Message)', not '$ExpectedMessage'"
                }
                return
            }
            throw 'expected a throw, got none'
        }
        if ($null -ne $BeOfType) {
            # Pester takes a type, or its name with or without [ ] around it.
            $type = $BeOfType
            if ($type -is [string]) {
                $type = ($type -replace '^\[(.*)\]$', '$1') -as [type]
            }
            if ($ActualValue -isnot $type) {
                throw "expected [$type], got $ActualValue"
            }
            return
        }
        throw 'this stand-in knows only -BeOfType and -Throw'
    }
}

. $Code
foreach ($s in 'unset', '1', '0') {
    $script:state = $s
    . $Tests
}
"""


@pytest.mark.skipif(PWSH is None, reason="runs the example under pwsh")
def test_pester_example_passes_whatever_lastexitcode_the_session_holds(tmp_path):
    text = (EXAMPLES / "powershell.md").read_text(encoding="utf-8")
    code, tests = _fenced(text, "powershell")
    its = len(re.findall(r"(?m)^\s*It '", tests))
    assert its, "the Pester block has no It"
    drive, code_ps1, tests_ps1 = (
        tmp_path / "drive.ps1",
        tmp_path / "Get-Order.ps1",
        tmp_path / "Get-Order.Tests.ps1",
    )
    drive.write_text(_PESTER, encoding="utf-8")
    code_ps1.write_text(code, encoding="utf-8")
    tests_ps1.write_text(tests, encoding="utf-8")
    assert PWSH is not None
    # pwsh on Linux writes its caches under XDG: keep them out of $HOME
    env = {
        **os.environ,
        "POWERSHELL_TELEMETRY_OPTOUT": "1",
        "POWERSHELL_UPDATECHECK": "Off",
        "XDG_CACHE_HOME": str(tmp_path / "cache"),
        "XDG_CONFIG_HOME": str(tmp_path / "config"),
        "XDG_DATA_HOME": str(tmp_path / "data"),
    }
    proc = subprocess.run(
        [
            PWSH,
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(drive),
            "-Code",
            str(code_ps1),
            "-Tests",
            str(tests_ps1),
        ],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    results = [r for r in proc.stdout.splitlines() if r.startswith(("PASS", "FAIL"))]
    assert [r for r in results if r.startswith("FAIL")] == []
    assert len(results) == 3 * its, proc.stdout
