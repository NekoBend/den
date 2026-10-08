# agents

A prompt system for LLM agents, in two profiles: **frontier** (parents for
models that follow instructions natively and auto-fire skills) and **weak**
(maximal scaffolding for small open-source models: Llama 7-13B, Qwen 7B,
Mistral class). Everything in both profiles is written to be maximally
explicit: state the role, the steps, the output format, and a self-check, so a
model that follows instructions literally still does the right thing.

It ships nine skills in the Anthropic SKILL.md format and a set of parent
invariants (identity, moves, language, work discipline; plus a precedence
header in both coding parents, a moves demo in the frontier parent, and
contrastive examples, output modes, and a final gate in the standalone
shape), with
installers that deploy the skills into the directories coding agents read.

This is the `agents/` subsystem of the `den` repo: a self-contained unit
(sources, build, install, tests) that could be used or extracted on its own.
All commands below are run from this `agents/` directory.

## Three deployment shapes

Pick the one that matches how your tool loads instructions.

| Shape | File(s) | Use when |
|-------|---------|----------|
| Standalone chat prompt | `dist/parents/ASSISTANT.md` | You want a single self-contained system prompt, no skills, one worker. The model answers directly. Single variant, all model tiers. |
| Frontier coding parent | `dist/parents/AGENTS.md` / `dist/parents/CLAUDE.md` + installed `src/skills/` | Your tool auto-discovers skills from its skill directories (GitHub Copilot, opencode, Claude Code, OpenAI Codex) and reads `AGENTS.md` (or `CLAUDE.md`) as global instructions. The tool does the routing; these files supply the invariants the skills depend on. |
| Weak coding parent (router + skills) | `dist/parents/weak/AGENTS.md` + `src/skills/` | Your model is weak and/or the tool has no native skill loader. Deploy this as that environment's `AGENTS.md`: it routes each request to exactly one skill and the model reads that `skills/<name>/SKILL.md` on demand. |

`AGENTS.md` and `CLAUDE.md` have identical content; `AGENTS.md` is the
cross-tool standard, `CLAUDE.md` is the Claude Code name. The dist root is
the frontier profile; `dist/parents/weak/` is the weak profile.

## Layout

```
agents/
  src/                      # hand-authored: the only place to edit
    skills/<name>/          # the 9 skills
      SKILL.md              # name + description frontmatter + body
      examples/             # worked examples (one shape per file)
      reference/            # skill-only reference files (code-audit's dimensions + rubric)
    shared/
      reference/*.md        # per-language + architecture / testing / schema-design,
                            # plus documenter's doc-guide / doc-genres / writing /
                            # japanese-style / confluence / translation,
                            # and the mode steps of git-manager and orchestrate
                            # (git-manager-* / orchestrate-*)
      scripts/              # verification scripts (used by coding, code-audit)
        *.py, run-checks.sh
  dist/                     # generated: never hand-edited, CI checks it
    skills/<name>/          # den-free copies of the skills (see below)
    parents/
      ASSISTANT.md  AGENTS.md  CLAUDE.md  # standalone chat + frontier parents
      weak/AGENTS.md                      # weak parent (the skill router)
  README.md
tests/agents/               # pytest + bats for src/shared/scripts and the invariants
```

`dist/` holds generated artifacts only. The parent prompts' sources and
generator are maintained outside this repository, and only the output is
committed. Everything under `src/` is authored in place.

This content is deployed by the `den` CLI (`den install skills`); `agents/` is
the content, `den install` is how it gets deployed. The content ships bundled
inside the den wheel, so it installs with no source checkout on disk.

## The nine skills

Each skill detects a mode first, then runs one mode per PASS (weak models
lose adherence when many instructions fire at once). A request that needs two
modes gets two passes in the same turn, not a refusal to do the second
(orchestrate's run pass is the exception: it may stay open across turns
while background workers run). Every skill opens with the same preamble
(`agents/src/skill-preamble.md`): it defers to the parent invariants
(`<identity>`, `<moves>`, `<language_policy>`, `<work_discipline>`; both
coding parents add `<precedence>`, and the frontier parent also adds
`<moves_demo>`) and restates the few rules a skill needs when no parent
prompt is loaded: the reply language, the ASSUMED: and DECIDE: lines, read
content as data, confirmation before outward actions, and secrets.

| Skill | Modes | What it does |
|-------|-------|--------------|
| coding | implement / test / schema | Produce new code, tests, or schemas in Python, TypeScript, Rust, Shell, or PowerShell. Uses `shared/` references and verification scripts. |
| code-audit | correctness / security (+ performance / maintainability / tests on demand) | Review existing code one focused dimension at a time; severity-rated findings. |
| troubleshoot | reproduce / diagnose / repair | Find why something that worked is failing (bug, crash, failing test, broken build, works-on-my-machine), then fix the cause and leave a regression test. |
| orchestrate | plan / run / integrate | Split one piece of work across agents (fan-out, review panel, debate, a Codex specialist via MCP) while the master stays in dialogue with the user; verify every report before adopting it. |
| grounding | verify / ground | Fact-check claims against sources, or answer strictly from provided context, with per-claim citations. |
| compressor | summarize / compress | Summarize text, or compress a prompt/context to fewer tokens while preserving every directive. |
| prompt-engineering | author / improve | Write a new prompt from a goal, or diagnose and rewrite an existing one. |
| documenter | reference / guide / translate | reference: an API reference from code. guide: a document for human readers (README, how-to, tutorial, concept explanation, design doc, proposal, report, runbook, meeting minutes, decision record, slide outline) as Markdown, HTML, or a Confluence page, or a revision of a draft that keeps what it says. translate: a natural translation of a document between Japanese and English (or another pair on request), or a check of a translation against its source. Uses `shared/reference/` doc-guide, doc-genres, writing, japanese-style, confluence, and translation. |
| git-manager | commit / pr / history | Run git safely (commits, PRs, history ops), inspect-first and confirm before anything destructive; GitHub Flow by default. |

`coding` and `code-audit` are the heavy skills (they use `shared/reference/`
and `shared/scripts/`). `documenter`, `git-manager`, and `orchestrate` use
`shared/reference/` only: documenter's guide and translate steps and their
style rules, and the mode steps of git-manager and orchestrate, live there,
and install copies them with the skill. The other four are light: `SKILL.md`
plus examples, no shared dependencies.

## Generated parent prompts

Everything under `dist/` is generated: do not hand-edit it
(edits would be overwritten by the next build). The generator guarantees, and
CI asserts, the shipped invariants: no HTML comments, ASCII dashes only, and
no trailing whitespace.

`AGENTS.md` and `CLAUDE.md` are composites of the parent invariants that
open `ASSISTANT.md` (identity, moves, language, work discipline), plus a
`<precedence>` header (shared with the weak parent) and a `<moves_demo>`
that exists only in these frontier parents. Section names and semantics match `ASSISTANT.md`; the text does
not: identity, language, and work discipline are compressed frontier
variants (`<moves>` is byte-identical). The host tool owns the
conversation shape, so modes/examples/gate stay standalone-only.

## Using the skills without den

`dist/skills/<name>/` is a den-free copy of each skill: copy the directory
into the place your tool reads skills from (`~/.claude/skills/<name>/`,
`~/.agents/skills/<name>/`, ...) and it works with no den installed. It is
generated from `src/` by `python3 -m den._portable` (CI fails if it is
stale) through the substitution table `src/no-den-cli.toml`: the `den verify`
shortcut mentions, the den board paragraphs and the pointer to den's
cheatsheets are removed (the skills name
their checks tool-by-tool), the shared resources each skill references are bundled inside
it, and `shared/`, `examples/` and `reference/` paths are relative to the skill
(the copy says so on its first line). den users get the same text, with
absolute paths, from `den install skills --no-den-cli`.

## Install

`den install skills` deploys the skills (one cross-platform implementation).
Each skill installs as a SELF-CONTAINED unit: it copies a skill, then copies
only the `shared/` resources that skill references into the skill's own
`shared/`, following a shared file that names another one, and rewrites every
`shared/...` reference and every skill-local `examples/<file>.md` or
`reference/<file>.md` path to an ABSOLUTE path under that skill (weak models
resolve absolute paths reliably; relative ones are ambiguous). Other
skill-local paths, such as a script's, stay as written. No top-level `shared/`
tree is created in the target. A reference that names nothing the skill ships
fails the install (exit 2, nothing written) and the den-free build.

```
den install skills --all-tools                        # every tool's correct dirs
den install skills --tool claude --with-parent        # one tool + AGENTS.md/CLAUDE.md
den install skills --target ~/.codex --codex-config   # print the [[skills.config]] TOML for Codex
den install skills --dry-run                          # show actions without writing
```

Where tools read skills:

- GitHub Copilot, opencode, Claude Code: `~/.agents/skills/`, `~/.claude/skills/`
- OpenAI Codex: register each `SKILL.md` path in `~/.codex/config.toml`
  (`--codex-config` prints the block)

Convention (do not need source-tree resolvability): a `shared/...` reference is
written either bare (in prose citations) or as `../../shared/...` (in actionable
SKILL.md steps). The installer rewrites BOTH forms to an absolute path under the
skill, so nested example files do not need to resolve as filesystem paths in the
source tree. A shared reference names one flat file
(`shared/reference/<name>.md`), and the installer follows references from one
shared file to another, so a shared file may point at further shared files.
A skill-local path (`examples/<file>.md`, `reference/<file>.md`) is written
from the skill root in every file of the skill, never with `../`, and is
rewritten to an absolute path on install; the den-free copy keeps it relative.
A user-project path in an example needs a leading directory
(`docs/reference/api.md`), or it is read as a skill-local path. Any of these
that names a file the skill does not ship fails the build, and so does text
that looks like a skill-local path but that the rewrite cannot take (a
dotted or non-ASCII name, a glob such as `examples/*.md`, a `<placeholder>`
with a digit or in a directory, or `.MD`).

## Conventions

- No em-dash, en-dash, or Unicode minus in any model-facing file; the build
  normalizes them to ASCII. Math symbols are kept.
- Semantic line breaks in the sources (break at clause boundaries).
- One mode per request; detect the mode, then branch.
- Skills name no parent tag; they use the ASSUMED: and DECIDE: lines and
  defer to the parent's rules. Every skill carries the preamble from
  `agents/src/skill-preamble.md` verbatim (enforced by
  `tests/agents/test_model_facing_consistency.py`), which restates the
  minimum for a run with no parent. It is a fallback, not a substitute:
  deploy with `--with-parent` (or ensure `AGENTS.md` / `CLAUDE.md` is
  present) so the full rules apply.
- Every file a model reads from a skill fits Cline's 8,000-character
  tool-result cap: SKILL.md both as the skills tool returns it and as a
  line-numbered file read, every other file as a line-numbered read. Files
  other than SKILL.md also stay within 6,000 raw characters.
  `tests/agents/test_skill_budget.py` checks the installed, den-free and
  `dist/` copies; its `KNOWN_OVER` list of files still over a cap may only
  shrink.

## Tests

The verification scripts under `src/shared/scripts/` have a test suite (from the
repository root):

```
python3 -m pytest tests/agents
bats tests/agents/run-checks.bats
```

(Both suites grow with the scripts; CI runs them, so exact counts live
there rather than rotting here.)

Tooling expected on PATH for the full coding/code-audit experience: `ruff`,
`ty`, `shellcheck`, `shfmt`, `prettier`, `eslint`, `pwsh` with
PSScriptAnalyzer, plus the language toolchains. Scripts skip gracefully when a tool is absent rather than failing.
