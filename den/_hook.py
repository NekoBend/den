"""den hook - what is left of den's per-turn hooks.

den no longer installs hooks or keeps a workspace memory (MIGRATIONS.md,
section 9). Two pieces stay, for the workspaces an older den set up:

  run      the command those hooks still call. A no-op: it reads nothing,
           writes nothing, and answers each tool with the response that tool
           takes for "nothing to add", so a hook that still fires neither
           fails nor blocks the session.
  remove   behind `den uninstall hook`: takes den's hooks and the cline-cli
           rule files back out of a workspace, leaving everything else in the
           files it edits.

Every other subcommand an older den had (install, list, imprint, memory, and
`den hook remove` itself) ends with one line that names the removal.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator

from ._fsafe import _find_den_dir, _symlink_component

_MIGRATIONS = "MIGRATIONS.md, https://github.com/NekoBend/den/blob/main/MIGRATIONS.md"

# stderr prefix of `den uninstall hook`, the one command that edits hooks now.
_ERR = "den uninstall hook"

# Marker embedded in every hook command den wrote, so remove can find and take
# out exactly the entries den owns, leaving foreign hooks alone.
_MARKER = "den hook run"

# The first bytes of both .clinerules files den wrote for cline-cli, in every
# version that wrote them (den-imprint.md: "<!-- den-managed. Edit ...",
# den-memory.md: "<!-- den-managed mirror of .den/memory.md ...").
_CLINERULES_HEADER = b"<!-- den-managed"
_CLINERULES_DIRNAME = ".clinerules"
_CLINERULES_IMPRINT = "den-imprint.md"
_CLINERULES_MEMORY = "den-memory.md"

# Where earlier dens installed each tool's hooks, per workspace.
_TOOLS: dict[str, dict] = {
    "claude": {
        # Claude Code's personal, uncommitted settings file.
        "config": ".claude/settings.local.json",
        # The shared, committed file earlier dens wrote to. remove reads it too.
        "legacy_config": ".claude/settings.json",
        "format": "settings_json",
    },
    "copilot": {
        "config": ".github/hooks/den.json",
        "format": "copilot_json",
    },
    "cline": {
        # The VS Code extension: one script per event, named for the event.
        "config": ".clinerules/hooks",
        "format": "cline_scripts",
        "scripts": ("TaskStart", "UserPromptSubmit", "PostToolUse"),
    },
    "cline-cli": {
        # The cline CLI got .clinerules rule files instead of a hook; `config`
        # is not used (see _remove_clinerules).
        "config": ".clinerules",
        "format": "clinerules",
    },
}


def removed(command: str, instead: str = "") -> int:
    """`command` was removed from den: one line on stderr that says so and
    where to read more, and exit 1. Not 2: Claude Code takes exit 2 from a hook
    for "block the prompt", and a stale hook or script may still call one."""
    hint = f"; {instead}" if instead else ""
    print(
        f"{command}: removed from den (2026-11){hint}; see {_MIGRATIONS}",
        file=sys.stderr,
    )
    return 1


# --------------------------------------------------------------------------- #
# run: the no-op
# --------------------------------------------------------------------------- #

# What each tool takes from a hook for "nothing to add", exactly what `den
# hook run` printed when it had nothing to inject. copilot and cline expect
# JSON on every hook; claude (and codex, which shared its contract) reads
# empty stdout as nothing. cline-cli never had a runtime hook, and a tool this
# den does not know (gemini, retired; a hand-written command) gets nothing.
_NOTHING_TO_ADD = {
    "copilot": "{}",
    "cline": '{"cancel": false}',
}


def _cmd_run(argv: list[str]) -> int:
    """The no-op the hooks an older den installed still call.

    It takes every argument form those hooks carry (`--event E --tool T`, with
    or without `--den-dir D`, from any den version) and any other, reads only
    `--tool` from them, and then reads nothing: no file, no stdin. It writes
    nothing, prints only the tool's "nothing to add" response, and exits 0, so
    a stale hook can neither fail nor block a session."""
    tool = None
    for i, arg in enumerate(argv[:-1]):
        if arg == "--tool":
            tool = argv[i + 1]
    response = _NOTHING_TO_ADD.get(tool or "")
    if response is not None:
        print(response)
    return 0


# --------------------------------------------------------------------------- #
# remove (den uninstall hook)
# --------------------------------------------------------------------------- #


def _leaves_workspace(path: Path) -> bool:
    """True (after one line on stderr) when `path` is under cwd but only reaches
    it through a symlink -- a dangling one included, since `is_symlink()` does not
    care whether the target exists.

    A path OUTSIDE cwd passes: that is an explicit --config, the user's own
    choice. What must not happen is a workspace-relative path leaving the
    workspace, because a cloned repo controls those.
    """
    bad = _symlink_component(Path.cwd(), path)
    if bad is None:
        return False
    print(
        f"{_ERR}: refusing {path}: {bad} is a symlink "
        "(the workspace config must stay in the workspace)",
        file=sys.stderr,
    )
    return True


def _resolve_config(spec: dict, override: str | None) -> Path | None:
    """The config file/dir to operate on, or None (after one line on stderr)
    when the workspace-relative default is unusable.

    An explicit --config is the user's own choice and is taken as given -- but
    RESOLVED, so the paths derived from it are real ones (dotfiles managers
    symlink `~/.claude`).

    The default is workspace-relative, so it must STAY in the workspace: a cloned
    repo that ships `.claude` (or `.claude/settings.local.json`) as a symlink
    would otherwise make remove rewrite the user's GLOBAL hook config.
    """
    if override:
        return Path(override).expanduser().resolve()
    config = Path.cwd() / spec["config"]
    if _leaves_workspace(config):
        return None
    # No symlink component left, so resolve() only normalizes the path.
    return config.resolve()


def _clinerules_dir(den_dir: Path) -> Path:
    return den_dir.parent / _CLINERULES_DIRNAME


def _display_config(spec: dict, config: Path) -> Path:
    """The path a format actually works on, for status messages. Most formats
    operate on `config`, but clinerules ignores it and uses the `.clinerules`
    beside the resolved `.den` (which may be an ancestor's). Report that real
    target so the message never names a dir that was not touched."""
    if spec.get("format") == "clinerules":
        return _clinerules_dir(_find_den_dir(Path.cwd()))
    return config


def _read_json(config: Path) -> dict:
    """Load an existing JSON config, or {} if absent/unreadable/not an object.
    Keeps remove from crashing on a malformed or hand-edited file."""
    if not config.is_file():
        return {}
    try:
        data = json.loads(config.read_text(encoding="utf-8"))
    except (OSError, ValueError):  # ValueError = JSONDecodeError + UnicodeError
        return {}
    return data if isinstance(data, dict) else {}


def _write_config(config: Path, data: dict) -> bool:
    """Write `data` to the existing JSON config at `config` without truncating
    it first: the file is replaced in one rename (_shell._replace_bytes, which
    gives the new file the old one's owner, group and permission bits and, on
    Linux, its extended attributes and ACLs). Written in place, a write that
    failed part-way (a full disk, an I/O error) left the user's settings empty
    or cut short.

    False (one line on stderr) when it cannot be written, and the file is then
    as it was: a write that failed, or a file _replace_bytes refuses, one with
    a second hard link among them (a new copy would take only this name),
    which the user edits by hand, as `den uninstall` leaves such an rc file."""
    # Imported here: the shell installer is not needed for anything else here.
    from ._shell import _replace_bytes

    # Line ends as write_text wrote them: os.linesep (CRLF on Windows).
    raw = (json.dumps(data, indent=2) + "\n").replace("\n", os.linesep)
    try:
        _replace_bytes(config, raw.encode("utf-8"))
    except OSError as e:
        print(f"{_ERR}: left {config} as it was: {e}", file=sys.stderr)
        return False
    return True


def _is_den_hook(hook: object, key: str = "command") -> bool:
    """Whether a hook entry is one den wrote: an object whose command (`key`:
    settings_json's "command", copilot's "bash") is text carrying the marker.
    An entry den never wrote (a command that is null or a number) is not taken
    out, nor makes remove raise."""
    if not isinstance(hook, dict):
        return False
    command = hook.get(key)
    return isinstance(command, str) and _MARKER in command


def _strip_den_hooks(hooks: object) -> object:
    """`hooks` with den's own entries taken out; the argument is not changed.

    Only a hook whose command carries the den marker comes out. Its group stays,
    with its matcher and every other key, while anything is left in it: a hook
    someone added to a group den wrote is theirs. A group goes only when den's
    hooks were all it held, and an event only when that leaves it with no group.
    A shape den never writes (a `hooks` that is not an object, an event whose
    value is not a list) holds nothing den can tell is its own, so it stays as
    it is.

    When nothing of den's is in it, `hooks` itself comes back, whatever its
    shape: remove then leaves the file byte-identical."""
    if not isinstance(hooks, dict):
        return hooks
    cleaned: dict = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            cleaned[event] = groups
            continue
        kept = []
        for group in groups:
            if not isinstance(group, dict):
                kept.append(group)  # not a group, so nothing of den's in it
                continue
            inner = group.get("hooks")
            if not isinstance(inner, list):
                kept.append(group)  # no hook list, so nothing of den's in it
                continue
            rest = [h for h in inner if not _is_den_hook(h)]
            if len(rest) == len(inner):
                kept.append(group)
            elif rest:
                kept.append({**group, "hooks": rest})
        if kept or not groups:
            cleaned[event] = kept
    # Equal exactly when nothing came out: the groups kept are the same objects.
    return hooks if cleaned == hooks else cleaned


def _holds_den_hooks(config: Path) -> bool:
    """Whether the settings_json file at `config` holds a hook den wrote."""
    hooks = _read_json(config).get("hooks")
    return _strip_den_hooks(hooks) is not hooks


def _remove_settings_json(tool: str, spec: dict, config: Path) -> bool:
    if not config.is_file():
        return True
    data = _read_json(config)
    if "hooks" not in data:
        return True
    cleaned = _strip_den_hooks(data["hooks"])
    if cleaned is data["hooks"]:
        return True  # nothing of den's: leave the file byte-identical
    data["hooks"] = cleaned
    if not data["hooks"]:
        del data["hooks"]
    return _write_config(config, data)


# --- copilot: flat {version, hooks:{event:[{type,bash}]}}, marker in "bash" --- #


def _strip_copilot(hooks: object) -> object:
    """_strip_den_hooks for copilot's flat event lists: only an entry whose
    `bash` is den's comes out, every other entry stays (one that is not an
    object, or whose `bash` is not text, included), and an event goes only when
    den's entries were all it held. A shape den never writes stays as it is, and
    when nothing of den's is in it, `hooks` itself comes back."""
    if not isinstance(hooks, dict):
        return hooks
    cleaned: dict = {}
    for event, arr in hooks.items():
        if not isinstance(arr, list):
            cleaned[event] = arr
            continue
        kept = [h for h in arr if not _is_den_hook(h, "bash")]
        if kept or not arr:
            cleaned[event] = kept
    # Equal exactly when nothing came out: the entries kept are the same objects.
    return hooks if cleaned == hooks else cleaned


def _remove_copilot(tool: str, spec: dict, config: Path) -> bool:
    if not config.is_file():
        return True
    data = _read_json(config)
    if "hooks" not in data:
        return True
    cleaned = _strip_copilot(data["hooks"])
    if cleaned is data["hooks"]:
        return True  # nothing of den's: leave the file byte-identical
    data["hooks"] = cleaned
    if not data["hooks"]:
        del data["hooks"]
    return _write_config(config, data)


# --- cline: one executable script per event, named exactly the event name --- #


def _cline_scripts(spec: dict, config: Path) -> Iterator[Path]:
    # Both names, whichever platform installed: extensionless on Unix, .ps1 on
    # Windows.
    for native in spec["scripts"]:
        for cand in (native, f"{native}.ps1"):
            script = config / cand
            if script.is_file() and _MARKER in script.read_text(
                encoding="utf-8", errors="ignore"
            ):
                yield script


def _remove_cline(tool: str, spec: dict, config: Path) -> bool:
    if not config.is_dir():
        return True
    for script in list(_cline_scripts(spec, config)):
        script.unlink()
    return True


# --- cline-cli: the .clinerules rule files den wrote (no hook) --- #
#
# These ignore the passed `config` and always use the `.clinerules/` beside the
# resolved `.den/`, because that is where den wrote them (`--config` is
# meaningless for this format). cline keeps loading every `.clinerules/*.md` as
# an always-on rule, so a stale imprint or memory copy left there keeps
# reaching the model after den stopped refreshing it.


def _clinerules_targets(den_dir: Path) -> list[Path] | None:
    """The two rule files this format wrote, or None (one line on stderr) when
    the `.clinerules` dir is not usable as one, or a symlink sits at it or at
    either file.

    The dir is derived HERE, the way the format itself derived it: beside the
    resolved `.den`, which may be an ANCESTOR's while cwd is a subdirectory. That
    is not the path `_resolve_config` vetted, so an ancestor `.clinerules`
    symlink would sail past that guard, and remove would then unlink real
    den-imprint.md / den-memory.md files outside the workspace through it.
    """
    rules = _clinerules_dir(den_dir)
    if rules.is_symlink():
        print(f"{_ERR}: refusing {rules}: it is a symlink", file=sys.stderr)
        return None
    if rules.exists() and not rules.is_dir():
        print(f"{_ERR}: refusing {rules}: it is not a directory", file=sys.stderr)
        return None
    targets = [rules / _CLINERULES_IMPRINT, rules / _CLINERULES_MEMORY]
    for path in targets:
        if path.is_symlink():
            print(f"{_ERR}: refusing {path}: it is a symlink", file=sys.stderr)
            return None
        if path.exists() and not path.is_file():
            # A DIRECTORY at den-memory.md let remove unlink the imprint and
            # report success while the invalid target stayed. Stop here, before
            # anything is half-done.
            print(f"{_ERR}: refusing {path}: not a regular file", file=sys.stderr)
            return None
    return targets


def _is_dens_rule(path: Path) -> bool:
    """Whether the rule file at `path` is one den wrote: it starts (after a
    UTF-8 BOM an editor may have added) with den's header. A file there that
    does not is someone else's, and stays as it is. A file that cannot be read
    is neither: the OSError goes to the caller."""
    with path.open("rb") as fh:
        head = fh.read(len(_CLINERULES_HEADER) + 3)
    return head.removeprefix(b"\xef\xbb\xbf").startswith(_CLINERULES_HEADER)


def _single_file_clinerules(den_dir: Path) -> bool:
    """True when `.clinerules` is a regular file: cline's classic single-file
    rules format, so cline-cli (which needs the directory) was never installed
    here. remove takes that as "nothing of den's" and stays quiet."""
    rules = _clinerules_dir(den_dir)
    return not rules.is_symlink() and rules.is_file()


def _remove_clinerules(tool: str, spec: dict, config: Path) -> bool:
    # `config` is ignored by this format (see the section comment above), so the
    # path _resolve_config vetted is not the one being unlinked here. Derive and
    # guard the real one, or the unlinks follow a planted link out of the
    # workspace and destroy someone else's files.
    den_dir = _find_den_dir(Path.cwd())
    if _single_file_clinerules(den_dir):
        return True
    targets = _clinerules_targets(den_dir)
    if targets is None:
        return False
    # Every header is read before anything goes: a file that cannot be read
    # was taken for someone else's, so den's stale copy stayed loaded and
    # uninstall reported success. Now it refuses and touches nothing.
    dens = []
    for path in targets:
        if not path.is_file():
            continue
        try:
            ours = _is_dens_rule(path)
        except OSError as e:
            print(
                f"{_ERR}: refusing {path}: cannot read it to tell whether den "
                f"wrote it ({e.strerror or e})",
                file=sys.stderr,
            )
            return False
        if ours:
            dens.append(path)
        else:
            print(
                f"{_ERR}: left {path}: it does not start with den's header, "
                "so it is not a file den wrote",
                file=sys.stderr,
            )
    for path in dens:
        path.unlink()
    return True


# --- claude's earlier config location --- #


def _legacy_config(spec: dict, override: str | None) -> Path | None:
    """The workspace file earlier dens wrote this tool's hooks to, when that has
    moved since (claude: .claude/settings.json -> settings.local.json), or None.
    An explicit --config names the one file to use, so it has no legacy file."""
    name = spec.get("legacy_config")
    return None if override or not name else Path.cwd() / name


def _strip_legacy(tool: str, spec: dict, override: str | None) -> bool:
    """Remove den's entries from the legacy file, leaving everything else in it.

    True when nothing of den's is (left) there, and a file without den entries
    stays byte-identical. False (one line on stderr) when den's entries are
    there but the path reaches a symlink: a repo can ship
    `.claude/settings.json` -> ~/.claude/settings.json, and stripping through it
    would rewrite the user's global settings. A symlinked file WITHOUT den's
    entries (or a dangling link) is not den's file any more and passes quietly;
    reading through the link to find that out writes nothing.
    """
    legacy = _legacy_config(spec, override)
    if legacy is None or not (legacy.is_file() or legacy.is_symlink()):
        return True
    if _symlink_component(Path.cwd(), legacy) is not None:
        if not legacy.is_file() or not _holds_den_hooks(legacy.resolve()):
            return True
        _leaves_workspace(legacy)  # says why on stderr
        return False
    legacy = legacy.resolve()
    if not _holds_den_hooks(legacy):
        return True
    if not _remove_settings_json(tool, spec, legacy):
        return False
    print(f"{_ERR}: {legacy} held den's {tool} hooks; removed them", file=sys.stderr)
    return True


# format -> remove
_FORMATS = {
    "settings_json": _remove_settings_json,
    "copilot_json": _remove_copilot,
    "cline_scripts": _remove_cline,
    "clinerules": _remove_clinerules,
}


def _parse_tool_args(argv: list[str]) -> tuple[list[str] | None, str | None]:
    """(tools, --config) from argv; every tool when none is named. --all-tools
    adds every tool to the --tool list."""
    tools: list[str] = []
    override: str | None = None
    i = 0
    while i < len(argv):
        if argv[i] == "--tool" and i + 1 < len(argv):
            name = argv[i + 1]
            if name not in _TOOLS:
                print(f"{_ERR}: unknown tool '{name}'", file=sys.stderr)
                return None, None
            if name not in tools:
                tools.append(name)
            i += 2
        elif argv[i] == "--all-tools":
            tools += [t for t in _TOOLS if t not in tools]
            i += 1
        elif argv[i] == "--config" and i + 1 < len(argv):
            override = argv[i + 1]
            i += 2
        else:
            print(f"{_ERR}: unexpected arg '{argv[i]}'", file=sys.stderr)
            return None, None
    return tools or list(_TOOLS), override


def _cmd_remove(argv: list[str]) -> int:
    """`den uninstall hook`: take den's hooks out of the current workspace."""
    tools, override = _parse_tool_args(argv)
    if tools is None:
        return 2
    rc = 0
    for tool in tools:
        spec = _TOOLS[tool]
        config = _resolve_config(spec, override)
        if config is None:  # symlinked workspace config: refuse, touch nothing
            rc = 1
            continue
        if not _FORMATS[spec["format"]](tool, spec, config):
            rc = 1  # the remover refused and touched nothing; it said why
            continue
        print(
            f"removed den hooks from {tool} -> {_display_config(spec, config)}",
            file=sys.stderr,
        )
        if not _strip_legacy(tool, spec, override):
            rc = 1
    return rc


# --------------------------------------------------------------------------- #
# dispatch
# --------------------------------------------------------------------------- #

# Subcommands an older den had, and what to use instead where something does.
_REMOVED = {
    "install": "'den uninstall hook' removes what it installed",
    "remove": "use 'den uninstall hook'",
    "list": "",
    "imprint": "",
    "memory": "",
}


def _usage() -> None:
    print(
        "usage: den hook run [args]\n"
        "\n"
        "den no longer installs hooks. 'den hook run' stays as a no-op for the\n"
        "hooks an older den installed: it answers each tool with an empty\n"
        "response. Run 'den uninstall hook' in each workspace that has them.\n"
        "See MIGRATIONS.md."
    )


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]

    if not args or args[0] in {"-h", "--help", "help"}:
        _usage()
        return 0

    cmd, rest = args[0], args[1:]
    if cmd == "run":
        return _cmd_run(rest)
    if cmd in _REMOVED:
        return removed(f"den hook {cmd}", _REMOVED[cmd])
    print(f"den hook: unknown subcommand '{cmd}'", file=sys.stderr)
    _usage()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
