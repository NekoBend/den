# agents

A prompt system for **weak open-source LLMs** (Llama 7-13B, Qwen 7B, Mistral
class, small hosted models). Everything here is written to be maximally
explicit: state the role, the steps, the output format, and a self-check, so a
model that follows instructions literally still does the right thing.

It ships eight skills in the Anthropic SKILL.md format, a set of parent
invariants (identity, moves, language, work discipline; plus contrastive
examples, output modes, and a final gate in the standalone shape), a build
system that assembles those from sources, and installers that deploy the
skills into the directories coding agents read.

This is the `agents/` subsystem of the `den` repo: a self-contained unit
(sources, build, install, tests) that could be used or extracted on its own.
All commands below are run from this `agents/` directory.

## Three deployment shapes

Pick the one that matches how your tool loads instructions.

| Shape | File(s) | Use when |
|-------|---------|----------|
| Standalone prompt | `dist/ASSISTANT.md` | You want a single self-contained system prompt, no skills, one worker. The model answers directly. |
| Router + skills | `dist/SKILL_ROUTER.md` + `skills/` | Your environment has no native skill loader. You supply the router as the system prompt; it routes each request to exactly one skill and the model reads that `skills/<name>/SKILL.md` on demand. |
| Parent invariants + native skills | `dist/AGENTS.md` / `dist/CLAUDE.md` + installed `skills/` | Your tool auto-discovers skills from its skill directories (GitHub Copilot, opencode, Claude Code, OpenAI Codex) and reads `AGENTS.md` (or `CLAUDE.md`) as global instructions. The tool does the routing; these files supply the invariants the skills depend on. |

`AGENTS.md` and `CLAUDE.md` have identical content; `AGENTS.md` is the
cross-tool standard, `CLAUDE.md` is the Claude Code name.

## Layout

```
agents/
  skills/<name>/            # the 8 skills
    SKILL.md                # name + description frontmatter + body
    examples/               # worked examples (one shape per file)
    reference/              # only code-review (dimension + rubric files)
  shared/
    reference/*.md          # per-language + architecture / testing / schema-design
    scripts/                # verification scripts (used by coding, code-review)
      *.py, run-checks.sh
      tests/                # pytest + bats
  .private/                 # LOCAL ONLY - self-gitignored, never committed
    parts/<ARTIFACT>/       # build sources: ASSISTANT/  SKILL_ROUTER/
    build.py                # builds dist/ from .private/parts/
  dist/                     # generated parent prompts (committed; do not hand-edit)
    ASSISTANT.md  SKILL_ROUTER.md  AGENTS.md  CLAUDE.md
  README.md
```

The build sources and builder live in `.private/`, which manages its own
exclusions via `.private/.gitignore` (`**`). Only the generated `dist/*.md`
is committed. The rest of `agents/` (skills, shared) is committed.

This content is deployed by the `den` CLI (`den install skills`); `agents/` is
the content, `den install` is how it gets deployed. The content ships bundled
inside the den wheel, so it installs with no source checkout on disk.

## The eight skills

Each skill detects a mode first, then runs ONE mode per request (weak models
lose adherence when many instructions fire at once). All skills assume the
parent invariants (`<identity>`, `<moves>`, `<language_policy>`,
`<work_discipline>`) are present.

| Skill | Modes | What it does |
|-------|-------|--------------|
| coding | implement / test / schema | Produce new code, tests, or schemas in Python, TypeScript, Go, Rust, Java, C#, or Shell. Uses `shared/` references and verification scripts. |
| code-review | correctness / security / performance / maintainability / tests | Review existing code one focused dimension at a time; severity-rated findings. |
| grounding | verify / ground | Fact-check claims against sources, or answer strictly from provided context, with per-claim citations. |
| compressor | summarize / compress | Summarize text, or compress a prompt/context to fewer tokens while preserving every directive. |
| prompt-engineering | author / improve | Write a new prompt from a goal, or diagnose and rewrite an existing one. |
| documenter | reference / guide | API reference from code, or a human guide (README/how-to/tutorial). |
| git-manager | commit / pr / history | Run git safely (commits, PRs, history ops), inspect-first and confirm before anything destructive; GitHub Flow by default. |
| translate | translate / review | Translate text into another language, or QA an existing translation. |

`coding` and `code-review` are the heavy skills (they use `shared/reference/`
and `shared/scripts/`). The other six are light: `SKILL.md` plus two examples,
no shared dependencies.

## Build (maintainers, local only)

The `dist/*.md` parent prompts are generated; edit the sources under
`.private/parts/`, never the generated files. Both live in `.private/` and are
not committed. After editing, rebuild and commit the regenerated `dist/`:

```
python3 .private/build.py            # rebuild dist/{ASSISTANT,SKILL_ROUTER,AGENTS,CLAUDE}.md
python3 .private/build.py --check    # verify dist/ is in sync with .private/parts/
```

The build concatenates each `.private/parts/<ARTIFACT>/` section in sorted order,
strips HTML comments (maintainer notes stay in source, never reach the model),
normalizes em / en / minus dashes to ASCII, and collapses blank runs.
`AGENTS.md` and `CLAUDE.md` are composites of the shared `ASSISTANT`
sections: identity, moves, language, and work discipline (the host tool owns
the conversation shape, so modes/examples/gate stay standalone-only).

## Install

`den install skills` deploys the skills (one cross-platform implementation).
Each skill installs as a SELF-CONTAINED unit: it copies a skill, then copies
only the `shared/` resources that skill references into the skill's own
`shared/`, and rewrites every `shared/...` reference to an ABSOLUTE path under
that skill (weak models resolve absolute paths reliably; relative ones are
ambiguous). No top-level `shared/` tree is created in the target.

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
source tree.

## Conventions

- No em-dash, en-dash, or Unicode minus in any model-facing file; the build
  normalizes them to ASCII. Math symbols are kept.
- Semantic line breaks in the sources (break at clause boundaries).
- One mode per request; detect the mode, then branch.
- Skills depend on the parent invariants. Deploy with `--with-parent` (or
  ensure `AGENTS.md` / `CLAUDE.md` is present) so `<language_policy>`,
  `<work_discipline>`, and the other tags the skills reference are actually
  defined.

## Tests

The verification scripts under `shared/scripts/` have a test suite:

```
python3 -m pytest shared/scripts/tests     # 25 tests
bats shared/scripts/tests/run-checks.bats  # 8 tests
```

Tooling expected on PATH for the full coding/code-review experience: `ruff`,
`ty`, `shellcheck`, `shfmt`, `prettier`, `eslint`, `gofmt`, plus the language
toolchains. Scripts skip gracefully when a tool is absent rather than failing.
