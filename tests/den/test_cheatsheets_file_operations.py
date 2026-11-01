"""cheatsheets/python/file-operations.py: the recipes do what their docstrings say.

The sheet's name has a hyphen, so it is loaded from its path, not imported.
"""

import importlib.util
import os
import re
import shutil
import stat
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


@pytest.mark.parametrize(
    ("encoding", "data"),
    [
        # A BOM came back at the start of every part: 23 bytes became 29.
        ("utf-8-sig", "alpha\r\nbeta\r\ngamma\r\n".encode("utf-8-sig")),
        # NEC row 13's 0x8790 decodes to U+2252, which cp932 encodes as 0x81E0.
        ("cp932", b"\x87\x90 nec\r\n" + "ログ 2\r\n".encode("cp932")),
    ],
    ids=["utf-8-sig", "cp932-nec"],
)
def test_split_then_merge_does_not_reencode(fileops, tmp_path, encoding, data):
    # Every part was decoded and encoded again, which is not the identity.
    src = tmp_path / "src.txt"
    src.write_bytes(data)
    parts = fileops.split_by_lines(
        src, lines_per_chunk=1, out_dir=tmp_path / "parts", encoding=encoding
    )
    assert len(parts) == data.count(b"\n")
    merged = tmp_path / "merged.txt"
    fileops.merge_files(parts, merged)
    assert merged.read_bytes() == data


@pytest.mark.parametrize("encoding", ["utf-16", "UTF-16-LE", "utf_32"])
def test_split_by_lines_refuses_utf16_and_utf32(fileops, tmp_path, encoding):
    # Their line break is not the byte 0x0A. Decoded and encoded again, every
    # part got a BOM of its own: 36 bytes of UTF-16 came back as 40.
    src = tmp_path / "src.txt"
    src.write_bytes("alpha\nbeta\n".encode(encoding))
    with pytest.raises(ValueError, match="0x0A"):
        fileops.split_by_lines(
            src, lines_per_chunk=1, out_dir=tmp_path / "parts", encoding=encoding
        )
    assert not (tmp_path / "parts").exists()


@pytest.mark.parametrize("encoding", ["cp037", "cp500"])
def test_split_by_lines_refuses_ebcdic(fileops, tmp_path, encoding):
    # EBCDIC encodes "\n" as b"%" (0x25). With no 0x0A to cut at, the binary
    # split handed the whole file back as one part, without an error.
    src = tmp_path / "src.txt"
    src.write_bytes("alpha\nbeta\n".encode(encoding))
    with pytest.raises(ValueError, match="0x0A"):
        fileops.split_by_lines(
            src, lines_per_chunk=1, out_dir=tmp_path / "parts", encoding=encoding
        )
    assert not (tmp_path / "parts").exists()


@pytest.mark.parametrize("encoding", ["iso2022_kr", "ISO-2022-KR"])
def test_split_by_lines_refuses_iso2022_kr(fileops, tmp_path, encoding):
    # It encodes "\n" as 0x0A, but writes its ESC $ ) C declaration only once,
    # before the first Korean text: the second part, decoded on its own, gave
    # "beta GQ19>n" for "beta 한국어", without an error.
    src = tmp_path / "src.txt"
    src.write_bytes("alpha 한국어\nbeta 한국어\n".encode(encoding))
    with pytest.raises(ValueError, match="declares its character set once"):
        fileops.split_by_lines(
            src, lines_per_chunk=1, out_dir=tmp_path / "parts", encoding=encoding
        )
    assert not (tmp_path / "parts").exists()


def test_split_by_lines_keeps_cr_only_line_endings_in_one_part(fileops, tmp_path):
    # Only b"\n" is cut at. Read as text, a lone CR ended a line as well; a
    # classic Mac OS file has no 0x0A, so it stays whole, as the docstring says.
    data = b"one\rtwo\rthree\r"
    src = tmp_path / "mac.txt"
    src.write_bytes(data)
    parts = fileops.split_by_lines(src, lines_per_chunk=1, out_dir=tmp_path / "parts")
    assert [part.read_bytes() for part in parts] == [data]


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


@pytest.fixture
def umask_022():
    old = os.umask(0o022)
    yield
    os.umask(old)


def _mode_of(fd: int) -> int:
    return stat.S_IMODE(os.fstat(fd).st_mode)


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
def test_merge_files_never_copies_a_private_file_into_a_wider_one(
    fileops, tmp_path, monkeypatch, umask_022
):
    # The temp file was created 0o666 minus the umask (0o644) and got the
    # output's 0o600 only after the copy: every local user could read the
    # merged data meanwhile, and an fd opened then keeps reading after chmod.
    part = tmp_path / "part"
    part.write_bytes(b"secret\n")
    out = tmp_path / "merged"
    out.write_bytes(b"old\n")
    out.chmod(0o600)
    modes: list[int] = []
    real_copy = shutil.copyfileobj

    def copyfileobj(src, dst, length=0):
        modes.append(_mode_of(dst.fileno()))
        real_copy(src, dst, length)

    monkeypatch.setattr(shutil, "copyfileobj", copyfileobj)
    fileops.merge_files([part], out)
    assert modes == [0o600]
    assert out.read_bytes() == b"secret\n"
    assert stat.S_IMODE(out.stat().st_mode) == 0o600


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
def test_merge_files_keeps_a_wider_output_mode(fileops, tmp_path, umask_022):
    part = tmp_path / "part"
    part.write_bytes(b"x")
    out = tmp_path / "merged"
    out.write_bytes(b"old")
    out.chmod(0o664)
    fileops.merge_files([part], out)
    assert stat.S_IMODE(out.stat().st_mode) == 0o664


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


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
def test_atomic_write_never_writes_a_private_file_into_a_wider_one(
    fileops, tmp_path, monkeypatch, umask_022
):
    # The temp file was created 0o644 (umask 022) and only narrowed to the
    # target's 0o600 after the secret was written and fsynced.
    secret = tmp_path / "credentials.json"
    secret.write_text("old", encoding="utf-8")
    secret.chmod(0o600)
    modes: list[int] = []
    real_fsync = os.fsync

    def fsync(fd: int) -> None:
        if stat.S_ISREG(os.fstat(fd).st_mode):
            modes.append(_mode_of(fd))
        real_fsync(fd)

    monkeypatch.setattr(os, "fsync", fsync)
    fileops.atomic_write(secret, '{"token": "s3cret"}')
    assert modes == [0o600]
    assert stat.S_IMODE(secret.stat().st_mode) == 0o600


# --- split_by_size + split_by_lines: the parts of a private file ---------------

SECRET = b"secret-1\nsecret-2\nsecret-3\n"
SPLITS = [  # each cuts SECRET into one part per line
    ("split_by_size", {"chunk_bytes": 9}),
    ("split_by_lines", {"lines_per_chunk": 1}),
]
SPLIT_IDS = [recipe for recipe, _ in SPLITS]


def _modes_while_written(directory: Path, call) -> dict[str, set[int]]:
    """Run ``call``; map each file it writes in ``directory`` to its modes then."""
    modes: dict[str, set[int]] = {}

    def profile(frame, event, arg):
        # A file object's write method, before the bytes go in.
        if event != "c_call" or getattr(arg, "__name__", None) != "write":
            return
        target = getattr(arg, "__self__", None)
        name = getattr(target, "name", None)
        if isinstance(name, (str, os.PathLike)) and Path(name).parent == directory:
            modes.setdefault(Path(name).name, set()).add(_mode_of(target.fileno()))

    sys.setprofile(profile)
    try:
        call()
    finally:
        sys.setprofile(None)
    return modes


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
@pytest.mark.parametrize(
    "leftover", [False, True], ids=["new-parts", "over-a-0o666-part"]
)
@pytest.mark.parametrize(("recipe", "kwargs"), SPLITS, ids=SPLIT_IDS)
def test_split_never_writes_a_private_file_into_a_wider_part(
    fileops, tmp_path, umask_022, recipe, kwargs, leftover
):
    # Every part was written with Path.write_bytes: a new one got 0o666 minus
    # the umask (0o644) and an old one kept its mode, so every local user
    # could read the pieces of a 0o600 file, next to it by default.
    src = tmp_path / "private.log"
    src.write_bytes(SECRET)
    src.chmod(0o600)
    out = tmp_path / "parts"
    out.mkdir()
    if leftover:
        old = out / "private.part0001.log"
        old.write_bytes(b"a longer part from an earlier run\n")
        old.chmod(0o666)
    parts: list[Path] = []
    modes = _modes_while_written(
        out, lambda: parts.extend(getattr(fileops, recipe)(src, out_dir=out, **kwargs))
    )
    names = [f"private.part{index:04d}.log" for index in range(3)]
    assert [part.name for part in parts] == names
    assert modes == {name: {0o600} for name in names}
    assert [stat.S_IMODE(part.stat().st_mode) for part in parts] == [0o600] * 3
    assert b"".join(part.read_bytes() for part in parts) == SECRET


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX permission bits")
@pytest.mark.parametrize(
    ("source_mode", "part_mode"),
    [(0o640, 0o640), (0o444, 0o644)],
    ids=["group-readable", "read-only"],
)
@pytest.mark.parametrize(("recipe", "kwargs"), SPLITS, ids=SPLIT_IDS)
def test_split_parts_take_the_source_permission_bits(
    fileops, tmp_path, umask_022, recipe, kwargs, source_mode, part_mode
):
    # A part takes the source's bits, as shutil.copy gives its copy, but
    # stays writable for its owner: parts of a read-only source made
    # read-only would stop the next run at the first part.
    src = tmp_path / "data.log"
    src.write_bytes(SECRET)
    src.chmod(source_mode)
    out = tmp_path / "parts"
    for _ in range(2):  # the second run replaces the parts of the first
        parts = getattr(fileops, recipe)(src, out_dir=out, **kwargs)
    assert [stat.S_IMODE(part.stat().st_mode) for part in parts] == [part_mode] * 3
    assert b"".join(part.read_bytes() for part in parts) == SECRET


# --- what the 0o600 notes promise ---------------------------------------------


def _sentences(doc: str | None) -> list[str]:
    assert doc is not None
    return re.split(r"(?<=\.)\s+(?=[A-Z`])", " ".join(doc.split()))


@pytest.mark.parametrize(
    ("recipe", "posix"),
    [
        ("merge_files", "On POSIX, over an existing ``output`` the temp file is 0o600"),
        ("atomic_write", "On POSIX, over an existing file the temp file is 0o600"),
        ("split_by_size", "On POSIX each part is created 0o600"),
        ("split_by_lines", "On POSIX each part is created 0o600"),
    ],
    ids=["merge_files", "atomic_write", "split_by_size", "split_by_lines"],
)
def test_private_file_notes_say_that_the_0o600_promise_is_posix_only(
    fileops, recipe, posix
):
    # Each creates its temp file or part 0o600, but on Windows os.open's
    # 0o600 only keeps it from being read-only: the ACL it inherits from its
    # directory decides who can read it, and os.replace keeps that ACL. The
    # merge_files and atomic_write notes promised on every platform that
    # private data never sits in a wider file. The promise has to sit in a
    # sentence that names POSIX and not Windows.
    sentences = _sentences(getattr(fileops, recipe).__doc__)
    promise = [sentence for sentence in sentences if posix in sentence]
    assert len(promise) == 1, (posix, sentences)
    assert "Windows" not in promise[0], promise[0]
    assert any("Windows has no such guarantee" in s for s in sentences), sentences
    assert any("ACL" in s for s in sentences), sentences


def test_atomic_write_note_says_that_the_directory_fsync_is_posix_only(fileops):
    # The directory is fsynced only when os.name == "posix", but the note said
    # "fsynced before the rename and the directory after it" for every
    # platform. The crash promise rests on the temp file's fsync alone.
    sentences = _sentences(fileops.atomic_write.__doc__)
    directory = [s for s in sentences if "fsync" in s and "directory" in s]
    assert len(directory) == 1, sentences
    assert directory[0].startswith("On POSIX the directory is fsynced"), directory
    assert "Windows cannot open a directory to fsync it" in directory[0], directory
    crash = [s for s in sentences if "never an empty file" in s]
    assert len(crash) == 1, sentences
    assert "directory" not in crash[0], crash
