# Migrations: what den leaves behind

`den uninstall` is stateless by design. It re-derives what the CURRENT
version installs and removes only the files that are byte-identical to it,
so your edits survive. The cost of that design: when den stops deploying
something (a retired tool, a renamed skill, a deleted script), the old copy
is no longer anything den knows about, and no den command will ever remove
it.

This file is the list of those leftovers. Nothing here is urgent - the
files are inert, not harmful - except where a note says otherwise. Run the
cleanup once per machine that has been running den for a while.

Check what a machine actually has before deleting:

```sh
ls -d ~/.gemini/skills ~/.cline/skills 2>/dev/null
ls -d ~/.claude/skills/code-review ~/.agents/skills/code-review \
      ~/.copilot/skills/code-review ~/.codex/skills/code-review 2>/dev/null
find ~/.claude/skills ~/.agents/skills ~/.copilot/skills ~/.codex/skills \
     \( -name verify-imports.py -o -name doc-coverage.py \) 2>/dev/null
```

## 1. `code-review` renamed to `code-audit` (2026-08, #57)

The skill was renamed because `code-review` collided with Claude Code's
own `/code-review`, and den's skill won: typing the command loaded den's
five-dimension procedure instead of the built-in multi-agent review.

**This one matters more than the others**: leaving the old directory in
place keeps the collision alive, so the rename buys nothing until it is
removed.

```sh
rm -rf ~/.claude/skills/code-review ~/.agents/skills/code-review \
       ~/.copilot/skills/code-review ~/.codex/skills/code-review
```

```powershell
Remove-Item -Recurse -Force ~/.claude/skills/code-review, `
  ~/.agents/skills/code-review, ~/.copilot/skills/code-review, `
  ~/.codex/skills/code-review -ErrorAction SilentlyContinue
```

Codex additionally registers each skill by PATH, so its `config.toml`
still points at the old file. Re-print the block and replace the
`[[skills.config]]` section in `~/.codex/config.toml`:

```sh
den install skills --target ~/.codex --codex-config
```

## 2. gemini retired (2026-07, #52)

gemini-cli hit upstream end-of-life for individual accounts; its
successor reads the cross-tool `~/.agents/skills` that den already
deploys, so the gemini entry was removed from den entirely.

```sh
rm -rf ~/.gemini/skills          # skills only; GEMINI.md is yours to keep
```

`den uninstall skills` still sweeps this one for now, because the sweep
was added in #52 before the entry was dropped. Do not rely on it after
that sweep is eventually removed.

## 3. cline skills moved to `~/.agents/skills` (2026-06)

den used to deploy cline's skills to `~/.cline/skills` as well. That
double-loaded in the VS Code extension, so deployment moved to
`~/.agents/skills` only. Anything still under `~/.cline/skills` is a
pre-move copy and will be stale.

```sh
rm -rf ~/.cline/skills
```

## 4. The AST verifier scripts (2026-07, #45)

`verify-imports.py` and `doc-coverage.py` were replaced by standard tools
(`ty` resolves imports; ruff's docstring rules cover the doc check) and
deleted from the repository. Every skill deployed before that still
carries them under its own `shared/scripts/`.

```sh
find ~/.claude/skills ~/.agents/skills ~/.copilot/skills ~/.codex/skills \
     \( -name verify-imports.py -o -name doc-coverage.py \) -delete
```

## Why there is no `den prune`

Deliberate: a prune command needs a durable record of everything den has
ever installed, which is the stateful design `den uninstall` was written
to avoid, and it would be maintained for a user base of one. A file that
says what to delete, and when it appeared, costs nothing to keep correct.

When a future change orphans something, add a section here in the same
commit.
