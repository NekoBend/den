"""Shared definitions for the reference-analysis scripts.

Imported by both find-references.py and check-broken-refs.py so the
per-language definition-site patterns, the search scope and the search itself
live in one place.

Pattern tables. Values contain the token `{name}`; each consumer substitutes
it before compiling the regex:

    DEFINITION_PATTERNS  where ONE symbol may be defined, at any depth
                         (find-references --def, and the def/use split of
                         --uses and --in). `{name}` becomes re.escape(symbol).
    TOP_LEVEL_PATTERNS   which names a file defines at module level
                         (find-references --in, check-broken-refs). `{name}`
                         becomes a capture group.
    MEMBER_PATTERNS      methods (check-broken-refs only): a removed one is
                         looked for as `.name` attribute access, never as a
                         bare word.

Every pattern is applied to ONE line at a time, in Python, never handed to
ripgrep: ripgrep only finds the lines holding the symbol as a whole word, and
the patterns classify those lines. That is what makes a lookup one search
instead of one per (extension, pattern) pair, and it lets the patterns use
lookarounds that ripgrep's regex engine lacks.

For Python files, which block a line sits in decides which table applies
(see _python_scopes): indentation alone cannot tell a method from a function
defined under a module-level `if`.

The search plumbing both scripts share lives here too: which files are
searched, the absolute path of git and rg, the ripgrep invocation and the
parser for its output, the streaming fallback reader, and the formatter that
prints a result. Keeping them in one place is what makes the two backends
return the same lines, and print them the same way.
"""

from __future__ import annotations

import contextlib
import functools
import io
import operator
import os
import re
import shutil
import stat
import subprocess
import sys
import tokenize
from pathlib import Path, PurePosixPath
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterable, Iterator

Hit = tuple[str, int, str]

# Where a symbol may be defined, per extension. {name} is the symbol.
DEFINITION_PATTERNS: dict[str, list[str]] = {
    ".py": [
        r"^\s*(?:async\s+)?def\s+{name}\s*\(",
        r"^\s*class\s+{name}\s*[(:\[]",
        # Column 0 only: a module-level name. Indented, this matched every
        # local assignment and every keyword argument of a multi-line call
        # (`    path=path,`), so such lines vanished from --uses and every
        # local of a changed file became a "removed definition".
        r"^{name}\s*=",
    ],
    ".ts": [
        r"\bfunction\s+{name}\s*[(<]",
        r"\bclass\s+{name}\b",
        r"\binterface\s+{name}\b",
        r"\btype\s+{name}\s*=",
        r"\b(?:const|let|var)\s+{name}\s*[=:]",
        r"\benum\s+{name}\b",  # `const enum` too
        r"\bnamespace\s+{name}\b",
    ],
    ".go": [
        r"^func\s+{name}\s*\(",
        r"^func\s+\(\s*\w+\s+\*?\w+\s*\)\s+{name}\s*\(",
        r"^type\s+{name}\s+",
        r"^var\s+{name}\b",
        r"^const\s+{name}\b",
    ],
    ".rs": [
        r"\bfn\s+{name}\s*[<(]",
        r"\bstruct\s+{name}\b",
        r"\benum\s+{name}\b",
        r"\btrait\s+{name}\b",
        r"\b(?:const|static)\s+{name}\b",
    ],
    ".java": [
        r"\bclass\s+{name}\b",
        r"\binterface\s+{name}\b",
        r"\benum\s+{name}\b",
        r"\brecord\s+{name}\b",
    ],
    ".cs": [
        r"\bclass\s+{name}\b",
        r"\binterface\s+{name}\b",
        r"\bstruct\s+{name}\b",
        r"\brecord\s+{name}\b",
        r"\benum\s+{name}\b",
    ],
    ".sh": [
        r"^\s*(?:function\s+)?{name}\s*\(\s*\)",
        # bash/ksh `function name {` (the parentheses are optional there)
        r"^\s*function\s+{name}(?=[\s({]|$)",
        r"^{name}\s*=",
    ],
    ".ps1": [
        r"^\s*function\s+(?:global:|script:|local:|private:)?{name}\b",
        r"^\s*filter\s+{name}\b",
        r"^\s*class\s+{name}\b",
        r"^\s*enum\s+{name}\b",
        # a script-level `$x =` at column 0, or an explicitly scoped one at any
        # depth; an indented plain `$x =` is a function's local
        r"^\$(?:script:|global:)?{name}\s*=",
        r"^\s*\$(?:script|global):{name}\s*=",
    ],
}

# Which names a file defines at the top level. A local variable, a keyword
# argument or a nested function is not something another file can refer to,
# and treating one as a definition made check-broken-refs search the whole
# tree for names like `path`, `r` or `n` whenever a file holding them changed.
#
# Python: these apply to a line at module level (_python_scopes). A def or a
# class indented under a module-level if/try/with/for/while block is
# module-level too (`if os.name == "nt": def helper()` is still lib.helper),
# and is matched with its indentation removed; an assignment counts at
# column 0 only, since the same block holds loop counters and the variables
# of an `if __name__ == "__main__":` script.
_TS_PREFIX = r"^(?:export\s+(?:default\s+)?)?(?:declare\s+)?"
TOP_LEVEL_PATTERNS: dict[str, list[str]] = {
    ".py": [
        r"^(?:async\s+)?def\s+{name}\s*\(",
        r"^class\s+{name}\s*[(:\[]",
        r"^{name}\s*=",
    ],
    ".ts": [
        _TS_PREFIX + r"(?:async\s+)?function\s+{name}\s*[(<]",
        _TS_PREFIX + r"(?:abstract\s+)?class\s+{name}\b",
        _TS_PREFIX + r"interface\s+{name}\b",
        _TS_PREFIX + r"type\s+{name}\s*=",
        _TS_PREFIX + r"(?:const|let|var)\s+{name}\s*[=:]",
        _TS_PREFIX + r"(?:const\s+)?enum\s+{name}\b",
        _TS_PREFIX + r"namespace\s+{name}\b",
    ],
    ".go": DEFINITION_PATTERNS[".go"],
    ".rs": DEFINITION_PATTERNS[".rs"],
    ".java": DEFINITION_PATTERNS[".java"],
    ".cs": DEFINITION_PATTERNS[".cs"],
    # Function definitions only, at any depth: a shell function is global
    # wherever it is defined, while an assignment is mostly a local or a loop
    # counter.
    ".sh": DEFINITION_PATTERNS[".sh"][:2],
    ".ps1": DEFINITION_PATTERNS[".ps1"],
}

# Methods. A removed one is searched for only as `.name` attribute access, so
# deleting a class does not report every bare occurrence of `run` or `get`.
# Python: applied only to a line directly in a class body (_python_scopes),
# so a function nested in another function is neither a method nor a
# top-level name.
MEMBER_PATTERNS: dict[str, list[str]] = {
    ".py": [r"^\s+(?:async\s+)?def\s+{name}\s*\("],
}

# The Python top-level patterns that also apply, with the indentation
# removed, to a line inside a module-level block: def and class.
_PY_BLOCK_LEVEL = TOP_LEVEL_PATTERNS[".py"][:2]

# The {name} capture used when DISCOVERING definitions (check-broken-refs,
# find-references --in). The default \w+ would truncate PowerShell's
# Verb-Noun names at the hyphen, so "function New-Wrapper" becomes a
# definition of "New" - measured to both flood false broken_refs (a deleted
# Test-* symbol collides with every Test-Path call) and hide real ones
# (New-Wrapper deleted stays "defined" through New-WrapperSuffix).
DEFINITION_CAPTURE: dict[str, str] = {
    ".ps1": r"([\w-]+)",
    ".psm1": r"([\w-]+)",
}
DEFAULT_CAPTURE = r"(\w+)"

# Extensions that share patterns with the canonical one.
for _table in (DEFINITION_PATTERNS, TOP_LEVEL_PATTERNS):
    for _alias in (".tsx", ".js", ".jsx", ".mjs", ".cjs"):
        _table[_alias] = _table[".ts"]
    _table[".psm1"] = _table[".ps1"]
    _table[".bash"] = _table[".sh"]
del _table, _alias

# PowerShell keywords, commands and variables are case-insensitive: in these
# files `Function Get-Widget` defines what `get-widget` calls, so both the
# patterns and the whole-word search ignore case there, and only there.
CASE_INSENSITIVE_EXTS: frozenset[str] = frozenset({".ps1", ".psm1", ".psd1"})

# Directories never searched, regardless of language.
SKIP_DIRS: frozenset[str] = frozenset(
    {
        ".git",
        ".hg",
        ".svn",
        "node_modules",
        ".venv",
        "venv",
        "__pycache__",
        "target",
        "build",
        "dist",
        "out",
        ".idea",
        ".vscode",
        ".mypy_cache",
        ".ruff_cache",
        ".pytest_cache",
        ".tox",
    }
)


def _flags(ext: str) -> int:
    return re.IGNORECASE if ext in CASE_INSENSITIVE_EXTS else 0


@functools.cache
def _definition_rxs(ext: str, symbol: str) -> tuple[re.Pattern[str], ...]:
    sym = re.escape(symbol)
    return tuple(
        re.compile(t.replace("{name}", sym), _flags(ext))
        for t in DEFINITION_PATTERNS.get(ext, [])
    )


def is_definition_line(line: str, ext: str, symbol: str) -> bool:
    """Whether `line` of a file with suffix `ext` may define `symbol`."""
    return any(rx.search(line) for rx in _definition_rxs(ext, symbol))


def _compile(ext: str, templates: list[str]) -> list[re.Pattern[str]]:
    capture = DEFINITION_CAPTURE.get(ext, DEFAULT_CAPTURE)
    return [re.compile(t.replace("{name}", capture), _flags(ext)) for t in templates]


def _scan(
    lines: Iterable[tuple[int, str, str, list[re.Pattern[str]]]],
) -> list[tuple[int, str, str]]:
    """(lineno, name, line) for each name the patterns capture.

    Each item is (lineno, the text the patterns run on, the line reported,
    the patterns), so one scan can hold lines matched with and without their
    indentation.
    """
    found: list[tuple[int, str, str]] = []
    seen: set[tuple[int, str]] = set()
    for lineno, probe, line, rxs in lines:
        for rx in rxs:
            for match in rx.finditer(probe):
                key = (lineno, match.group(1))
                if key not in seen:
                    seen.add(key)
                    found.append((lineno, match.group(1), line))
    return found


def _lines(text: str) -> list[str]:
    # Split on "\n" alone, as ripgrep numbers lines: run over the whole text
    # with re.MULTILINE, `^\s*` swallowed the blank lines above a definition
    # and reported it at the first of them. A leading byte-order mark is not
    # part of the first line (it hid a definition there from `^def`).
    return text.removeprefix("\ufeff").split("\n")


# The first word of a Python statement that opens an indented block, and the
# kind of block: a def, a class, or any other compound statement.
_PY_OPENER = re.compile(
    r"(?:async\s+)?(?:(def|class)|if|elif|else|try|except|finally|with|for"
    r"|while|match|case)\b"
)
# `if __name__ == "__main__":` holds a script's own code, not the module's
# API: a function defined there (a route handler, a demo) is not something
# another file imports, and counting it searched the tree for `root` or
# `main` whenever such a script changed.
_PY_MAIN_GUARD = re.compile(
    r"""if\s*\(?\s*(?:__name__\s*==\s*(['"])__main__\1"""
    r"""|(['"])__main__\2\s*==\s*__name__)\s*\)?\s*:"""
)


# Tokens that neither start a statement nor change the block structure.
_PY_PASSIVE_TOKENS = frozenset({tokenize.NL, tokenize.COMMENT, tokenize.ENDMARKER})


def _python_statement(line: str, col: int, blocks: list[str]) -> tuple[str, str]:
    """(scope, kind of block it opens) for the statement at `line[col:]`.

    The scope is "module", "class" or "" (in a function or the main guard):
    the innermost def or class decides, and if/try/... blocks in between do
    not change whose body a statement is in.
    """
    opener = _PY_OPENER.match(line, col)
    opens = (opener.group(1) or "block") if opener else "block"
    if _PY_MAIN_GUARD.match(line, col):
        opens = "script"
    owner = next((kind for kind in reversed(blocks) if kind != "block"), "module")
    return (owner if owner in {"module", "class"} else ""), opens


@functools.lru_cache(maxsize=8)
def _python_scopes(text: str) -> dict[int, str]:
    """Line number -> "module" or "class" for each Python statement line.

    "module": a statement at module level, or in a module-level
    if/try/with/for/while block (a function defined there is still an
    attribute of the module), except `if __name__ == "__main__":`.
    "class": a statement in a class body, an if/try/... block inside it
    included. Statements nested in a function or in the main guard,
    continuation lines and lines inside strings get no entry.

    The blocks come from Python's own tokenizer, so a bracketed continuation
    line, a string spanning lines or a comment cannot pass for a statement.
    Where the tokenizer gives up (a syntax error, an unterminated string),
    the remaining lines fall back to the indentation rule: column 0 is
    "module", anything indented "class".
    """
    lines = _lines(text)
    scopes: dict[int, str] = {}
    # each open indented block: "def", "class", "script" (the main guard) or
    # "block" (any other compound statement)
    blocks: list[str] = []
    opens = "block"  # the kind of block the current statement would open
    statement_start = True
    last_row = 0
    try:
        tokens = tokenize.generate_tokens(io.StringIO("\n".join(lines)).readline)
        for tok in tokens:
            last_row = tok.start[0]
            if tok.type == tokenize.INDENT:
                blocks.append(opens)
            elif tok.type == tokenize.DEDENT:
                del blocks[-1:]
            elif tok.type == tokenize.NEWLINE:
                statement_start = True
            elif statement_start and tok.type not in _PY_PASSIVE_TOKENS:
                statement_start = False
                row, col = tok.start
                line = lines[row - 1] if row <= len(lines) else ""
                scope, opens = _python_statement(line, col, blocks)
                if scope:
                    scopes[row] = scope
    except (tokenize.TokenError, SyntaxError):
        for lineno in range(last_row + 1, len(lines) + 1):
            line = lines[lineno - 1]
            if line.strip():
                scopes[lineno] = "class" if line[:1].isspace() else "module"
    return scopes


def _python_definitions(text: str, *, member: bool) -> list[tuple[int, str, str]]:
    lines = _lines(text)
    top = _compile(".py", TOP_LEVEL_PATTERNS[".py"])
    nested = _compile(".py", _PY_BLOCK_LEVEL)
    methods = _compile(".py", MEMBER_PATTERNS[".py"])
    picked: list[tuple[int, str, str, list[re.Pattern[str]]]] = []
    for lineno, scope in sorted(_python_scopes(text).items()):
        line = lines[lineno - 1] if lineno <= len(lines) else ""
        if member:
            if scope == "class":
                picked.append((lineno, line, line, methods))
        elif scope == "module":
            if line[:1].isspace():
                picked.append((lineno, line.lstrip(), line, nested))
            else:
                picked.append((lineno, line, line, top))
    return _scan(picked)


def top_level_definitions(text: str, ext: str) -> list[tuple[int, str, str]]:
    """(lineno, name, line) for every top-level definition in `text`."""
    if ext == ".py":
        return _python_definitions(text, member=False)
    rxs = _compile(ext, TOP_LEVEL_PATTERNS.get(ext, []))
    return _scan((n, line, line, rxs) for n, line in enumerate(_lines(text), 1))


def member_definitions(text: str, ext: str) -> list[tuple[int, str, str]]:
    """(lineno, name, line) for every method defined in `text`."""
    if ext == ".py":
        return _python_definitions(text, member=True)
    rxs = _compile(ext, MEMBER_PATTERNS.get(ext, []))
    return _scan((n, line, line, rxs) for n, line in enumerate(_lines(text), 1))


@functools.cache
def _word_rx(symbol: str, *, ignore_case: bool, member: bool) -> re.Pattern[str]:
    prefix = r"\." if member else r"\b"
    return re.compile(
        rf"{prefix}{re.escape(symbol)}\b", re.IGNORECASE if ignore_case else 0
    )


def mentions(line: str, ext: str, symbol: str, *, member: bool = False) -> bool:
    """Whether `line` (of a file with suffix `ext`) names `symbol`.

    As a whole word, or with member=True only as `.symbol` attribute access.
    """
    ignore_case = ext in CASE_INSENSITIVE_EXTS
    if not ignore_case and symbol not in line:  # the cheap test first
        return False
    rx = _word_rx(symbol, ignore_case=ignore_case, member=member)
    return rx.search(line) is not None


# ---------- external tools ----------


def _windows() -> bool:
    # Indirection so tests can flip platform without touching os.name globally
    # (pathlib reads os.name to pick WindowsPath/PosixPath).
    return os.name == "nt"


def search_path() -> str:
    """PATH with every current-directory entry dropped.

    An empty entry and any relative entry (including a Windows drive-relative
    one) are resolved against the cwd - the workspace under review - so only
    absolute directories are allowed to supply a tool.
    """
    entries = os.environ.get("PATH", "").split(os.pathsep)
    return os.pathsep.join(e for e in entries if e and Path(e).is_absolute())


def resolve_tool(name: str, path: str | None = None) -> tuple[str | None, str | None]:
    """(absolute path to run, refusal reason) for the tool `name`.

    The same rule as the resolver of the CLI these scripts ship with, copied
    because they also run standalone and import nothing but the standard
    library. Both None means "not installed". A hit in the working
    directory itself is refused rather than run: shutil.which re-inserts the
    current directory ahead of any search path on Windows (unless
    NoDefaultCurrentDirectoryInExePath is set) and CreateProcess searches it
    too for a path-less name, so a checkout that ships `git.exe` or `rg.exe`
    at its root would otherwise run when these scripts are pointed at it.
    Handing subprocess the absolute path stops CreateProcess searching at all.
    Only the directory itself is refused, and only on Windows (or when the hit
    came through a relative entry): POSIX searches neither the cwd nor, after
    search_path, a relative entry.
    """
    hit = shutil.which(name, path=search_path() if path is None else path)
    if hit is None:
        return None, None
    exe = Path(hit)
    relative = not exe.is_absolute()  # via the Windows curdir entry, or `path`
    if relative:
        exe = Path.cwd() / exe
    in_cwd = exe.resolve().parent == Path.cwd().resolve()
    if in_cwd and (relative or _windows()):
        return None, f"refusing {name} resolved inside the workspace ({exe})"
    return str(exe), None


def _note(message: str) -> None:
    print(f"{Path(sys.argv[0]).name}: {message}", file=sys.stderr)


@functools.cache
def find_tool(name: str) -> str | None:
    """Absolute path of `name`, or None when it is missing or refused.

    Resolved once per run. A refusal is reported on stderr, so the caller
    that falls back to something else still tells the user why.
    """
    exe, refusal = resolve_tool(name)
    if refusal:
        _note(refusal)
    return exe


# Put ahead of every git subcommand these scripts run. core.fsmonitor names a
# program git starts to ask which files changed, and the repository's own
# .git/config can set it: a tree copied from elsewhere (an archive, a shared
# folder) would otherwise run that program as soon as it is searched.
GIT_SAFE_CONFIG: tuple[str, ...] = ("-c", "core.fsmonitor=false")


def git_command(git: str, *args: str) -> list[str]:
    """argv for `git <args>` run by absolute path, with GIT_SAFE_CONFIG."""
    return [git, *GIT_SAFE_CONFIG, *args]


# ---------- which files are searched ----------


def _git_listing(root: Path) -> list[str] | None:
    """Paths under `root` that git tracks or would track, or None.

    `git ls-files --cached --others --exclude-standard` is the tree minus what
    the user told git to ignore (.gitignore at every level,
    .git/info/exclude, core.excludesFile). None when git is missing or
    refused, or `root` is not inside a work tree. None as well when `root`
    itself is ignored, even if some files in it are force-added: a search the
    user pointed there explicitly must not come back empty, or hold only
    those files. When git fails inside a work tree (an unreadable index, a
    repository owned by someone else), stderr says so before the whole tree
    is searched instead.
    """
    git = find_tool("git")
    if git is None:
        return None
    proc = subprocess.run(
        git_command(
            git, "ls-files", "-z", "--cached", "--others", "--exclude-standard"
        ),
        cwd=root,
        capture_output=True,
        check=False,
        # untranslated messages, so "not a git repository" can be recognized
        env={**os.environ, "LC_ALL": "C"},
    )
    if proc.returncode != 0:
        if b"not a git repository" not in proc.stderr:
            reason = proc.stderr.decode("utf-8", errors="replace").strip()
            first = reason.splitlines()[0] if reason else f"exit {proc.returncode}"
            _note(
                f"git ls-files failed ({first}); .gitignore is not applied,"
                " every file under the root is searched"
            )
        return None
    ignored = subprocess.run(
        # --no-index: a directory holding a force-added file is still ignored
        git_command(git, "check-ignore", "-q", "--no-index", "--", "."),
        cwd=root,
        capture_output=True,
        check=False,
    )
    if ignored.returncode == 0:
        return None
    return [os.fsdecode(raw) for raw in proc.stdout.split(b"\x00") if raw]


def _walk(root: Path) -> list[Path]:
    """Every regular file under `root`, for a root outside a git work tree.

    Prunes SKIP_DIRS and every directory holding a pyvenv.cfg, which is what
    marks a Python virtual environment whatever it is called. Symlinks are
    neither followed nor listed.
    """
    found: list[Path] = []
    pending = [root]
    while pending:
        try:
            with os.scandir(pending.pop()) as it:
                entries = list(it)
        except OSError:
            continue
        for entry in entries:
            if entry.name in SKIP_DIRS:
                continue
            if entry.is_dir(follow_symlinks=False):
                if not Path(entry.path, "pyvenv.cfg").is_file():
                    pending.append(Path(entry.path))
            elif entry.is_file(follow_symlinks=False):
                found.append(Path(entry.path))
    return found


def _regular_file(path: Path) -> bool:
    """One lstat: a regular file, and not a symlink to one."""
    try:
        return stat.S_ISREG(path.lstat().st_mode)
    except OSError:
        return False


_IO_REPARSE_TAG_MOUNT_POINT = 0xA0000003  # a Windows junction


def _real_directory(path: Path) -> bool:
    """One lstat: a directory, and not a symlink (or junction) to one."""
    try:
        st = path.lstat()
    except OSError:
        return False
    if getattr(st, "st_reparse_tag", 0) == _IO_REPARSE_TAG_MOUNT_POINT:
        return False
    return stat.S_ISDIR(st.st_mode)


def list_search_files(root: Path) -> list[Path]:
    """Every file under `root` that a search reads, sorted.

    Inside a git work tree that is what `git ls-files --cached --others
    --exclude-standard` lists, so ignored files (virtual environments, build
    output, caches) are not searched. Outside one, every file under the root
    is, except directories that hold a pyvenv.cfg. Both ways:

    - SKIP_DIRS are dropped by NAME below `root`, so a checkout that itself
      lives under `build/`, `dist/`, `target/` ... is still searched. A
      regular FILE carrying one of those names is dropped as well: a linked
      git worktree keeps a `.git` file, not a directory.
    - Symlinks are never followed, so a link committed in the tree cannot
      pull a file from outside it into the results. That holds for the
      directories on the way to a listed file too: the index can still name
      conf/settings.py after conf/ became a link to somewhere else.
    - Inside a work tree, nested repositories and submodules are separate
      work trees (git lists each as one entry) and are not searched.

    The same list is handed to ripgrep and to the fallback reader, which is
    what keeps the two backends on the same files.
    """
    listing = _git_listing(root)
    if listing is None:
        files = _walk(root)
    else:
        files = []
        real: dict[Path, bool] = {root: True}

        def real_dirs(directory: Path) -> bool:
            # every directory from `root` down to this one: one lstat each,
            # once per run however many files they hold
            if directory not in real:
                real[directory] = real_dirs(directory.parent) and _real_directory(
                    directory
                )
            return real[directory]

        for rel in dict.fromkeys(listing):  # a conflicted path is listed per stage
            parts = PurePosixPath(rel).parts  # git separates with "/" everywhere
            if any(part in SKIP_DIRS for part in parts):
                continue
            path = root.joinpath(*parts)
            if real_dirs(path.parent) and _regular_file(path):
                files.append(path)
    return sorted(files, key=str)


# ---------- the search ----------


# Flags for every ripgrep invocation. Ripgrep is handed the file list itself,
# so it applies no ignore rules or globs of its own (an explicitly named file
# is always searched).
#
# --no-config: ripgrep otherwise reads the file named by RIPGREP_CONFIG_PATH
# and applies whatever is in it, so a user whose config carries --follow or
# --text would get the rg backend reading differently on that machine only.
#
# --null terminates the file name with a NUL byte instead of a colon, which is
# what lets parse_rg_line find where the path ends: a path may contain colons
# of its own (`a:b.py`, or a Windows drive letter) and a NUL byte cannot occur
# in one. The flag and the parser belong together; do not pass one without the
# other.
#
# --text is the one binary policy both backends can enforce EXACTLY: every
# regular file is searched as text. ripgrep's own binary heuristic works per
# read buffer and can still print matches found before the NUL it stops at,
# which the fallback reader cannot reproduce; so neither side gives up on a
# file.
RG_SEARCH_FLAGS: tuple[str, ...] = (
    "--no-config",
    "--null",
    "--text",
    "--no-heading",
    "--line-number",
    "--with-filename",
    "--no-messages",
)

# Longest ripgrep command line, in characters, before the file list is split
# over several runs. Windows caps a whole command line at 32,767 characters;
# POSIX limits are far higher.
_ARGV_BUDGET = 24_000 if os.name == "nt" else 100_000


def parse_rg_line(record: bytes) -> tuple[str, int, str] | None:
    """Parse one `<path>NUL<lineno>:<content>` record of ripgrep --null output.

    Returns None when the record carries no usable location.

    Records are BYTES because a POSIX file name is bytes and need not be valid
    UTF-8. Decoding the stream as text renamed such a file to one with U+FFFD
    in it, while the fallback reader yields the real name, so the two backends
    printed different paths for the same file (and check-broken-refs' own
    "this mention is in the file the symbol was removed from" test stopped
    matching, turning that mention into a reported broken reference under rg
    only). The path is converted with os.fsdecode, whose surrogateescape
    round-trips back to the original bytes; the content is text and is decoded
    with errors="replace", exactly as iter_searchable_lines does it.

    The NUL is what makes the split unambiguous: a path may contain colons of
    its own (`a:b.py`, or a Windows drive letter) and cannot contain a NUL.
    """
    path, sep, rest = record.partition(b"\x00")
    if not sep:
        return None
    lineno_text, sep, content = rest.partition(b":")
    if not sep:
        return None
    try:
        lineno = int(lineno_text)
    except ValueError:
        return None
    return (os.fsdecode(path), lineno, content.decode("utf-8", errors="replace"))


def parse_rg_output(stdout: bytes) -> list[tuple[str, int, str]]:
    """Parse ripgrep's whole --null stdout into hits, record by record.

    A record is `<path>NUL<lineno>:<content>` and only the newline AFTER the
    NUL ends it, which is why the stream is framed by hand rather than split
    into "lines": splitlines() also breaks on form feed, vertical tab, NEL,
    U+2028 and U+2029, so any of those INSIDE a matching line truncated the
    record, and a newline inside a FILE NAME split one record into two
    unusable halves. The fallback reader reads both kinds of file without
    trouble, so each case was a disagreement between the backends.

    Records that do not parse are skipped.
    """
    hits: list[tuple[str, int, str]] = []
    pos = 0
    while pos < len(stdout):
        nul = stdout.find(b"\x00", pos)
        if nul == -1:
            break
        end = stdout.find(b"\n", nul)
        if end == -1:
            end = len(stdout)
        hit = parse_rg_line(stdout[pos:end])
        if hit is not None:
            hits.append(hit)
        pos = end + 1
    return hits


# What ripgrep does with a byte-order mark, which the reader below mirrors: a
# UTF-16 file is transcoded to UTF-8 before it is searched (Windows
# PowerShell writes its scripts that way), and a UTF-8 mark is dropped.
_UTF16_BOMS = ((b"\xff\xfe", "utf-16-le"), (b"\xfe\xff", "utf-16-be"))
_UTF8_BOM = b"\xef\xbb\xbf"


def _raw_lines(path: Path) -> Iterator[bytes]:
    """Each line of `path` as UTF-8 bytes, without its "\\n"."""
    try:
        with path.open("rb") as fh:
            head = fh.read(3)
            for bom, codec in _UTF16_BOMS:
                if head.startswith(bom):
                    fh.seek(len(bom))
                    # newline="\n": split on "\n" alone, keep every "\r"
                    text = io.TextIOWrapper(
                        fh, encoding=codec, errors="replace", newline="\n"
                    )
                    for line in text:
                        yield line.removesuffix("\n").encode("utf-8")
                    return
            fh.seek(len(_UTF8_BOM) if head == _UTF8_BOM else 0)
            for raw in fh:
                yield raw.removesuffix(b"\n")
    except OSError:
        return


def iter_searchable_lines(path: Path) -> Iterator[tuple[int, str]]:
    """Yield (lineno, text) for every line of `path`, read as a stream.

    Lines are split on b"\\n" alone, the record separator ripgrep uses (never
    on "\\r", form feed or U+2028), and each one is decoded on its own with
    errors="replace". A UTF-8 sequence never contains 0x0A, so that is the
    text a whole-file decode gives, while memory stays bounded by the longest
    line instead of the largest file: every regular file is searched,
    datasets and model weights included.

    Undecodable bytes become U+FFFD rather than disappearing: ripgrep searches
    raw bytes, so it does not match `widget` inside b"wid\\xffget()", while
    errors="ignore" would delete the 0xff and forge exactly that hit here.
    U+FFFD is not a word character, so the boundary behaves as rg's does.

    A file starting with a byte-order mark is read as ripgrep reads it: UTF-16
    is decoded as such, and the mark itself is never part of line 1.

    A file that cannot be read yields nothing more.
    """
    for lineno, raw in enumerate(_raw_lines(path), start=1):
        yield lineno, raw.decode("utf-8", errors="replace")


def _batches(args: list[str], budget: int) -> Iterator[list[str]]:
    batch: list[str] = []
    used = 0
    for arg in args:
        cost = len(arg) + 3  # a separator, and quotes on Windows
        if batch and used + cost > budget:
            yield batch
            batch, used = [], 0
        batch.append(arg)
        used += cost
    if batch:
        yield batch


def _search_rg(
    rg: str, pattern: str, files: list[Path], *, ignore_case: bool
) -> list[Hit]:
    """Hits of `pattern` in `files`; OSError when ripgrep cannot run it.

    The pattern goes in on stdin (`-f -`), not on the command line: an
    alternation of a few thousand removed names is longer than the whole
    command-line budget, which left room for one file per ripgrep run, and
    longer than the kernel takes for one argument at all.
    """
    cmd = [rg, *RG_SEARCH_FLAGS]
    if ignore_case:
        cmd.append("--ignore-case")
    cmd += ["-f", "-", "--"]
    pattern_bytes = pattern.encode("utf-8", errors="surrogateescape")
    hits: list[Hit] = []
    budget = _ARGV_BUDGET - sum(len(a) + 3 for a in cmd)
    for batch in _batches([str(f) for f in files], budget):
        # stdout is read as BYTES: it carries file names, and a name is not
        # required to be valid UTF-8. parse_rg_output converts each part with
        # the right codec.
        proc = subprocess.run(
            [*cmd, *batch], input=pattern_bytes, capture_output=True, check=False
        )
        # --no-messages silences unreadable files, so anything on stderr with
        # status 2 is about the pattern itself (too big to compile, say):
        # nothing was searched, and the in-process reader has to do it.
        if proc.returncode == 2 and proc.stderr.strip():
            raise OSError(proc.stderr.decode("utf-8", errors="replace").strip())
        hits.extend(parse_rg_output(proc.stdout))
    return hits


def _search_walk(
    names: list[str], pattern: str, files: list[Path], *, ignore_case: bool
) -> list[Hit]:
    # One hit per matching LINE, not one per regex match, as ripgrep reports
    # them with no --only-matching.
    rx = re.compile(pattern, re.IGNORECASE if ignore_case else 0)
    # A line can hold a name only if its bytes hold the name's UTF-8 bytes, so
    # that cheap test runs first and only the lines passing it are decoded.
    # Not under ignore-case, where Unicode folding (the Kelvin sign is a `k`)
    # has no byte-level equivalent, nor for a name holding U+FFFD, which an
    # undecodable byte in the file also turns into.
    pre = None
    if not ignore_case and not any("\ufffd" in n for n in names):
        pre = re.compile(b"|".join(re.escape(n.encode()) for n in names))
    hits: list[Hit] = []
    for path in files:
        name = str(path)
        for lineno, raw in enumerate(_raw_lines(path), start=1):
            if pre is not None and not pre.search(raw):
                continue
            line = raw.decode("utf-8", errors="replace")
            if rx.search(line):
                hits.append((name, lineno, line))
    return hits


def search_words(symbols: Iterable[str], files: list[Path]) -> list[Hit]:
    """Every line of `files` holding one of `symbols` as a whole word.

    One pass over the files for any number of symbols: the caller works out
    which symbol a line holds, and whether it is a definition, from the line
    itself. Uses ripgrep when it is installed, otherwise reads the files
    in-process; both get the same file list and the same pattern, and the
    hits come back sorted by (file, line). Case is ignored in PowerShell
    files only, so those are searched apart: one ripgrep run per case group,
    more only when a file list outgrows the command-line budget.
    """
    names = sorted(set(symbols), key=lambda s: (-len(s), s))
    if not names or not files:
        return []
    pattern = r"\b(?:" + "|".join(re.escape(n) for n in names) + r")\b"
    rg = find_tool("rg")
    hits: list[Hit] = []
    for ignore_case in (False, True):
        group = [f for f in files if (f.suffix in CASE_INSENSITIVE_EXTS) == ignore_case]
        if not group:
            continue
        if rg is not None:
            try:
                hits.extend(_search_rg(rg, pattern, group, ignore_case=ignore_case))
                continue
            except OSError:
                pass  # rg vanished or cannot start: read the files instead
        hits.extend(_search_walk(names, pattern, group, ignore_case=ignore_case))
    hits.sort(key=operator.itemgetter(0, 1))
    return hits


# ---------- output ----------


# Longest <context> printed on a result line. Every regular file is searched
# as text, so the matching "line" of a minified bundle, a data blob or an
# object file can be megabytes long, and both scripts print it verbatim. The
# clamp sits where the line is FORMATTED - one place for both scripts and both
# backends - so ripgrep's own output stays untouched and parse_rg_line is
# unaffected.
MAX_CONTEXT_CHARS = 300


def format_hit(file: str, lineno: int, kind: str, content: str) -> str:
    """Render one `<file>:<line>:<kind>:<context>` result line.

    The context loses its trailing newline and is clamped to
    MAX_CONTEXT_CHARS, with ` [...+N chars]` appended when anything was cut,
    so a single hit inside a long line cannot flood the caller's output.
    """
    context = content.rstrip("\r\n")
    if len(context) > MAX_CONTEXT_CHARS:
        dropped = len(context) - MAX_CONTEXT_CHARS
        context = f"{context[:MAX_CONTEXT_CHARS]} [...+{dropped} chars]"
    return f"{file}:{lineno}:{kind}:{context}"


def allow_undecodable_paths_on_stdout() -> None:
    """Let stdout carry file names that are not valid UTF-8.

    os.fsdecode leaves undecodable bytes as surrogate escapes, and printing one
    to a strict stdout raises UnicodeEncodeError: on a tree holding such a file
    the scripts would die instead of reporting it. surrogateescape writes the
    original bytes back out, which is what every other tool prints.
    """
    # not every stdout is a reconfigurable text stream
    with contextlib.suppress(AttributeError, OSError):
        sys.stdout.reconfigure(errors="surrogateescape")
