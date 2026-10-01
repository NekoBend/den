"""Subprocess tests for find-references.py.

The script lives one directory up. It is invoked as a child process
(not imported) because its filename contains a hyphen and because the
public contract under test is its CLI: argv in, stdout + exit code out.
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
    / "find-references.py"
)

# The scripts share their search plumbing through _common.py, which is importable
# (find-references.py itself is not: its filename has a hyphen).
sys.path.insert(0, str(SCRIPT.parent))

import _common  # ruff: ignore[module-import-not-at-top-of-file]
from _common import (  # ruff: ignore[module-import-not-at-top-of-file]
    parse_rg_line,
    parse_rg_output,
    resolve_tool,
    search_path,
)


def run(
    *args: str, cwd: Path | None = None, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    """Run find-references.py with `args`; return the completed process."""
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


@pytest.fixture
def backends(tmp_path_factory: pytest.TempPathFactory) -> list[dict[str, str] | None]:
    """The two environments a search must return the same files in.

    `None` keeps the ambient PATH, which must have ripgrep on it; the second
    replaces PATH with a directory holding nothing but a link to git, so the
    script cannot find rg and has to read the files itself. BOTH halves are
    asserted, because either one failing quietly turns every parity test into
    the same backend run twice.
    Dropping only the PATH entries that contain rg is not enough: where rg
    sits in /usr/bin that removes every other tool with it.

    The directory is a sibling of the test's own tmp_path, never inside it, so
    it cannot show up in the tree being searched.
    """
    assert shutil.which("rg") is not None, (
        "these parity tests need ripgrep on PATH: without it BOTH legs below "
        "run the walk fallback and the comparison proves nothing. Install it "
        "(apt-get install ripgrep / brew install ripgrep); CI installs it in "
        "the job that runs tests/agents."
    )
    bin_dir = tmp_path_factory.mktemp("no-rg-bin")
    # git stays reachable on both legs: inside a work tree it decides which
    # files are searched, and the two legs must search the same ones.
    link_git(bin_dir)
    env = dict(os.environ)
    env["PATH"] = str(bin_dir)
    assert shutil.which("rg", path=env["PATH"]) is None
    assert shutil.which("git", path=env["PATH"]) is not None
    return [None, env]


def link_git(bin_dir: Path) -> None:
    """Put the real git into `bin_dir` (a link, or a copy where links fail)."""
    git_exe = shutil.which("git")
    assert git_exe is not None, "these tests need git on PATH"
    link = bin_dir / Path(git_exe).name
    try:
        link.symlink_to(git_exe)
    except (OSError, NotImplementedError):  # Windows without privileges
        shutil.copy2(git_exe, link)


def git(repo: Path, *args: str) -> None:
    """Run a git command inside `repo`, raising on failure."""
    exe = shutil.which("git")
    assert exe is not None, "these tests build git repositories: install git"
    subprocess.run([exe, *args], cwd=repo, check=True, capture_output=True)


def rows(proc: subprocess.CompletedProcess[str], root: Path) -> list[str]:
    """Output lines with the `<root>/` prefix removed."""
    prefix = f"{root}{os.sep}"
    out = []
    for ln in proc.stdout.splitlines():
        assert ln.startswith(prefix), ln
        out.append(ln[len(prefix) :])
    return out


def counting_rg(bin_dir: Path) -> Path:
    """A `rg` in `bin_dir` that logs one line per run, then runs the real one.

    Returns the log file. git is linked next to it, so PATH=bin_dir is enough.
    """
    real = shutil.which("rg")
    assert real is not None, "this test needs ripgrep on PATH"
    log = bin_dir / "rg-runs.log"
    stub = bin_dir / "rg"
    stub.write_text(
        f'#!/bin/sh\necho run >> "{log}"\nexec "{real}" "$@"\n', encoding="utf-8"
    )
    stub.chmod(0o755)
    link_git(bin_dir)
    return log


def symlink_or_skip(link: Path, target: Path) -> None:
    """Create `link` -> `target`, skipping the test where that is not allowed."""
    try:
        link.symlink_to(target)
    except (OSError, NotImplementedError) as exc:  # Windows without privileges
        pytest.skip(f"symlinks unavailable: {exc}")


def run_bytes(
    *args: str, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[bytes]:
    """Run find-references.py capturing stdout as raw bytes.

    A POSIX file name is bytes, so a test that checks how a name is PRINTED
    cannot let subprocess decode the stream for it.
    """
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        check=False,
        env=env,
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


def test_def_finds_powershell_function(tmp_path: Path) -> None:
    # Verb-Noun names contain a hyphen; the pattern must still anchor on the
    # function keyword and the whole name, not the first \w+ run.
    write(tmp_path, "mod.ps1", "function Get-Widget {\n    param()\n}\n")
    proc = run("--def", "Get-Widget", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    lines = [ln for ln in proc.stdout.splitlines() if ln]
    assert len(lines) == 1
    file, lineno, kind, _context = lines[0].split(":", 3)
    assert file.endswith("mod.ps1")
    assert lineno == "1"
    assert kind == "def"


def test_uses_finds_powershell_call_sites(tmp_path: Path) -> None:
    write(tmp_path, "mod.psm1", "function Get-Widget {\n    param()\n}\n")
    write(tmp_path, "caller.ps1", "$w = Get-Widget\n")
    proc = run("--uses", "Get-Widget", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    out = proc.stdout
    assert "caller.ps1" in out


def test_in_reports_full_powershell_names(tmp_path: Path) -> None:
    # --in discovers definitions with a capturing group; the capture must not
    # stop at the hyphen (New-Wrapper reported as "New" made two symbols
    # sharing a verb indistinguishable).
    write(
        tmp_path,
        "mod.ps1",
        "function New-Wrapper {\n    param()\n}\nenum WidgetKind {\n    A\n}\n",
    )
    write(tmp_path, "caller.ps1", "New-Wrapper\n")
    proc = run("--in", str(tmp_path / "mod.ps1"), "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert "New-Wrapper" in proc.stdout
    assert "WidgetKind" in proc.stdout
    # Every line is `<file>:<line>:<kind>:<context>` and <file> is the absolute
    # path, so strip that prefix first instead of splitting the line blindly:
    # both the kind (`use:<owner>`) and the context can contain colons.
    prefix = f"{tmp_path}{os.sep}"
    rows: list[tuple[str, str]] = []
    for ln in proc.stdout.splitlines():
        if not ln:
            continue
        assert ln.startswith(prefix), ln
        name, _lineno, kind_and_context = ln[len(prefix) :].split(":", 2)
        rows.append((name, kind_and_context))
    assert [n for n, kc in rows if kc.startswith("def:")] == ["mod.ps1", "mod.ps1"]
    # The external call site is attributed to the whole Verb-Noun name, never
    # to the verb alone: `use:New` is the regression this test exists for.
    owners = [kc.split(":", 2)[1] for _n, kc in rows if kc.startswith("use:")]
    assert owners == ["New-Wrapper"], proc.stdout


# ---------- rg output parsing ----------


def test_rg_line_parser_reads_the_null_separated_format() -> None:
    # rg is run with --null and its stdout is read as bytes, so a record is
    # bytes: the path ends at the NUL and the only colon that matters is the
    # one after the line number. Parsed directly, since the ubuntu CI runners
    # cannot produce the Windows case.
    assert parse_rg_line(b"/repo/mod.py\x0012:def widget():") == (
        "/repo/mod.py",
        12,
        "def widget():",
    )
    # a colon inside the path is no longer ambiguous...
    assert parse_rg_line(b"/repo/a:b.py\x0012:widget()") == (
        "/repo/a:b.py",
        12,
        "widget()",
    )
    # ...neither is a Windows drive letter, which needs no special case now
    assert parse_rg_line(b"C:\\repo\\mod.py\x0012:def widget():") == (
        "C:\\repo\\mod.py",
        12,
        "def widget():",
    )
    # the content keeps every colon it had
    assert parse_rg_line(b"/repo/mod.py\x007:d = {'a': 1, 'b': 2}") == (
        "/repo/mod.py",
        7,
        "d = {'a': 1, 'b': 2}",
    )
    # a name that is not valid UTF-8 keeps its bytes (os.fsdecode round-trips)
    assert parse_rg_line(b"/repo/bad\xff.py\x001:widget()") == (
        os.fsdecode(b"/repo/bad\xff.py"),
        1,
        "widget()",
    )
    # ...while undecodable bytes in the CONTENT are replaced, as the walker's
    # reader does it
    assert parse_rg_line(b"/repo/mod.py\x001:wid\xffget()") == (
        "/repo/mod.py",
        1,
        "wid\ufffdget()",
    )


def test_rg_line_parser_rejects_junk() -> None:
    assert parse_rg_line(b"no separators here") is None
    assert parse_rg_line(b"/repo/mod.py:12:no null byte") is None
    assert parse_rg_line(b"/repo/mod.py\x00twelve:x") is None
    assert parse_rg_line(b"/repo/mod.py\x0012 no colon") is None


def test_rg_stream_parser_splits_records_on_the_record_newline_only() -> None:
    # Only the newline that ends a record ends a record. str.splitlines(),
    # which this replaced, also breaks on form feed, vertical tab, NEL, U+2028
    # and U+2029, and it split a path containing a newline in half.
    stream = (
        b"/repo/a.txt\x001:head \x0c tail\n"
        b"/repo/b\nc.txt\x002:x\n"
        b"/repo/d.txt\x003:sep \xe2\x80\xa8 here\n"
        b"/repo/e.txt\x004:vertical \x0b tab\n"
        b"/repo/bad\xff.py\x005:widget()\n"
    )
    assert parse_rg_output(stream) == [
        ("/repo/a.txt", 1, "head \x0c tail"),
        ("/repo/b\nc.txt", 2, "x"),
        ("/repo/d.txt", 3, "sep \u2028 here"),
        ("/repo/e.txt", 4, "vertical \x0b tab"),
        (os.fsdecode(b"/repo/bad\xff.py"), 5, "widget()"),
    ]
    # a stream with no trailing newline still yields its last record
    assert parse_rg_output(b"/repo/f.txt\x005:last") == [("/repo/f.txt", 5, "last")]
    assert parse_rg_output(b"") == []


# ---------- the two backends must see the same tree ----------


def test_the_ripgrep_backend_is_really_invoked(
    tmp_path: Path, tmp_path_factory: pytest.TempPathFactory
) -> None:
    # The `backends` fixture asserts rg is reachable on the ambient PATH; this
    # observes the call itself, which is the only direct evidence that the
    # first leg of every parity test runs ripgrep and not the fallback. A stub
    # `rg` records its argv, so the flags that keep the two backends in
    # agreement are pinned on the real command line too.
    if sys.platform == "win32":
        pytest.skip("the stub rg is a /bin/sh script")
    bin_dir = tmp_path_factory.mktemp("stub-rg-bin")
    record = bin_dir / "argv.txt"
    stub = bin_dir / "rg"
    stub.write_text(
        f'#!/bin/sh\nprintf "%s\\n" "$@" > "{record}"\nexit 1\n', encoding="utf-8"
    )
    stub.chmod(0o755)
    env = dict(os.environ)
    env["PATH"] = str(bin_dir)
    write(tmp_path, "mod.py", "def widget():\n    return 1\n")

    proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
    assert proc.returncode == 0, proc.stderr
    assert record.is_file(), "rg was on PATH but the script never ran it"
    argv = record.read_text(encoding="utf-8").splitlines()
    assert "--no-config" in argv, argv
    assert "--null" in argv, argv
    assert "--text" in argv, argv
    # rg is handed the file list itself, after `--`: the same list the
    # fallback reads, so neither ignore rules nor globs of rg's own apply
    files = argv[argv.index("--") + 1 :]
    assert files == [str(tmp_path / "mod.py")], argv


def test_root_under_a_skipped_directory_is_still_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # SKIP_DIRS applies BELOW the root; a checkout that happens to live under a
    # directory called build/ (or dist/, target/, out/) is not itself skipped.
    root = tmp_path / "build" / "proj"
    write(root, "mod.py", "def widget():\n    return 1\n")
    for env in backends:
        proc = run("--def", "widget", "--root", str(root), env=env)
        assert proc.returncode == 0, proc.stderr
        lines = [ln for ln in proc.stdout.splitlines() if ln]
        assert len(lines) == 1, proc.stdout
        assert lines[0].endswith("mod.py:1:def:def widget():"), proc.stdout


def test_in_a_git_repo_hidden_files_are_searched_and_ignored_ones_are_not(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # Inside a work tree both backends search what `git ls-files --cached
    # --others --exclude-standard` lists. A virtual environment under any
    # name (uv writes a `*` .gitignore into its own) and anything else the
    # user ignores used to be searched too: a uv venv called .4win alone put
    # 17,602 false hits into one check-broken-refs run. Hidden files are not
    # ignored, so .github/ is still searched, tracked or not.
    git(tmp_path, "init", "-q")
    write(tmp_path, ".gitignore", "ignored.py\n")
    write(tmp_path, "ignored.py", "widget()\n")
    write(tmp_path, ".4win/.gitignore", "*\n")
    write(tmp_path, ".4win/pyvenv.cfg", "home = /usr/bin\n")
    write(tmp_path, ".4win/Lib/site-packages/pkg.py", "widget()\n")
    write(tmp_path, ".github/workflows/ci.yml", "run: widget()\n")
    write(tmp_path, "tracked.py", "widget()\n")
    git(tmp_path, "add", "tracked.py")
    write(tmp_path, "untracked.py", "widget()\n")
    outputs = []
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        found = sorted(r.split(":", 1)[0] for r in rows(proc, tmp_path))
        assert found == [
            str(Path(".github", "workflows", "ci.yml")),
            "tracked.py",
            "untracked.py",
        ], proc.stdout
        outputs.append(proc.stdout)
    assert outputs[0] == outputs[1], outputs


def test_outside_git_a_virtualenv_of_any_name_is_not_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # Outside a work tree there is no .gitignore to go by, so a directory
    # holding a pyvenv.cfg - what marks a Python virtual environment,
    # whatever it is called - is skipped by both backends. Everything else,
    # hidden files included, is still searched.
    root = tmp_path / "proj"
    write(root, "env-3.12/pyvenv.cfg", "home = /usr/bin\n")
    write(root, "env-3.12/lib/python3.12/site-packages/pkg.py", "widget()\n")
    write(root, ".hidden/notes.txt", "widget()\n")
    write(root, "src/app.py", "widget()\n")
    outputs = []
    for env in backends:
        full = dict(os.environ if env is None else env)
        full["GIT_CEILING_DIRECTORIES"] = str(tmp_path)  # never a repo above
        proc = run("--uses", "widget", "--root", str(root), env=full)
        assert proc.returncode == 0, proc.stderr
        found = sorted(r.split(":", 1)[0] for r in rows(proc, root))
        assert found == [
            str(Path(".hidden", "notes.txt")),
            str(Path("src", "app.py")),
        ], proc.stdout
        outputs.append(proc.stdout)
    assert outputs[0] == outputs[1], outputs


def test_a_root_that_git_ignores_is_still_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # git lists nothing below an ignored directory, but a search the user
    # pointed there explicitly must not come back empty because of it.
    git(tmp_path, "init", "-q")
    write(tmp_path, ".gitignore", "generated/\n")
    write(tmp_path, "generated/api.py", "def widget():\n    pass\n")
    for env in backends:
        proc = run("--def", "widget", "--root", str(tmp_path / "generated"), env=env)
        assert proc.returncode == 0, proc.stderr
        assert rows(proc, tmp_path / "generated") == ["api.py:1:def:def widget():"]


def test_binary_files_are_searched_as_text_by_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # One policy on both sides: every regular file is searched as text (rg
    # gets --text, the walker decodes with errors="replace"). Letting each
    # backend detect binaries instead could only ever approximate the other -
    # rg decides per read buffer and can still print matches from before the
    # NUL it stops at - so the files hardest to reason about were exactly the
    # ones where the two disagreed. Both blobs below must be reported, with
    # identical output.
    (tmp_path / "early.bin").write_bytes(b"\x00\x00widget()\n")
    (tmp_path / "late.bin").write_bytes(b"x" * 20000 + b"\nwidget()\n" + b"\x00")
    write(tmp_path, "real.py", "widget()\n")
    outputs = []
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "early.bin" in proc.stdout, proc.stdout
        assert "late.bin" in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout
        outputs.append(sorted(proc.stdout.splitlines()))
    assert outputs[0] == outputs[1], outputs


def test_a_very_long_line_is_clamped_identically_by_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # Every regular file is searched as text, so a hit inside a minified
    # bundle or a blob would otherwise print a "line" megabytes long into the
    # caller's output. The clamp sits where the result line is formatted, so
    # both backends produce exactly the same clamped row.
    long_line = "x" * 2000 + " widget() " + "y" * 3000
    write(tmp_path, "bundle.min.js", long_line + "\n")
    write(tmp_path, "short.py", "widget()\n")
    expected = long_line[:300] + f" [...+{len(long_line) - 300} chars]"

    outputs = []
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        contexts = {}
        for ln in proc.stdout.splitlines():
            file, _lineno, _kind, context = ln.split(":", 3)
            contexts[Path(file).name] = context
        assert contexts["bundle.min.js"] == expected, contexts["bundle.min.js"][:120]
        # a short line keeps every character and gains no marker
        assert contexts["short.py"] == "widget()", contexts["short.py"]
        outputs.append(sorted(proc.stdout.splitlines()))
    assert outputs[0] == outputs[1], outputs


def test_undecodable_bytes_do_not_forge_a_match(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # ripgrep searches raw bytes, so `widget` does not occur in
    # b"wid\xffget()". Decoding with errors="ignore" deleted the 0xff and
    # made the fallback report a hit rg never sees; errors="replace" leaves a
    # U+FFFD in the way, which is not a word character, so the boundary
    # behaves the way rg's does.
    (tmp_path / "bad.txt").write_bytes(b"wid\xffget()\n")
    write(tmp_path, "real.py", "widget()\n")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "bad.txt" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout


def test_a_ripgrep_config_cannot_change_what_is_searched(
    tmp_path: Path,
    tmp_path_factory: pytest.TempPathFactory,
    backends: list[dict[str, str] | None],
) -> None:
    # RIPGREP_CONFIG_PATH would otherwise hand the rg backend --follow and
    # extra globs, putting files the walker never sees (here: a symlink out of
    # the tree) into the rg results on that machine alone. --no-config is in
    # the shared flag list; this pins the whole result against the walker with
    # such a config in place.
    config = tmp_path_factory.mktemp("rg-config") / "rgrc"
    config.write_text("--follow\n--text\n", encoding="utf-8")
    secret = tmp_path_factory.mktemp("outside") / "credentials"
    secret.write_text("widget = 'SENTINEL-SECRET'\n", encoding="utf-8")
    root = tmp_path / "repo"
    write(root, "real.py", "widget()\n")
    (root / "blob.bin").write_bytes(b"\x00\x00widget()\n")
    symlink_or_skip(root / "creds", secret)

    outputs = []
    for env in backends:
        full = dict(os.environ if env is None else env)
        full["RIPGREP_CONFIG_PATH"] = str(config)
        proc = run("--uses", "widget", "--root", str(root), env=full)
        assert proc.returncode == 0, proc.stderr
        assert "SENTINEL-SECRET" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout
        outputs.append(sorted(proc.stdout.splitlines()))
    assert outputs[0] == outputs[1], outputs


def test_a_colon_in_a_path_does_not_lose_the_hit(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # The rg backend used to split its output on colons, so a hit in `a:b.py`
    # was dropped there and reported by the walk fallback.
    try:
        write(tmp_path, "a:b.py", "widget()\n")
    except OSError as exc:  # Windows forbids ':' in a file name
        pytest.skip(f"cannot create a path containing a colon: {exc}")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "a:b.py" in proc.stdout, proc.stdout


def test_a_file_named_like_a_skipped_directory_is_not_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # A linked git worktree has a regular `.git` FILE holding a gitdir
    # pointer. rg's `-g !.git` excludes files as well as directories; the
    # walker pruned directory names only, so it alone searched this one.
    write(tmp_path, "worktree/.git", "gitdir: /elsewhere/.git/worktrees/x\nwidget()\n")
    write(tmp_path, "real.py", "widget()\n")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert ".git" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout


def test_control_characters_in_a_line_do_not_truncate_the_record(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # A form feed, a vertical tab or U+2028 inside a matching line used to cut
    # rg's record short (the walker never split on them), so the two backends
    # printed different context for the same hit.
    write(tmp_path, "odd.txt", "head \x0c mid \u2028 widget() \x0b tail\n")
    write(tmp_path, "real.py", "widget()\n")
    outputs = []
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        # split on the record separator only: the content holds characters
        # that str.splitlines() would break on here too.
        rows = [ln for ln in proc.stdout.split("\n") if ln]
        assert len(rows) == 2, rows
        assert any("\x0c" in ln and "\u2028" in ln and "\x0b" in ln for ln in rows), (
            rows
        )
        outputs.append(sorted(rows))
    assert outputs[0] == outputs[1], outputs


def test_a_newline_in_a_file_name_does_not_lose_the_hit(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # rg terminates the path with NUL, so a newline inside the NAME is data,
    # not a record boundary - but only if the stream is parsed as records.
    try:
        write(tmp_path, "new\nline.txt", "widget()\n")
    except OSError as exc:  # a filesystem that refuses the name
        pytest.skip(f"cannot create a file name containing a newline: {exc}")
    write(tmp_path, "real.py", "widget()\n")
    outputs = []
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "new\nline.txt" in proc.stdout, proc.stdout
        outputs.append(sorted(proc.stdout.split("\n")))
    assert outputs[0] == outputs[1], outputs


def test_a_non_utf8_file_name_is_printed_identically_by_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # A POSIX name need not be valid UTF-8. rg's stream used to be decoded as
    # text, so the rg backend printed the name with U+FFFD in it while the
    # walker printed the real bytes: one file, two spellings, and neither
    # usable to open it.
    if sys.platform == "win32":
        pytest.skip("Windows file names are UTF-16, not bytes")
    try:
        write(tmp_path, os.fsdecode(b"bad\xff.py"), "widget()\n")
    except OSError as exc:  # a filesystem that insists on valid UTF-8
        pytest.skip(f"cannot create a non-UTF-8 file name: {exc}")
    write(tmp_path, "real.py", "widget()\n")

    outputs = []
    for env in backends:
        proc = run_bytes("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert b"bad\xff.py" in proc.stdout, proc.stdout
        # U+FFFD would mean the name was decoded and re-encoded lossily
        assert b"\xef\xbf\xbd" not in proc.stdout, proc.stdout
        assert b"real.py" in proc.stdout, proc.stdout
        outputs.append(sorted(proc.stdout.split(b"\n")))
    assert outputs[0] == outputs[1], outputs

    # A strict stdout must not kill the script either: the surrogate escapes
    # os.fsdecode produced are written back out as the original bytes.
    strict = dict(os.environ, PYTHONIOENCODING="utf-8:strict")
    proc = run_bytes("--uses", "widget", "--root", str(tmp_path), env=strict)
    assert proc.returncode == 0, proc.stderr
    assert b"bad\xff.py" in proc.stdout, proc.stdout


def test_repeated_matches_on_one_line_are_one_row_in_both_backends(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # ripgrep reports a matching LINE once; the walk fallback reported every
    # regex MATCH, so a line calling the symbol three times printed three
    # identical use rows without rg and one with it.
    write(tmp_path, "caller.py", "widget(); widget(); widget()\n")
    write(tmp_path, "other.py", "widget()\n")
    outputs = []
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        rows = [ln for ln in proc.stdout.split("\n") if ln]
        assert len(rows) == 2, rows
        assert sum("caller.py" in ln for ln in rows) == 1, rows
        outputs.append(sorted(rows))
    assert outputs[0] == outputs[1], outputs


def test_the_git_directory_is_never_searched(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # .git holds the whole history (and credentials in .git/config); it is in
    # SKIP_DIRS, and --no-ignore/--hidden must not bring it back.
    write(tmp_path, ".git/config", "widget()\n")
    write(tmp_path, "real.py", "widget()\n")
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert ".git" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout


def test_symlinked_files_are_not_followed(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # rg does not follow links without -L; the fallback walk must not either,
    # or a link committed in a repo turns a search into a read of a file
    # outside it, printed verbatim.
    outside = tmp_path / "outside"
    outside.mkdir()
    secret = outside / "credentials"
    secret.write_text("widget = 'SENTINEL-SECRET'\n", encoding="utf-8")
    root = tmp_path / "repo"
    write(root, "real.py", "widget()\n")
    symlink_or_skip(root / "creds", secret)
    for env in backends:
        proc = run("--uses", "widget", "--root", str(root), env=env)
        assert proc.returncode == 0, proc.stderr
        assert "SENTINEL-SECRET" not in proc.stdout, proc.stdout
        assert "creds" not in proc.stdout, proc.stdout
        assert "real.py" in proc.stdout, proc.stdout


# ---------- what counts as a definition ----------


def test_keyword_arguments_and_locals_are_uses_not_definitions(tmp_path: Path) -> None:
    # The .py assignment pattern accepted any indentation, so a keyword
    # argument on its own line (`    path=path,`) and every local assignment
    # counted as a DEFINITION of `path`: --def listed them, and --uses hid
    # them although each one reads `path`. Only a column-0 assignment is a
    # module-level name.
    write(
        tmp_path,
        "mod.py",
        "path = 'x'\n"
        "def run(path):\n"
        "    path = path + '/'\n"
        "    return dict(\n"
        "        path=path,\n"
        "    )\n",
    )
    proc = run("--def", "path", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert rows(proc, tmp_path) == ["mod.py:1:def:path = 'x'"]

    proc = run("--uses", "path", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert rows(proc, tmp_path) == [
        "mod.py:2:use:def run(path):",
        "mod.py:3:use:path = path + '/'",
        "mod.py:5:use:path=path,",
    ]


def test_in_lists_top_level_names_only(tmp_path: Path) -> None:
    # --in documents "every top-level symbol"; it listed every local, keyword
    # argument and method too, each with a whole-tree search of its own (89
    # symbols for a 52-name module, and 535,857 lines for rich/progress.py).
    target = write(
        tmp_path,
        "lib.py",
        "LIMIT = 3\n"
        "def helper(n):\n"
        "    total = n\n"
        "    return dict(\n"
        "        total=total,\n"
        "    )\n"
        "class Box:\n"
        "    size = 1\n"
        "    def run(self):\n"
        "        return 1\n",
    )
    write(tmp_path, "app.py", "from lib import helper\nhelper(total)\nbox.run()\n")
    proc = run("--in", str(target), "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert rows(proc, tmp_path) == [
        "lib.py:7:def:class Box:",
        "lib.py:1:def:LIMIT = 3",
        "lib.py:2:def:def helper(n):",
        "app.py:1:use:helper:from lib import helper",
        "app.py:2:use:helper:helper(total)",
    ]


def test_in_reports_the_line_a_definition_is_on(tmp_path: Path) -> None:
    # The patterns ran over the whole text with re.MULTILINE, so `^\s*`
    # swallowed the blank lines above `def beta` and reported it at line 3.
    target = write(
        tmp_path, "lib.py", "def alpha():\n    pass\n\n\ndef beta():\n    pass\n"
    )
    proc = run("--in", str(target), "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert rows(proc, tmp_path) == [
        "lib.py:1:def:def alpha():",
        "lib.py:5:def:def beta():",
    ]


def test_bash_function_keyword_form_is_a_definition(tmp_path: Path) -> None:
    # `function name {` (no parentheses) is the standard bash/ksh form; the
    # pattern required `()`, so --def, --in and check-broken-refs never saw it.
    lib = write(tmp_path, "lib.sh", "function deploy_app {\n  echo x\n}\n")
    write(tmp_path, "run.sh", "deploy_app\n")
    proc = run("--def", "deploy_app", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert rows(proc, tmp_path) == ["lib.sh:1:def:function deploy_app {"]
    proc = run("--in", str(lib), "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert rows(proc, tmp_path) == [
        "lib.sh:1:def:function deploy_app {",
        "run.sh:1:use:deploy_app:deploy_app",
    ]
    # a hyphenated name is not truncated into a definition of its first part
    write(tmp_path, "other.sh", "function deploy_app-v2 {\n  :\n}\n")
    proc = run("--def", "deploy_app", "--root", str(tmp_path))
    assert rows(proc, tmp_path) == ["lib.sh:1:def:function deploy_app {"]


def test_powershell_matching_ignores_case(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # PowerShell keywords and command names are case-insensitive: `Function`
    # defines what `get-widget` calls. Both were invisible. Other languages
    # keep exact case, so the .txt line below is not a use.
    write(tmp_path, "Tools.psm1", "Function Get-Widget {\n    param()\n}\n")
    write(tmp_path, "run.ps1", "get-widget\nGET-WIDGET -Name x\n")
    write(tmp_path, "notes.txt", "get-widget\n")
    for env in backends:
        proc = run("--def", "Get-Widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert rows(proc, tmp_path) == ["Tools.psm1:1:def:Function Get-Widget {"]
        proc = run("--uses", "Get-Widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert rows(proc, tmp_path) == [
            "run.ps1:1:use:get-widget",
            "run.ps1:2:use:GET-WIDGET -Name x",
        ]
    proc = run("--in", str(tmp_path / "Tools.psm1"), "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert rows(proc, tmp_path)[0] == "Tools.psm1:1:def:Function Get-Widget {"
    assert len(rows(proc, tmp_path)) == 3, proc.stdout


def test_typescript_enum_and_namespace_are_definitions(tmp_path: Path) -> None:
    status = write(
        tmp_path,
        "status.ts",
        "export enum OrderStatus { Open }\n"
        "export const enum Flag { On }\n"
        "export namespace Shapes {\n"
        "  export const side = 1;\n"
        "}\n",
    )
    write(tmp_path, "app.ts", "use(OrderStatus.Open, Flag.On, Shapes.side);\n")
    proc = run("--def", "OrderStatus", "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert rows(proc, tmp_path) == ["status.ts:1:def:export enum OrderStatus { Open }"]
    proc = run("--in", str(status), "--root", str(tmp_path))
    assert proc.returncode == 0, proc.stderr
    defs = [r for r in rows(proc, tmp_path) if ":def:" in r]
    assert defs == [
        "status.ts:2:def:export const enum Flag { On }",
        "status.ts:1:def:export enum OrderStatus { Open }",
        "status.ts:3:def:export namespace Shapes {",
    ]


# ---------- one search per run ----------


def test_each_mode_runs_one_search(
    tmp_path: Path, tmp_path_factory: pytest.TempPathFactory
) -> None:
    # --def ran one search per (extension, pattern) pair (66 of them), --uses
    # one more on top, and --in all of that again for every symbol of the
    # file. Definition lines hold the symbol as a whole word, so one word
    # search, classified in-process, finds them all.
    if sys.platform == "win32":
        pytest.skip("the counting rg is a /bin/sh script")
    log = counting_rg(tmp_path_factory.mktemp("counting-rg"))
    env = dict(os.environ)
    env["PATH"] = str(log.parent)
    lib = write(
        tmp_path,
        "lib.py",
        "".join(f"def f{i}():\n    pass\n" for i in range(20)),
    )
    write(tmp_path, "app.py", "f1()\nf7()\n")
    for args, expected in (
        (["--def", "f1"], ["lib.py:3:def:def f1():"]),
        (["--uses", "f1"], ["app.py:1:use:f1()"]),
    ):
        log.unlink(missing_ok=True)
        proc = run(*args, "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert rows(proc, tmp_path) == expected
        assert log.read_text(encoding="utf-8").count("run") == 1, args
    log.unlink(missing_ok=True)
    proc = run("--in", str(lib), "--root", str(tmp_path), env=env)
    assert proc.returncode == 0, proc.stderr
    assert "app.py:1:use:f1:f1()" in rows(proc, tmp_path)
    assert "app.py:2:use:f7:f7()" in rows(proc, tmp_path)
    assert log.read_text(encoding="utf-8").count("run") == 1


# ---------- the fallback reads files as a stream ----------


def test_the_fallback_numbers_lines_as_ripgrep_does(
    tmp_path: Path, backends: list[dict[str, str] | None]
) -> None:
    # The fallback read whole files in text mode, whose universal newlines
    # turn a lone "\r" into a line break, so every line after one was
    # numbered differently from rg. Both now split on "\n" alone.
    (tmp_path / "old-mac.txt").write_bytes(b"a\rb\rc\nwidget()\n")
    (tmp_path / "dos.txt").write_bytes(b"x\r\nwidget()\r\n")
    outputs = []
    for env in backends:
        proc = run("--uses", "widget", "--root", str(tmp_path), env=env)
        assert proc.returncode == 0, proc.stderr
        assert sorted(rows(proc, tmp_path)) == [
            "dos.txt:2:use:widget()",
            "old-mac.txt:2:use:widget()",
        ]
        outputs.append(proc.stdout)
    assert outputs[0] == outputs[1], outputs


def test_the_fallback_does_not_load_a_large_file_whole(
    tmp_path: Path, tmp_path_factory: pytest.TempPathFactory
) -> None:
    # Without rg every file was read whole and split, so peak memory was
    # several times the largest file under the root (2.2 GB for a 256 MB
    # weights file). Read as a stream it is bounded by the longest line.
    pytest.importorskip("resource")  # POSIX only: the probe below reads ru_maxrss
    data = tmp_path / "data.csv"
    line = b"0123456789," * 9 + b"\n"
    with data.open("wb") as fh:
        for _ in range(64):
            fh.write(line * 10_000)  # 58 MB of short lines in all
    write(tmp_path, "app.py", "widget()\n")
    bin_dir = tmp_path_factory.mktemp("no-rg-bin")
    link_git(bin_dir)
    probe = (
        "import resource, subprocess, sys\n"
        "subprocess.run(sys.argv[1:], check=True, stdout=subprocess.DEVNULL)\n"
        "print(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)\n"
    )
    env = dict(os.environ)
    env["PATH"] = str(bin_dir)
    proc = subprocess.run(
        [
            *(sys.executable, "-c", probe, sys.executable, str(SCRIPT)),
            *("--uses", "widget", "--root", str(tmp_path)),
        ],
        capture_output=True,
        text=True,
        check=True,
        env=env,
    )
    peak = int(proc.stdout.strip())
    peak_mb = peak / (1024 * 1024) if sys.platform == "darwin" else peak / 1024
    # measured: about 170 MB read whole, about 16 MB streamed
    assert peak_mb < 60, f"peak RSS {peak_mb:.0f} MB for a 58 MB file"


# ---------- git and rg are never taken from the workspace ----------


def test_search_path_drops_current_directory_entries(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # An empty entry, "." and a relative directory all mean the workspace.
    monkeypatch.setenv(
        "PATH", os.pathsep.join([str(tmp_path), "", os.curdir, "rel/bin"])
    )
    assert search_path() == str(tmp_path)


def test_a_tool_in_the_working_directory_is_refused_on_windows(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Windows' which() and CreateProcess both search the cwd for a bare name,
    # so a checkout shipping rg.exe or git.exe at its root would run.
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(_common, "_windows", lambda: True)
    monkeypatch.setattr(
        _common.shutil, "which", lambda name, path=None: str(tmp_path / name)
    )
    exe, refusal = resolve_tool("rg")
    assert exe is None
    assert refusal == f"refusing rg resolved inside the workspace ({tmp_path / 'rg'})"


@pytest.mark.skipif(sys.platform == "win32", reason="the real POSIX search")
def test_posix_resolves_to_an_absolute_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    tool = tmp_path / "rg"
    tool.write_text("#!/bin/sh\n")
    tool.chmod(0o755)
    monkeypatch.chdir(tmp_path)
    # an absolute PATH entry that happens to be the cwd still supplies it
    monkeypatch.setenv("PATH", str(tmp_path))
    assert resolve_tool("rg") == (str(tool), None)
    # reached through a relative entry, it is refused
    exe, refusal = resolve_tool("rg", path=os.curdir)
    assert exe is None
    assert refusal is not None


def test_a_rg_or_git_planted_in_the_working_directory_never_runs(
    tmp_path: Path, tmp_path_factory: pytest.TempPathFactory
) -> None:
    # The script checked shutil.which("rg") and then ran the bare name, so a
    # `.` (or empty) PATH entry made it run the checkout's own rg; on Windows
    # the cwd is searched even without one. Now only absolute PATH entries
    # supply a tool, and without a real rg the in-process reader is used.
    if sys.platform == "win32":
        pytest.skip("the planted tools are /bin/sh scripts")
    marker = tmp_path_factory.mktemp("marker") / "planted-ran"
    for tool in ("rg", "git"):
        planted = tmp_path / tool
        planted.write_text(f'#!/bin/sh\necho {tool} >> "{marker}"\nexit 1\n')
        planted.chmod(0o755)
    write(tmp_path, "app.py", "widget()\n")
    env = dict(os.environ)
    env["PATH"] = os.curdir
    env["GIT_CEILING_DIRECTORIES"] = str(tmp_path.parent)
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "--uses", "widget", "--root", "."],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    assert proc.returncode == 0, proc.stderr
    assert not marker.exists(), marker.read_text()
    assert rows(proc, tmp_path) == ["app.py:1:use:widget()"]
