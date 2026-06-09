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

Hooks install per WORKSPACE: `install` writes each tool's project-level hook
config (e.g. .claude/settings.json, .clinerules/hooks/) under the current
directory and seeds <cwd>/.den/imprint.md, so hook + imprint + memory all share
one .den scope. Run it once inside each workspace you want imprinting in.

Subcommands:
  run --event E --tool T   worker the tool invokes; prints injection for T
  install [--tool T ...]    register hooks into the workspace (cwd)
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
import os
import sys
from pathlib import Path

from ._memory import (
    _CLINERULES_IMPRINT,
    _CLINERULES_MEMORY,
    _clinerules_dir,
    _do_checkpoint,
    _find_den_dir,
    _memory_path,
    mirror_to_clinerules,
)

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
- When you make a durable decision or learn a project fact, append it that
  same turn with: den memory add "<the fact>" (one line, low effort). For a
  larger cleanup, overwrite .den/memory.md wholesale.
- State assumptions explicitly; ask before assuming when scope is ambiguous.
"""

# Per-tool registry. event map: generic name -> the tool's own event name.
# verified=False tools are scaffolded but refuse install/run until their hook
# output contract has been checked against the real CLI.
_TOOLS: dict[str, dict] = {
    "claude": {
        "config": ".claude/settings.json",
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
        "config": ".gemini/settings.json",
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
    # codex: DEFERRED. The output contract is the same as claude/gemini
    # (UserPromptSubmit/SessionStart with hookSpecificOutput.additionalContext;
    # confirmed in the codex binary's hook schema), so `emit` could reuse the
    # hookspecific emitter. The blocker is DELIVERY: codex has no direct hooks
    # config file. Hooks ship only inside a PLUGIN (plugin.json -> hooks.json),
    # installed from a registered marketplace via `codex plugin marketplace add`
    # + `codex plugin add NAME@MARKETPLACE`, and gated by hook trust
    # (`--dangerously-bypass-hook-trust`). Implementing a "codex_plugin" format
    # means generating that plugin tree + a local marketplace and driving those
    # commands. Left verified=False until that is built and live-tested.
    "codex": {
        "config": "~/.codex/plugins",  # plugin install root (not a direct file)
        "emit": "claude",  # same hookSpecificOutput.additionalContext contract
        "events": {
            "session-start": "SessionStart",
            "per-turn": "UserPromptSubmit",
            "post-tool": "PostToolUse",
            "stop": "Stop",
        },
        "verified": False,
    },
    "copilot": {
        "config": ".github/hooks/den.json",
        "emit": "copilot",
        "format": "copilot_json",
        # userPromptSubmitted is notification-only (cannot inject), so the
        # imprint loads once at sessionStart; per-turn only drives checkpoint.
        "events": {
            "session-start": "sessionStart",
            "per-turn": "userPromptSubmitted",
            "post-tool": "postToolUse",
        },
        "verified": True,
    },
    "cline": {
        # The VS Code EXTENSION. It runs workspace project hooks and DOES inject
        # `contextModification` per turn (apps/vscode .../task: wraps it in a
        # <hook_context> block), gated by the extension's `hooksEnabled` setting.
        # Workspace-local so hook + imprint + memory share one .den scope.
        "config": ".clinerules/hooks",
        "emit": "cline",
        "format": "cline_scripts",
        "events": {
            "session-start": "TaskStart",
            "per-turn": "UserPromptSubmit",
            "post-tool": "PostToolUse",
        },
        "verified": True,
    },
    "cline-cli": {
        # The cline CLI canNOT inject context via hooks: its file hooks are
        # observe-only (prompt_submit/agent_start are fire-and-forget) and the one
        # applied control is cancel/overrideInput on tool_call -- context /
        # contextModification are parsed then ignored (verified in cline/cline
        # sdk/packages/core .../hook-file-hooks.ts). It DOES load .clinerules/*.md
        # as always-on rules at session start, so den delivers the imprint + memory
        # as rule files there instead of a hook. There is no `den hook run` for it.
        "config": ".clinerules",
        "format": "clinerules",
        "events": {},
        "verified": True,
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


def _emit_copilot(event_name: str, text: str) -> None:
    """stdout JSON for Copilot CLI. additionalContext injects on sessionStart
    (and postToolUse); other events ignore output. {} means no-op."""
    out: dict = {}
    if text:
        out["additionalContext"] = text
    print(json.dumps(out))


def _emit_cline(event_name: str, text: str) -> None:
    """stdout JSON for Cline. contextModification injects into the conversation;
    cancel=false always allows the turn. Cline expects a JSON response."""
    out: dict = {"cancel": False}
    if text:
        out["contextModification"] = text
    print(json.dumps(out))


_EMITTERS = {
    "claude": _emit_hookspecific,
    "gemini": _emit_hookspecific,
    "copilot": _emit_copilot,
    "cline": _emit_cline,
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
    if spec.get("format") == "clinerules":
        print(
            f"den hook run: '{tool}' delivers via .clinerules rule files, not a "
            "runtime hook",
            file=sys.stderr,
        )
        return 0
    if event not in spec["events"]:
        print(f"den hook run: tool '{tool}' has no event '{event}'", file=sys.stderr)
        return 2

    den_dir = _find_den_dir(Path.cwd())

    # Always checkpoint: captures the previous turn's direct edits to memory.md.
    # Cheap and content-gated, so unconditional is fine on every event.
    _do_checkpoint(den_dir)

    # Inject only on inject-events; other events still get an (empty) response
    # because some tools (cline, copilot) require valid JSON on every hook.
    # copilot's per-turn (userPromptSubmitted) is notification-only, so do not
    # compose for it -- it injects only at session-start.
    inject = event in _INJECT_EVENTS and not (tool == "copilot" and event == "per-turn")
    text = _compose(den_dir) if inject else ""
    emit = _EMITTERS.get(spec["emit"])
    if emit is None:
        # Fallback for tools whose emitter is not implemented yet: plain stdout.
        if text:
            sys.stdout.write(text + "\n")
    else:
        emit(spec["events"][event], text)

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
    if override:
        return Path(override).expanduser()
    # config is a workspace-relative path; resolve against the current dir so
    # hooks land in the project being set up (alongside its .den/).
    return (Path.cwd() / spec["config"]).resolve()


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


def _read_json(config: Path) -> dict:
    """Load an existing JSON config, or {} if absent/unreadable/not an object.
    Keeps install/remove from crashing on a malformed or hand-edited file."""
    if not config.is_file():
        return {}
    try:
        data = json.loads(config.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _strip_den_hooks(hooks: dict) -> dict:
    """Drop every hook group whose command contains the den marker."""
    if not isinstance(hooks, dict):
        return {}
    cleaned: dict[str, list] = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        kept = [
            g
            for g in groups
            if isinstance(g, dict)
            and not any(_MARKER in h.get("command", "") for h in g.get("hooks", []))
        ]
        if kept:
            cleaned[event] = kept
    return cleaned


def _install_settings_json(tool: str, spec: dict, config: Path) -> None:
    data = _read_json(config)
    hooks = _strip_den_hooks(data.get("hooks", {}))
    for event, groups in _settings_entries(tool, spec).items():
        hooks.setdefault(event, []).extend(groups)
    data["hooks"] = hooks
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def _list_settings_json(tool: str, spec: dict, config: Path) -> list[str]:
    hooks = _read_json(config).get("hooks", {})
    if not isinstance(hooks, dict):
        return []
    lines = []
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        for g in groups:
            if not isinstance(g, dict):
                continue
            for h in g.get("hooks", []):
                if isinstance(h, dict) and _MARKER in h.get("command", ""):
                    lines.append(f"{tool}  {event}  {h['command']}")
    return lines


def _remove_settings_json(tool: str, spec: dict, config: Path) -> None:
    if not config.is_file():
        return
    data = _read_json(config)
    if "hooks" not in data:
        return
    data["hooks"] = _strip_den_hooks(data["hooks"])
    if not data["hooks"]:
        del data["hooks"]
    config.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


# --- copilot: flat {version, hooks:{event:[{type,bash}]}}, marker in "bash" --- #


def _strip_copilot(hooks: dict) -> dict:
    if not isinstance(hooks, dict):
        return {}
    cleaned: dict[str, list] = {}
    for event, arr in hooks.items():
        if not isinstance(arr, list):
            continue
        kept = [
            h for h in arr if isinstance(h, dict) and _MARKER not in h.get("bash", "")
        ]
        if kept:
            cleaned[event] = kept
    return cleaned


def _install_copilot(tool: str, spec: dict, config: Path) -> None:
    data = _read_json(config)
    data["version"] = data.get("version", 1)
    hooks = _strip_copilot(data.get("hooks", {}))
    for generic, native in spec["events"].items():
        cmd = f"den hook run --event {generic} --tool {tool}"
        hooks.setdefault(native, []).append({"type": "command", "bash": cmd})
    data["hooks"] = hooks
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def _list_copilot(tool: str, spec: dict, config: Path) -> list[str]:
    hooks = _read_json(config).get("hooks", {})
    if not isinstance(hooks, dict):
        return []
    return [
        f"{tool}  {event}  {h['bash']}"
        for event, arr in hooks.items()
        if isinstance(arr, list)
        for h in arr
        if isinstance(h, dict) and _MARKER in h.get("bash", "")
    ]


def _remove_copilot(tool: str, spec: dict, config: Path) -> None:
    if not config.is_file():
        return
    data = _read_json(config)
    if "hooks" not in data:
        return
    data["hooks"] = _strip_copilot(data["hooks"])
    if not data["hooks"]:
        del data["hooks"]
    config.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


# --- cline: one executable script per event, named exactly the event name --- #


def _is_windows() -> bool:
    # Indirection so tests can flip platform without touching os.name globally
    # (pathlib reads os.name to pick WindowsPath/PosixPath).
    return os.name == "nt"


def _cline_script_name(native: str) -> str:
    """Cline reads <Event>.ps1 (PowerShell) on Windows, extensionless <Event>
    (executable bash) on macOS/Linux."""
    return f"{native}.ps1" if _is_windows() else native


def _install_cline(tool: str, spec: dict, config: Path) -> None:
    config.mkdir(parents=True, exist_ok=True)
    for generic, native in spec["events"].items():
        script = config / _cline_script_name(native)
        if script.exists() and _MARKER not in script.read_text(
            encoding="utf-8", errors="ignore"
        ):
            print(
                f"den hook install: {script} exists and is not den-managed; skipping",
                file=sys.stderr,
            )
            continue
        cmd = f"den hook run --event {generic} --tool {tool}"
        if _is_windows():
            # PowerShell hook: Cline runs <Event>.ps1 and reads its stdout JSON.
            script.write_text(
                f"# {_MARKER} (den-managed; do not edit)\n{cmd}\n",
                encoding="utf-8",
            )
        else:
            script.write_text(
                f"#!/usr/bin/env bash\n# {_MARKER} (den-managed; do not edit)\nexec {cmd}\n",
                encoding="utf-8",
            )
            script.chmod(0o755)


def _cline_scripts(spec: dict, config: Path):
    # Check both names so list/remove work regardless of the platform that
    # installed (extensionless on Unix, .ps1 on Windows).
    for native in spec["events"].values():
        for cand in (native, f"{native}.ps1"):
            script = config / cand
            if script.is_file() and _MARKER in script.read_text(
                encoding="utf-8", errors="ignore"
            ):
                yield native, script


def _list_cline(tool: str, spec: dict, config: Path) -> list[str]:
    if not config.is_dir():
        return []
    return [
        f"{tool}  {native}  {script}" for native, script in _cline_scripts(spec, config)
    ]


def _remove_cline(tool: str, spec: dict, config: Path) -> None:
    if not config.is_dir():
        return
    for _native, script in _cline_scripts(spec, config):
        script.unlink()


# --- cline-cli: deliver imprint + memory as .clinerules rule files (no hook) --- #
#
# These ignore the passed `config` and always use the workspace's `.clinerules/`
# (beside `.den/`), because that is the only place cline reads rules from -- and
# the memory mirror (`den memory`) targets the same dir, so imprint + memory stay
# colocated. (`--config` is meaningless for this format.)

_CLINERULES_RULE_HEADER = (
    "<!-- den-managed. Edit .den/imprint.md, then re-run "
    "`den hook install --tool cline-cli`. -->\n\n"
)


def _install_clinerules(tool: str, spec: dict, config: Path) -> None:
    den_dir = _find_den_dir(Path.cwd())
    rules = _clinerules_dir(den_dir)
    rules.mkdir(parents=True, exist_ok=True)
    imprint = _imprint_path(den_dir)
    if imprint.is_file():
        # The imprint rule is also the cline-cli marker mirror_to_clinerules gates
        # on, so write it BEFORE mirroring the memory.
        (rules / _CLINERULES_IMPRINT).write_text(
            _CLINERULES_RULE_HEADER + imprint.read_text(encoding="utf-8"),
            encoding="utf-8",
        )
    mirror_to_clinerules(den_dir)


def _list_clinerules(tool: str, spec: dict, config: Path) -> list[str]:
    rules = _clinerules_dir(_find_den_dir(Path.cwd()))
    out = []
    for name in (_CLINERULES_IMPRINT, _CLINERULES_MEMORY):
        p = rules / name
        if p.is_file():
            out.append(f"{tool}  {name}  {p}")
    return out


def _remove_clinerules(tool: str, spec: dict, config: Path) -> None:
    rules = _clinerules_dir(_find_den_dir(Path.cwd()))
    for name in (_CLINERULES_IMPRINT, _CLINERULES_MEMORY):
        p = rules / name
        if p.is_file():
            p.unlink()


# format -> (install, list, remove)
_FORMATS = {
    "settings_json": (
        _install_settings_json,
        _list_settings_json,
        _remove_settings_json,
    ),
    "copilot_json": (_install_copilot, _list_copilot, _remove_copilot),
    "cline_scripts": (_install_cline, _list_cline, _remove_cline),
    "clinerules": (_install_clinerules, _list_clinerules, _remove_clinerules),
}


def _seed_imprint(den_dir: Path) -> bool:
    """Create .den/imprint.md with defaults if absent. Returns True if seeded."""
    path = _imprint_path(den_dir)
    if path.is_file():
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(_DEFAULT_IMPRINT, encoding="utf-8")
    return True


def _pick_tools_interactive() -> list[str] | None:
    """Ask which tools to install hooks for (checkbox). Returns --tool flags,
    or None if nothing was selected."""
    from . import _ui

    _ui.say("den hook install -- per-turn imprint hooks in this workspace.")
    chosen = _ui.select(
        "Which tools? (space to toggle, enter to confirm)",
        [(t, t == "claude") for t, s in _TOOLS.items() if s["verified"]],
    )
    if not chosen:
        _ui.say("  (none selected; nothing to install)")
        return None
    flags: list[str] = []
    for tool in chosen:
        flags += ["--tool", tool]
    return flags


def _cmd_install(argv: list[str]) -> int:
    # In a terminal with no tool selected, ask rather than silently defaulting
    # to claude.
    selected = any(a in ("--tool", "--all-tools") for a in argv)
    if not selected and "--config" not in argv and sys.stdin.isatty():
        picked = _pick_tools_interactive()
        if picked is None:
            return 0
        argv = picked + list(argv)

    tools, override = _parse_tool_args(argv)
    if tools is None:
        return 2

    den_dir = _find_den_dir(Path.cwd())
    if _seed_imprint(den_dir):
        print(f"seeded {_imprint_path(den_dir)}", file=sys.stderr)

    rc = 0
    for tool in tools:
        spec = _TOOLS[tool]
        handlers = _FORMATS.get(spec.get("format", ""))
        if not spec["verified"] or handlers is None:
            print(
                f"den hook install: '{tool}' is not verified yet; skipping. "
                f"Verified: claude, gemini, copilot, cline.",
                file=sys.stderr,
            )
            rc = 1
            continue
        config = _resolve_config(spec, override)
        handlers[0](tool, spec, config)
        print(f"installed {tool} hooks -> {config}", file=sys.stderr)
    return rc


def _cmd_list(argv: list[str]) -> int:
    tools, override = _parse_tool_args(argv, default_all=True)
    if tools is None:
        return 2
    for tool in tools:
        spec = _TOOLS[tool]
        handlers = _FORMATS.get(spec.get("format", ""))
        if handlers is None:
            continue
        for line in handlers[1](tool, spec, _resolve_config(spec, override)):
            print(line)
    return 0


def _cmd_remove(argv: list[str]) -> int:
    tools, override = _parse_tool_args(argv, default_all=True)
    if tools is None:
        return 2
    for tool in tools:
        spec = _TOOLS[tool]
        handlers = _FORMATS.get(spec.get("format", ""))
        if handlers is None:
            continue
        config = _resolve_config(spec, override)
        handlers[2](tool, spec, config)
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
        "Verified: claude, gemini, cline (per-turn inject); copilot "
        "(session-start inject only). codex is scaffolded (verified=False)."
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
