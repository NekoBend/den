"""den hook - install per-tool hooks that imprint context every turn.

Soft enforcement only: these hooks never block a tool call. Each turn the
agent's tool runs `den hook run`, which injects two things as additional
context and then checkpoints memory:

  .den/imprint.md   static, human-owned directives that must not fall out of
                    context (read the skill, use a subagent, record memory).
  .den/memory.md    agent-owned, overwritable session memory (via den memory).

Because weak models forget on-demand instructions, the per-turn hook re-injects
both every turn. checkpoint runs first so the previous turn's direct edits to
memory.md are captured before this turn proceeds.

Subcommands:
  run --event E --tool T   worker the tool invokes; prints injection for T
  install [--tool T ...]    register hooks into each tool's config
          [--all-tools] [--config PATH]
  imprint                   print the composed injection (imprint + memory)
  list [--config PATH]      show den-managed hooks per tool
  remove [--tool T ...]     unregister den-managed hooks
         [--config PATH]

Generic events (mapped to each tool's own event names): session-start,
per-turn, post-tool, stop.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from _memory import _do_checkpoint, _find_den_dir, _memory_path

_IMPRINT_NAME = "imprint.md"

# Marker embedded in every den-managed hook command so install/list/remove can
# find and replace exactly the entries den owns, leaving foreign hooks alone.
_MARKER = "den hook run"

_DEFAULT_IMPRINT = """\
# Imprint (always-on directives)

These directives apply every turn. Do not let them fall out of context.

- Before writing code, check whether a skill applies and read its SKILL.md.
- For multi step or broad tasks, delegate to a subagent instead of doing
  everything inline.
- Record durable decisions and project facts in .den/memory.md so they
  survive across turns; keep it current and overwrite it wholesale.
- State assumptions explicitly; ask before assuming when scope is ambiguous.
"""

# Per-tool registry. event map: generic name -> the tool's own event name.
# verified=False tools are scaffolded but refuse install/run until their hook
# output contract has been checked against the real CLI.
_TOOLS: dict[str, dict] = {
    "claude": {
        "config": "~/.claude/settings.json",
        "emit": "claude",
        "format": "settings_json",
        "events": {
            "session-start": "SessionStart",
            "per-turn": "UserPromptSubmit",
            "post-tool": "PostToolUse",
            "stop": "Stop",
        },
        "post_tool_matcher": "Write|Edit|MultiEdit",
        "verified": True,
    },
    "gemini": {
        "config": "~/.gemini/settings.json",
        "emit": "gemini",
        "format": "settings_json",
        "events": {
            "session-start": "SessionStart",
            "per-turn": "BeforeAgent",
            "post-tool": "AfterTool",
            "stop": "SessionEnd",
        },
        "verified": True,
    },
    "codex": {
        "config": "~/.codex/hooks.json",
        "emit": "codex",
        "events": {
            "session-start": "SessionStart",
            "per-turn": "UserPromptSubmit",
            "post-tool": "PostToolUse",
            "stop": "Stop",
        },
        "verified": False,
    },
    "copilot": {
        "config": "~/.copilot/hooks.json",
        "emit": "copilot",
        "events": {
            "session-start": "sessionStart",
            "per-turn": "userPromptSubmitted",
            "post-tool": "postToolUse",
            "stop": "sessionEnd",
        },
        "verified": False,
    },
    "cline": {
        "config": "~/Documents/Cline/Rules/Hooks/den.json",
        "emit": "cline",
        "events": {
            "session-start": "TaskStart",
            "per-turn": "UserPromptSubmit",
            "post-tool": "PostToolUse",
            "stop": "TaskCancel",
        },
        "verified": False,
    },
}

_INJECT_EVENTS = ("session-start", "per-turn")  # events that emit context


# --------------------------------------------------------------------------- #
# composition
# --------------------------------------------------------------------------- #


def _imprint_path(den_dir: Path) -> Path:
    return den_dir / _IMPRINT_NAME


def _compose(den_dir: Path) -> str:
    """Build the injection: imprint then memory, each in a tagged block.

    Empty / missing sources are skipped. Returns "" when both are empty.
    """
    blocks: list[str] = []

    imprint = _imprint_path(den_dir)
    if imprint.is_file():
        text = imprint.read_text(encoding="utf-8").strip()
        if text:
            blocks.append(f"<den:imprint>\n{text}\n</den:imprint>")

    mem = _memory_path(den_dir)
    if mem.is_file():
        text = mem.read_text(encoding="utf-8").strip()
        if text:
            blocks.append(f"<den:memory>\n{text}\n</den:memory>")

    return "\n\n".join(blocks)


# --------------------------------------------------------------------------- #
# per-tool output emitters
# --------------------------------------------------------------------------- #


def _emit_hookspecific(event_name: str, text: str) -> None:
    """stdout JSON with hookSpecificOutput.additionalContext (exit 0).

    Shared by Claude Code and Gemini CLI: both parse exit-0 stdout as JSON and
    append additionalContext to the turn. Verified end to end against both.
    """
    if not text:
        return
    out = {
        "hookSpecificOutput": {
            "hookEventName": event_name,
            "additionalContext": text,
        }
    }
    print(json.dumps(out))


_EMITTERS = {
    "claude": _emit_hookspecific,
    "gemini": _emit_hookspecific,
}


# --------------------------------------------------------------------------- #
# run
# --------------------------------------------------------------------------- #


def _cmd_run(argv: list[str]) -> int:
    event, tool = _parse_run_args(argv)
    if event is None or tool is None:
        return 2

    spec = _TOOLS.get(tool)
    if spec is None:
        print(f"den hook run: unknown tool '{tool}'", file=sys.stderr)
        return 2
    if event not in spec["events"]:
        print(f"den hook run: tool '{tool}' has no event '{event}'", file=sys.stderr)
        return 2

    den_dir = _find_den_dir(Path.cwd())

    # Always checkpoint: captures the previous turn's direct edits to memory.md.
    # Cheap and content-gated, so unconditional is fine on every event.
    _do_checkpoint(den_dir)

    if event in _INJECT_EVENTS:
        emit = _EMITTERS.get(spec["emit"])
        if emit is None:
            # Fallback for tools whose emitter is not implemented yet: plain
            # stdout. Many tools inject stdout on exit 0; verify before relying.
            text = _compose(den_dir)
            if text:
                sys.stdout.write(text + "\n")
        else:
            emit(spec["events"][event], _compose(den_dir))

    return 0


def _parse_run_args(argv: list[str]) -> tuple[str | None, str | None]:
    event = tool = None
    i = 0
    while i < len(argv):
        if argv[i] == "--event" and i + 1 < len(argv):
            event = argv[i + 1]
            i += 2
        elif argv[i] == "--tool" and i + 1 < len(argv):
            tool = argv[i + 1]
            i += 2
        else:
            print(f"den hook run: unexpected arg '{argv[i]}'", file=sys.stderr)
            return None, None
    if event is None or tool is None:
        print("den hook run: --event and --tool are required", file=sys.stderr)
        return None, None
    return event, tool


# --------------------------------------------------------------------------- #
# install / list / remove
#
# claude and gemini share format "settings_json": a settings.json with a hooks
# object keyed by native event name. codex/copilot/cline use other formats and
# are not wired yet.
# --------------------------------------------------------------------------- #


def _resolve_config(spec: dict, override: str | None) -> Path:
    return (
        Path(override).expanduser() if override else Path(spec["config"]).expanduser()
    )


def _settings_entries(tool: str, spec: dict) -> dict[str, list]:
    """Build the per-event hook entries den manages for a settings_json config."""
    entries: dict[str, list] = {}
    for generic, native in spec["events"].items():
        cmd = f"den hook run --event {generic} --tool {tool}"
        entry: dict = {"hooks": [{"type": "command", "command": cmd}]}
        if generic == "post-tool" and spec.get("post_tool_matcher"):
            entry["matcher"] = spec["post_tool_matcher"]
        entries.setdefault(native, []).append(entry)
    return entries


def _strip_den_hooks(hooks: dict) -> dict:
    """Drop every hook group whose command contains the den marker."""
    cleaned: dict[str, list] = {}
    for event, groups in hooks.items():
        kept = [
            g
            for g in groups
            if not any(_MARKER in h.get("command", "") for h in g.get("hooks", []))
        ]
        if kept:
            cleaned[event] = kept
    return cleaned


def _install_settings_json(tool: str, spec: dict, config: Path) -> None:
    data: dict = {}
    if config.is_file():
        data = json.loads(config.read_text(encoding="utf-8"))
    hooks = _strip_den_hooks(data.get("hooks", {}))
    for event, groups in _settings_entries(tool, spec).items():
        hooks.setdefault(event, []).extend(groups)
    data["hooks"] = hooks
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


_INSTALLERS = {
    "settings_json": _install_settings_json,
}


def _seed_imprint(den_dir: Path) -> bool:
    """Create .den/imprint.md with defaults if absent. Returns True if seeded."""
    path = _imprint_path(den_dir)
    if path.is_file():
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(_DEFAULT_IMPRINT, encoding="utf-8")
    return True


def _cmd_install(argv: list[str]) -> int:
    tools, override = _parse_tool_args(argv)
    if tools is None:
        return 2

    den_dir = _find_den_dir(Path.cwd())
    if _seed_imprint(den_dir):
        print(f"seeded {_imprint_path(den_dir)}", file=sys.stderr)

    rc = 0
    for tool in tools:
        spec = _TOOLS[tool]
        installer = _INSTALLERS.get(spec.get("format", ""))
        if not spec["verified"] or installer is None:
            print(
                f"den hook install: '{tool}' is not verified yet; skipping. "
                f"Verified so far: claude, gemini.",
                file=sys.stderr,
            )
            rc = 1
            continue
        config = _resolve_config(spec, override)
        installer(tool, spec, config)
        print(f"installed {tool} hooks -> {config}", file=sys.stderr)
    return rc


def _cmd_list(argv: list[str]) -> int:
    tools, override = _parse_tool_args(argv, default_all=True)
    if tools is None:
        return 2
    for tool in tools:
        spec = _TOOLS[tool]
        config = _resolve_config(spec, override)
        if not config.is_file():
            continue
        try:
            data = json.loads(config.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        for event, groups in data.get("hooks", {}).items():
            for g in groups:
                for h in g.get("hooks", []):
                    if _MARKER in h.get("command", ""):
                        print(f"{tool}  {event}  {h['command']}")
    return 0


def _cmd_remove(argv: list[str]) -> int:
    tools, override = _parse_tool_args(argv, default_all=True)
    if tools is None:
        return 2
    for tool in tools:
        spec = _TOOLS[tool]
        config = _resolve_config(spec, override)
        if not config.is_file():
            continue
        data = json.loads(config.read_text(encoding="utf-8"))
        if "hooks" not in data:
            continue
        data["hooks"] = _strip_den_hooks(data["hooks"])
        if not data["hooks"]:
            del data["hooks"]
        config.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        print(f"removed den hooks from {tool} -> {config}", file=sys.stderr)
    return 0


def _cmd_imprint(argv: list[str]) -> int:
    den_dir = _find_den_dir(Path.cwd())
    text = _compose(den_dir)
    if text:
        sys.stdout.write(text + "\n")
    return 0


def _parse_tool_args(
    argv: list[str], default_all: bool = False
) -> tuple[list[str] | None, str | None]:
    tools: list[str] = []
    override: str | None = None
    i = 0
    while i < len(argv):
        if argv[i] == "--tool" and i + 1 < len(argv):
            name = argv[i + 1]
            if name not in _TOOLS:
                print(f"den hook: unknown tool '{name}'", file=sys.stderr)
                return None, None
            tools.append(name)
            i += 2
        elif argv[i] == "--all-tools":
            tools = list(_TOOLS)
            i += 1
        elif argv[i] == "--config" and i + 1 < len(argv):
            override = argv[i + 1]
            i += 2
        else:
            print(f"den hook: unexpected arg '{argv[i]}'", file=sys.stderr)
            return None, None
    if not tools:
        tools = list(_TOOLS) if default_all else ["claude"]
    return tools, override


# --------------------------------------------------------------------------- #
# dispatch
# --------------------------------------------------------------------------- #


_HANDLERS = {
    "run": _cmd_run,
    "install": _cmd_install,
    "list": _cmd_list,
    "remove": _cmd_remove,
    "imprint": _cmd_imprint,
}


def _usage() -> None:
    print(
        "usage: den hook <subcommand> [args]\n"
        "\n"
        "Subcommands:\n"
        "  run --event E --tool T   worker the tool invokes (prints injection)\n"
        "  install [--tool T] [--all-tools] [--config PATH]\n"
        "  imprint                  print composed injection (imprint + memory)\n"
        "  list [--config PATH]     show den-managed hooks\n"
        "  remove [--tool T] [--config PATH]\n"
        "\n"
        "Events: session-start, per-turn, post-tool, stop.\n"
        "Only 'claude' is verified end to end; other tools are scaffolded."
    )


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]

    if not args or args[0] in ("-h", "--help", "help"):
        _usage()
        return 0

    cmd, rest = args[0], args[1:]
    handler = _HANDLERS.get(cmd)
    if handler is None:
        print(f"den hook: unknown subcommand '{cmd}'", file=sys.stderr)
        _usage()
        return 2
    return handler(rest)


if __name__ == "__main__":
    raise SystemExit(main())
