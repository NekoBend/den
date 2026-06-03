"""Subprocess tests for verify-imports.py.

Invoked as a child process: the contract under test is the CLI output
line `<file>:<line>:<kind>:<target>:<status>[:<details>]` and the exit
code. Verification that depends on external toolchains (go list, cargo,
node_modules) is exercised only where the environment makes the outcome
deterministic; ambiguous cases assert the UNVERIFIED fallback instead.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "verify-imports.py"


def run(file: Path) -> subprocess.CompletedProcess[str]:
    """Run verify-imports.py on `file`; return the completed process."""
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(file)],
        capture_output=True,
        text=True,
        check=False,
    )


def write(root: Path, rel: str, body: str) -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path


def fields(line: str) -> list[str]:
    """Split an output line into its colon-separated fields (max-split aware)."""
    return line.split(":")


# ---------- Python ----------


def test_python_stdlib_import_is_ok(tmp_path: Path) -> None:
    f = write(tmp_path, "m.py", "import os\nimport sys\n")
    proc = run(f)
    assert proc.returncode == 0, proc.stderr
    lines = [ln for ln in proc.stdout.splitlines() if ln]
    assert any(":import_module:os:OK" in ln for ln in lines)
    assert any(":import_module:sys:OK" in ln for ln in lines)


def test_python_unknown_module_is_missing(tmp_path: Path) -> None:
    f = write(tmp_path, "m.py", "import totally_not_a_real_module_xyz\n")
    proc = run(f)
    assert proc.returncode == 0
    assert "MISSING" in proc.stdout
    assert "totally_not_a_real_module_xyz" in proc.stdout


def test_python_relative_import_is_unverified(tmp_path: Path) -> None:
    f = write(tmp_path, "m.py", "from . import sibling\n")
    proc = run(f)
    assert proc.returncode == 0
    assert "UNVERIFIED" in proc.stdout
    assert "relative import" in proc.stdout


def test_python_from_import_stdlib_ok(tmp_path: Path) -> None:
    f = write(tmp_path, "m.py", "from pathlib import Path\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":from_import:pathlib:OK" in proc.stdout


# ---------- Shell ----------


def test_shell_source_existing_file_ok(tmp_path: Path) -> None:
    write(tmp_path, "helper.sh", "echo hi\n")
    f = write(tmp_path, "main.sh", "source ./helper.sh\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":source:./helper.sh:OK" in proc.stdout


def test_shell_source_missing_file_is_missing(tmp_path: Path) -> None:
    f = write(tmp_path, "main.sh", ". ./not_here.sh\n")
    proc = run(f)
    assert proc.returncode == 0
    assert "MISSING" in proc.stdout
    assert "not_here.sh" in proc.stdout


# ---------- TS local imports ----------


def test_ts_local_relative_import_resolves(tmp_path: Path) -> None:
    write(tmp_path, "util.ts", "export const x = 1;\n")
    f = write(tmp_path, "main.ts", "import { x } from './util';\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":./util:OK" in proc.stdout


def test_ts_node_builtin_is_ok(tmp_path: Path) -> None:
    f = write(tmp_path, "main.ts", "import * as fs from 'fs';\n")
    proc = run(f)
    assert proc.returncode == 0
    assert "fs:OK" in proc.stdout


# ---------- Go (needs the go toolchain) ----------


@pytest.mark.skipif(shutil.which("go") is None, reason="go toolchain not installed")
def test_go_stdlib_single_import_ok(tmp_path: Path) -> None:
    f = write(
        tmp_path,
        "m.go",
        'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println() }\n',
    )
    proc = run(f)
    assert proc.returncode == 0, proc.stderr
    assert ":import_module:fmt:OK" in proc.stdout


@pytest.mark.skipif(shutil.which("go") is None, reason="go toolchain not installed")
def test_go_import_block_each_path_extracted(tmp_path: Path) -> None:
    f = write(tmp_path, "m.go", 'package main\n\nimport (\n\t"fmt"\n\t"os"\n)\n')
    proc = run(f)
    assert proc.returncode == 0
    out = proc.stdout
    assert ":import_module:fmt:OK" in out
    assert ":import_module:os:OK" in out


@pytest.mark.skipif(shutil.which("go") is None, reason="go toolchain not installed")
def test_go_unknown_package_missing(tmp_path: Path) -> None:
    f = write(tmp_path, "m.go", 'package main\n\nimport "totally/not/a/pkg"\n')
    proc = run(f)
    assert proc.returncode == 0
    assert "MISSING" in proc.stdout


# ---------- Rust (Cargo.toml parsing, no toolchain needed) ----------


def test_rust_std_use_is_ok(tmp_path: Path) -> None:
    f = write(tmp_path, "m.rs", "use std::collections::HashMap;\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":use:std::collections::HashMap:OK" in proc.stdout


def test_rust_external_crate_unverified_without_cargo(tmp_path: Path) -> None:
    f = write(tmp_path, "m.rs", "use serde::Serialize;\n")
    proc = run(f)
    assert proc.returncode == 0
    assert "UNVERIFIED" in proc.stdout
    assert "Cargo.toml" in proc.stdout


def test_rust_external_crate_ok_with_cargo(tmp_path: Path) -> None:
    write(tmp_path, "Cargo.toml", '[dependencies]\nserde = "1"\n')
    f = write(tmp_path, "src/m.rs", "use serde::Serialize;\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":use:serde::Serialize:OK" in proc.stdout


# ---------- Java (pom/gradle parsing, no toolchain needed) ----------


def test_java_jdk_import_is_ok(tmp_path: Path) -> None:
    f = write(tmp_path, "M.java", "import java.util.List;\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":import_module:java.util.List:OK" in proc.stdout


def test_java_unmatched_import_unverified_without_manifest(tmp_path: Path) -> None:
    f = write(tmp_path, "M.java", "import com.example.thing.Widget;\n")
    proc = run(f)
    assert proc.returncode == 0
    assert "UNVERIFIED" in proc.stdout


def test_java_import_matched_to_pom_dependency(tmp_path: Path) -> None:
    write(
        tmp_path,
        "pom.xml",
        "<project><dependencies><dependency>"
        "<groupId>com.example</groupId>"
        "<artifactId>thing</artifactId>"
        "</dependency></dependencies></project>\n",
    )
    f = write(tmp_path, "src/M.java", "import com.example.thing.Widget;\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":import_module:com.example.thing.Widget:OK" in proc.stdout


# ---------- C# (.csproj parsing, no toolchain needed) ----------


def test_csharp_bcl_using_is_ok(tmp_path: Path) -> None:
    f = write(tmp_path, "M.cs", "using System.Text;\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":using:System.Text:OK" in proc.stdout


def test_csharp_unmatched_using_unverified_without_csproj(tmp_path: Path) -> None:
    f = write(tmp_path, "M.cs", "using Newtonsoft.Json;\n")
    proc = run(f)
    assert proc.returncode == 0
    assert "UNVERIFIED" in proc.stdout


def test_csharp_using_matched_to_package_reference(tmp_path: Path) -> None:
    write(
        tmp_path,
        "app.csproj",
        "<Project><ItemGroup>"
        '<PackageReference Include="Newtonsoft.Json" Version="13.0.0" />'
        "</ItemGroup></Project>\n",
    )
    f = write(tmp_path, "src/M.cs", "using Newtonsoft.Json;\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":using:Newtonsoft.Json:OK" in proc.stdout


# ---------- errors ----------


def test_unrecognized_extension_exits_1(tmp_path: Path) -> None:
    f = write(tmp_path, "data.txt", "hello\n")
    proc = run(f)
    assert proc.returncode == 1
    assert "unrecognized extension" in proc.stderr


def test_missing_file_exits_1(tmp_path: Path) -> None:
    proc = run(tmp_path / "nope.py")
    assert proc.returncode == 1
    assert "file not found" in proc.stderr
