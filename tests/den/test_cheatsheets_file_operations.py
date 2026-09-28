"""cheatsheets/python/file-operations.py: the recipes do what their docstrings say.

The sheet's name has a hyphen, so it is loaded from its path, not imported.
"""

import importlib.util
import os
import shutil
import sys
from pathlib import Path
from types import ModuleType

import pytest

SHEET = Path(__file__).resolve().parents[2] / "cheatsheets/python/file-operations.py"


@pytest.fixture(scope="module")
def fileops() -> ModuleType:
    spec = importlib.util.spec_from_file_location("cheatsheet_file_operations", SHEET)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --- split_by_lines + merge_files -------------------------------------------


@pytest.mark.parametrize("newline", [b"\r\n", b"\n"], ids=["crlf", "lf"])
def test_split_then_merge_rebuilds_the_file_byte_for_byte(fileops, tmp_path, newline):
    # Reading with universal newlines and writing with the platform default
    # turned CRLF into LF on POSIX (and LF into CRLF on Windows).
    data = newline.join([b"a,b", b"1,2", b"3,4", b"5,6", b""])
    src = tmp_path / "data.csv"
    src.write_bytes(data)
    parts = fileops.split_by_lines(src, lines_per_chunk=2, out_dir=tmp_path / "parts")
    assert len(parts) == 2
    merged = tmp_path / "merged.csv"
    fileops.merge_files(parts, merged)
    assert merged.read_bytes() == data


def test_split_by_lines_reads_the_given_encoding(fileops, tmp_path):
    # A cp932 (Shift-JIS) log raised UnicodeDecodeError: the encoding was
    # hard-coded to UTF-8.
    data = "ログ 1\r\nログ 2\r\nログ 3\r\n".encode("cp932")
    src = tmp_path / "app.log"
    src.write_bytes(data)
    parts = fileops.split_by_lines(
        src, lines_per_chunk=2, out_dir=tmp_path / "parts", encoding="cp932"
    )
    assert b"".join(part.read_bytes() for part in parts) == data


# --- write_csv ---------------------------------------------------------------


def test_write_csv_with_no_rows_rewrites_the_header(fileops, tmp_path):
    # An empty report used to return early and leave yesterday's rows in place.
    out = tmp_path / "report.csv"
    fileops.write_csv(out, [{"k": "old"}])
    fileops.write_csv(out, [], fieldnames=["k"])
    assert fileops.read_csv(out) == []
    assert out.read_text(encoding="utf-8").splitlines() == ["k"]


def test_write_csv_with_neither_rows_nor_fieldnames_raises(fileops, tmp_path):
    out = tmp_path / "report.csv"
    out.write_bytes(b"k\r\nold\r\n")
    with pytest.raises(ValueError, match="fieldnames"):
        fileops.write_csv(out, [])
    assert out.read_bytes() == b"k\r\nold\r\n"


# --- merge_files ---------------------------------------------------------------


def test_merge_files_refuses_an_output_that_is_also_an_input(fileops, tmp_path):
    # With the output after an input, the reader chased the writer until the
    # disk was full. With the output FIRST (as here) the old code truncated it
    # before reading it: silent data loss, and no hang for this test to wait on.
    out = tmp_path / "app.log"
    out.write_bytes(b"previous run\n")
    part = tmp_path / "app-2026-09-01.log"
    part.write_bytes(b"new part\n")
    with pytest.raises(shutil.SameFileError):
        fileops.merge_files([out, part], out)
    assert out.read_bytes() == b"previous run\n"


def test_merge_files_leaves_the_old_output_alone_when_it_fails(fileops, tmp_path):
    out = tmp_path / "merged.bin"
    out.write_bytes(b"previous run\n")
    good = tmp_path / "a.bin"
    good.write_bytes(b"A" * 10)
    unreadable = tmp_path / "a-directory"
    unreadable.mkdir()
    with pytest.raises((IsADirectoryError, PermissionError)):  # POSIX, Windows
        fileops.merge_files([good, unreadable], out)
    assert out.read_bytes() == b"previous run\n"
    assert sorted(p.name for p in tmp_path.iterdir()) == [
        "a-directory",
        "a.bin",
        "merged.bin",
    ]


# --- atomic_write --------------------------------------------------------------


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
def test_atomic_write_keeps_the_file_mode(fileops, tmp_path):
    # mkstemp creates 0o600 and os.replace kept it: a 0o644 config became
    # unreadable to every other user and service.
    conf = tmp_path / "app.conf"
    conf.write_text("x", encoding="utf-8")
    conf.chmod(0o644)
    fileops.atomic_write(conf, "y")
    assert conf.read_text(encoding="utf-8") == "y"
    assert conf.stat().st_mode & 0o777 == 0o644


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
def test_atomic_write_creates_a_new_file_like_open_does(fileops, tmp_path):
    reference = tmp_path / "reference"
    with reference.open("x", encoding="utf-8"):
        pass
    new = tmp_path / "new.conf"
    fileops.atomic_write(new, "y")
    assert new.stat().st_mode & 0o777 == reference.stat().st_mode & 0o777


def test_atomic_write_writes_through_a_symlink(fileops, tmp_path):
    target = tmp_path / "dotfiles_repo_bashrc"
    target.write_text("old", encoding="utf-8")
    link = tmp_path / "bashrc"
    try:
        link.symlink_to(target)
    except OSError:
        pytest.skip("creating symlinks is not permitted here")
    fileops.atomic_write(link, "new")
    assert link.is_symlink()
    assert target.read_text(encoding="utf-8") == "new"


def test_atomic_write_fsyncs_before_it_replaces(fileops, tmp_path, monkeypatch):
    calls: list[str] = []
    real_fsync = os.fsync
    real_replace = os.replace

    def fsync(fd: int) -> None:
        calls.append("fsync")
        real_fsync(fd)

    def replace(src: str, dst: str) -> None:
        calls.append("replace")
        real_replace(src, dst)

    monkeypatch.setattr(os, "fsync", fsync)
    monkeypatch.setattr(os, "replace", replace)
    fileops.atomic_write(tmp_path / "state.json", "{}")
    assert calls[:2] == ["fsync", "replace"]
