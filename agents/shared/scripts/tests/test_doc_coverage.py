"""Subprocess tests for doc-coverage.py.

Invoked as a child process: the contract under test is the CLI output
line `<file>:<line>:<kind>:<name>:<status>` and the exit code. Each test
builds a tiny source file and asserts the HAS_DOC / NO_DOC verdict and
the visibility filtering for that language.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "doc-coverage.py"


def run(file: Path) -> subprocess.CompletedProcess[str]:
    """Run doc-coverage.py on `file`; return the completed process."""
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


# ---------- Python ----------


def test_python_documented_function_has_doc(tmp_path: Path) -> None:
    f = write(
        tmp_path, "m.py", 'def widget():\n    """Do the thing."""\n    return 1\n'
    )
    proc = run(f)
    assert proc.returncode == 0, proc.stderr
    assert ":function:widget:HAS_DOC" in proc.stdout


def test_python_undocumented_function_no_doc(tmp_path: Path) -> None:
    f = write(tmp_path, "m.py", "def widget():\n    return 1\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":function:widget:NO_DOC" in proc.stdout


def test_python_private_function_skipped(tmp_path: Path) -> None:
    f = write(tmp_path, "m.py", "def _helper():\n    return 1\n")
    proc = run(f)
    assert proc.returncode == 0
    assert "_helper" not in proc.stdout


def test_python_dunder_method_reported(tmp_path: Path) -> None:
    f = write(
        tmp_path,
        "m.py",
        "class CustomerOrder:\n"
        '    """An order."""\n'
        "    def __init__(self):\n"
        "        pass\n",
    )
    proc = run(f)
    assert proc.returncode == 0
    # __init__ is treated as public (part of the contract) and undocumented.
    assert "CustomerOrder.__init__:NO_DOC" in proc.stdout
    assert ":class:CustomerOrder:HAS_DOC" in proc.stdout


def test_python_single_underscore_method_skipped(tmp_path: Path) -> None:
    f = write(
        tmp_path,
        "m.py",
        "class CustomerOrder:\n"
        '    """An order."""\n'
        "    def _internal(self):\n"
        "        pass\n",
    )
    proc = run(f)
    assert proc.returncode == 0
    assert "_internal" not in proc.stdout


def test_python_syntax_error_reports_parse_error(tmp_path: Path) -> None:
    f = write(tmp_path, "m.py", "def broken(:\n")
    proc = run(f)
    assert proc.returncode == 0
    assert "parse_error" in proc.stdout


# ---------- Shell ----------


def test_shell_function_with_comment_has_doc(tmp_path: Path) -> None:
    f = write(tmp_path, "s.sh", "# Greet the user.\ngreet() {\n  echo hi\n}\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":function:greet:HAS_DOC" in proc.stdout


def test_shell_function_without_comment_no_doc(tmp_path: Path) -> None:
    f = write(tmp_path, "s.sh", "greet() {\n  echo hi\n}\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":function:greet:NO_DOC" in proc.stdout


# ---------- TypeScript ----------


def test_ts_exported_function_jsdoc_detected(tmp_path: Path) -> None:
    f = write(
        tmp_path,
        "m.ts",
        "/** Adds two numbers. */\n"
        "export function add(a: number, b: number): number {\n"
        "  return a + b;\n"
        "}\n",
    )
    proc = run(f)
    assert proc.returncode == 0
    assert ":function:add:HAS_DOC" in proc.stdout


def test_ts_control_flow_keyword_not_reported_as_method(tmp_path: Path) -> None:
    f = write(
        tmp_path,
        "m.ts",
        "export class Service {\n"
        "  run(): void {\n"
        "    if (true) {\n"
        "      return;\n"
        "    }\n"
        "  }\n"
        "}\n",
    )
    proc = run(f)
    assert proc.returncode == 0
    # `if` must not be mistaken for a method name.
    assert "Service.if" not in proc.stdout
    assert "Service.run" in proc.stdout


# ---------- Go ----------


def test_go_exported_func_with_doc_has_doc(tmp_path: Path) -> None:
    f = write(
        tmp_path,
        "m.go",
        "// Widget builds a widget.\nfunc Widget() int {\n\treturn 1\n}\n",
    )
    proc = run(f)
    assert proc.returncode == 0
    assert ":function:Widget:HAS_DOC" in proc.stdout


def test_go_exported_func_without_doc_no_doc(tmp_path: Path) -> None:
    f = write(tmp_path, "m.go", "func Widget() int {\n\treturn 1\n}\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":function:Widget:NO_DOC" in proc.stdout


def test_go_unexported_func_skipped(tmp_path: Path) -> None:
    f = write(tmp_path, "m.go", "func helper() int {\n\treturn 1\n}\n")
    proc = run(f)
    assert proc.returncode == 0
    assert "helper" not in proc.stdout


# ---------- Rust ----------


def test_rust_pub_fn_with_doc_has_doc(tmp_path: Path) -> None:
    f = write(
        tmp_path, "m.rs", "/// Adds two numbers.\npub fn add() -> i32 {\n    1\n}\n"
    )
    proc = run(f)
    assert proc.returncode == 0
    assert ":function:add:HAS_DOC" in proc.stdout


def test_rust_pub_fn_without_doc_no_doc(tmp_path: Path) -> None:
    f = write(tmp_path, "m.rs", "pub fn add() -> i32 {\n    1\n}\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":function:add:NO_DOC" in proc.stdout


def test_rust_private_fn_skipped(tmp_path: Path) -> None:
    f = write(tmp_path, "m.rs", "fn helper() -> i32 {\n    1\n}\n")
    proc = run(f)
    assert proc.returncode == 0
    assert "helper" not in proc.stdout


# ---------- Java (exercises the block-comment fix) ----------


def test_java_public_class_with_javadoc_has_doc(tmp_path: Path) -> None:
    f = write(tmp_path, "Widget.java", "/** A widget. */\npublic class Widget {\n}\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":class:Widget:HAS_DOC" in proc.stdout


def test_java_public_class_without_javadoc_no_doc(tmp_path: Path) -> None:
    f = write(tmp_path, "Widget.java", "public class Widget {\n}\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":class:Widget:NO_DOC" in proc.stdout


def test_java_public_method_with_multiline_javadoc_has_doc(tmp_path: Path) -> None:
    f = write(
        tmp_path,
        "Widget.java",
        "public class Widget {\n"
        "    /**\n"
        "     * Builds it.\n"
        "     */\n"
        "    public int build() {\n"
        "        return 1;\n"
        "    }\n"
        "}\n",
    )
    proc = run(f)
    assert proc.returncode == 0
    assert ":method:Widget.build:HAS_DOC" in proc.stdout


# ---------- C# ----------


def test_csharp_public_class_with_doc_has_doc(tmp_path: Path) -> None:
    f = write(
        tmp_path,
        "Widget.cs",
        "/// <summary>A widget.</summary>\npublic class Widget {\n}\n",
    )
    proc = run(f)
    assert proc.returncode == 0
    assert ":class:Widget:HAS_DOC" in proc.stdout


def test_csharp_public_class_without_doc_no_doc(tmp_path: Path) -> None:
    f = write(tmp_path, "Widget.cs", "public class Widget {\n}\n")
    proc = run(f)
    assert proc.returncode == 0
    assert ":class:Widget:NO_DOC" in proc.stdout


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
