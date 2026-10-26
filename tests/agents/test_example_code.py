"""The coding skill's worked examples behave as their prose says when run.

A model copies these blocks into real scripts, so each test runs the block
itself, cut from the markdown, not a copy that could drift from it. What each
test guards against, as an outside review (2026-10) found it in the old text:

- examples/shell-cleanup-main.md Example 4 set `trap ... RETURN` in a plain
  function. The trap stayed set after the call and ran again as each calling
  function returned: under set -u that exited 1 on `tmp_file: unbound
  variable`, and a caller's own tmp_file was deleted. When set -e stopped the
  function, the trap did not run and the temp file stayed behind. It also
  relied on set -e to stop at a failed fetch, which bash turns off in
  `result="$(report_orders ...)"`: that call went on and returned a count.
- Example 5 and shell-structure.md section 9 ended the script with a bare
  `main "$@"` and said the script could be sourced: sourcing it ran main.
  A `BASH_SOURCE` check against $0 still ran it when sourced through
  `bash -c 'source "$0"' ./orders.sh`. Example 5's usage error exited 1
  through die, where section 10 gives usage errors 2.
- examples/powershell.md's Pester mock of curl returned the JSON but left
  $LASTEXITCODE alone, so Get-Order read whatever the session held: nothing
  (a StrictMode error) or an earlier native command's exit code. The Pester
  block never loaded Get-Order either, so under Pester 5 its It blocks could
  not find it.
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
# with 7 for "bad" and calls die for "gone" (an exit). The caller holds a
# trap and a file of its own that report_orders must leave alone.
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

# A global tmp_file in the caller
_KEEP = r"""tmp_file="$PWD/keep.txt"
echo keep >"$tmp_file"
"""

# Each case: the caller's code, the status the script must exit with, and
# what it must print before its EXIT trap runs.
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
        ["fetched 2 orders", "main finished"],
    ),
    "global-tmp_file": (
        _KEEP
        + r"""wrapper() { report_orders o1 o2; }
wrapper
echo "main finished"
""",
        0,
        ["fetched 2 orders", "main finished"],
    ),
    "set-e-stops-it": (
        _KEEP + 'report_orders o1 bad o2\necho "main finished"\n',
        7,
        [],
    ),
    "die-exits-it": (_KEEP + 'report_orders o1 gone\necho "main finished"\n', 1, []),
    # die ends only report_orders' subshell: a caller that tests the call goes on
    "die-in-a-tested-call": (
        _KEEP + 'report_orders o1 gone || echo "report_orders failed with $?"\n',
        0,
        ["report_orders failed with 1"],
    ),
    # $(...) runs report_orders with set -e off, and an `if` keeps it off:
    # the failed fetch must still end it, before it prints a count.
    "captured": (
        _KEEP + 'result="$(report_orders o1 o2)"\necho "main finished: $result"\n',
        0,
        ["main finished: fetched 2 orders"],
    ),
    "captured-failure": (
        _KEEP + 'result="$(report_orders o1 bad o2)"\necho "main finished: $result"\n',
        7,
        [],
    ),
    "captured-failure-in-an-if": (
        _KEEP
        + r"""if result="$(report_orders o1 bad o2)"; then
  echo "main finished: $result"
else
  echo "report_orders failed with $?: [$result]"
fi
""",
        0,
        ["report_orders failed with 7: []"],
    ),
}


@needs_bash
@pytest.mark.parametrize("case", list(_CLEANUP_CASES))
def test_example_4_cleans_up_and_leaves_the_caller_alone(tmp_path, case):
    (block,) = _fenced(_section(EXAMPLES / "shell-cleanup-main.md", "4."), "bash")
    (tmp_path / "report_orders.sh").write_text(block, encoding="utf-8")
    body, rc, printed = _CLEANUP_CASES[case]
    (tmp_path / "run.sh").write_text(_CALLER + body, encoding="utf-8")
    proc = _bash(tmp_path, "run.sh")
    # BSD wc pads the count with spaces
    out = [" ".join(line.split()) for line in proc.stdout.splitlines()]
    assert proc.returncode == rc, proc.stdout + proc.stderr
    assert (tmp_path / "keep.txt").is_file(), "the caller's tmp_file was deleted"
    assert not list((tmp_path / "tmp").iterdir()), "the temp file was left behind"
    # The caller's EXIT trap runs once, at the end: report_orders kept its own.
    assert out == [*printed, "caller EXIT trap"], out


# --- Example 5 and shell-structure.md section 9: main "$@" --------------------

# process_orders stands in for Example 3's.
_STUBS = r"""set -euo pipefail
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
# own, and through `bash -c 'source "$0"' ./orders.sh`, where $0 and
# BASH_SOURCE both name the file; executing it runs main with the script's
# arguments, also when bash reads it from stdin (curl ... | bash), where
# BASH_SOURCE is empty.
_DEFINED = 'echo "defined: $(type -t main)"'
_STARTS = {
    "sourced": ["-c", f"source ./orders.sh; {_DEFINED}"],
    "sourced-in-a-function": ["-c", f"f() {{ source ./orders.sh; }}; f o1; {_DEFINED}"],
    "sourced-by-bash-c": ["-c", f'source "$0"; {_DEFINED}', "./orders.sh"],
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


@needs_bash
def test_example_5_exits_2_on_a_usage_error(tmp_path):
    # shell-structure.md section 10: 2 is the exit status for usage errors
    (tmp_path / "orders.sh").write_text(_example_5(), encoding="utf-8")
    proc = _bash(tmp_path, "orders.sh")
    assert proc.returncode == 2, proc.stdout + proc.stderr
    assert proc.stdout == ""
    assert proc.stderr.startswith("usage: orders.sh <order_id>"), proc.stderr


# --- examples/powershell.md: the Pester test -----------------------------------

# Stand-ins for the Pester 5 commands the example uses (Pester is not a test
# dependency), run in Pester 5's two phases. Discovery runs the test file
# once: Describe runs its body, while BeforeAll and It only record theirs.
# The run phase then dot-sources each block's BeforeAll bodies into a scope
# of the block's own, which its It bodies run under, so what the file
# defines outside BeforeAll and It is gone by then, as in Pester 5. The
# stand-in loads nothing itself: Get-Order exists only if the example's
# BeforeAll loads it.
# Mock makes a command of the mocked name that runs the mock's body, as
# Pester's alias to its bootstrap function does: neither touches
# $LASTEXITCODE. Each It runs once per state the session can be in before
# it: no native command run yet (unset), an earlier one failed (1) or passed
# (0). Before each It, curl is a function that throws, so an unmocked call
# fails the test instead of reaching the network. Should records what it
# checked, so the test can see which outcomes the It blocks cover.
_PESTER = r"""param([string]$Tests)
$ErrorActionPreference = 'Stop'
$global:StandIn = @{ Block = $null; Checks = @() }

function New-Block { @{ Setup = @(); Tests = @(); Blocks = @() } }

function BeforeAll([scriptblock]$Setup) {
    $global:StandIn.Block.Setup += $Setup
}

function It([string]$Name, [scriptblock]$Test) {
    $global:StandIn.Block.Tests += @{ Name = $Name; Test = $Test }
}

function Describe([string]$Name, [scriptblock]$Fixture) {
    $parent = $global:StandIn.Block
    $global:StandIn.Block = New-Block
    $parent.Blocks += $global:StandIn.Block
    try { & $Fixture } finally { $global:StandIn.Block = $parent }
}

function Mock([string]$CommandName, [scriptblock]$MockWith) {
    Set-Item -Path "function:global:$CommandName" -Value $MockWith
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
                $message = $_.Exception.Message
                if ($message -notlike $ExpectedMessage) {
                    throw "threw '$message', not '$ExpectedMessage'"
                }
                $global:StandIn.Checks += "Throw '$message'"
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
            $global:StandIn.Checks += "BeOfType [$type]"
            return
        }
        throw 'this stand-in knows only -BeOfType and -Throw'
    }
}

function Invoke-Block($Block) {
    foreach ($setup in $Block.Setup) { . $setup }
    foreach ($test in $Block.Tests) {
        foreach ($state in 'unset', '1', '0') { Invoke-Test $test $state }
    }
    foreach ($child in $Block.Blocks) { Invoke-Block $child }
}

function Invoke-Test($Test, [string]$State) {
    Set-Item -Path function:global:curl -Value { throw 'curl ran without a mock' }
    if ($State -eq 'unset') {
        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
    } else {
        $global:LASTEXITCODE = [int]$State
    }
    $global:StandIn.Checks = @()
    try {
        & $Test.Test
        "PASS [$State] $($Test.Name) :: $($global:StandIn.Checks -join '; ')"
    } catch {
        "FAIL [$State] $($Test.Name) :: $_"
    }
}

$root = New-Block
$global:StandIn.Block = $root
& $Tests
Invoke-Block $root
"""


@pytest.mark.skipif(PWSH is None, reason="runs the example under pwsh")
def test_pester_example_passes_whatever_lastexitcode_the_session_holds(tmp_path):
    text = (EXAMPLES / "powershell.md").read_text(encoding="utf-8")
    code, tests = _fenced(text, "powershell")
    names = re.findall(r"(?m)^\s*It '([^']*)'", tests)
    assert names, "the Pester block has no It"
    # The example's BeforeAll loads Get-Order.ps1 from the test file's own
    # folder; the stand-in lives elsewhere.
    src, drive = tmp_path / "src", tmp_path / "pester" / "drive.ps1"
    src.mkdir()
    drive.parent.mkdir()
    drive.write_text(_PESTER, encoding="utf-8")
    (src / "Get-Order.ps1").write_text(code, encoding="utf-8")
    tests_ps1 = src / "Get-Order.Tests.ps1"
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
    assert not re.search(r"(?m)^FAIL", proc.stdout), proc.stdout
    passed = re.findall(r"(?m)^PASS \[(unset|1|0)\] (.*) :: (.*)$", proc.stdout)
    assert sorted((state, name) for state, name, _ in passed) == sorted(
        (state, name) for state in ("unset", "1", "0") for name in names
    ), proc.stdout
    # Each It checks something, and together they check both outcomes: the
    # typed object from the payload, and Get-Order's throw on a failed curl.
    checks = [check for _, _, check in passed]
    assert all(checks), proc.stdout
    assert any(c.startswith("BeOfType") for c in checks), proc.stdout
    assert any(
        re.search(r"Throw 'order service returned exit code [1-9]\d* for o1'", c)
        for c in checks
    ), proc.stdout
