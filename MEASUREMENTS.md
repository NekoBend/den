# Measurements

What has actually been measured about these prompts and skills, how, and
what was decided from it. Everything below is a summary of a private
evaluation harness (`workitems/llm-test`, not in this repository); the
numbers are copied from its results file, and the design is described in
enough detail to be reproduced.

## 1. Does the `## Self-check` block earn its lines?

Every skill ends with a self-check list. The question was whether that
block changes behavior at all, and in which direction, per model tier.

**Design.** A/B, one variable: the code-audit skill with its
`## Self-check (run before sending)` section present (`check`) versus
stripped (`nocheck`). Six review scenarios (prompt injection in a
comment, feedback on the user's own code, a clean file, a real bug, a
secrets leak, a pride trap), each with regex assertions in the
anthropics/skills eval schema, two to three repetitions per cell. The
skill is in context deterministically, so the measurement is about the
block, not about whether the skill fired.

Delivery differed by harness, which matters for reading the table:

| harness | delivery | models |
|---|---|---|
| Claude Code `claude -p` | deployed skill, explicit invocation | haiku-4-5, sonnet-5, opus-4-6, opus-5 |
| Codex `codex exec` | deployed skill, named in the prompt, load verified per cell | gpt-5.4-mini, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna |
| OpenCode `opencode run` | skill text inlined in the prompt (weak models do not reliably fire skill tools) | 8 open-weight models on the Go plan, 3 free-tier models |

Within one row the two arms are paired (same delivery, same scenarios),
so the delta is valid. Absolute rates across harnesses are reference
only.

**Results.** Pass rate over all assertions, `check` minus `nocheck` in
percentage points.

Claude and GPT (252 cells, 2026-08-20):

| model | check | nocheck | delta |
|---|---|---|---|
| haiku-4-5 | 0.73 | 0.83 | -10 |
| sonnet-5 | 0.93 | 0.87 | +6 |
| opus-4-6 | 0.89 | 0.81 | +8 |
| opus-5 | 0.97 | 0.97 | 0 |
| gpt-5.4-mini | 0.88 | 0.91 | -3 |
| gpt-5.6-sol | 0.87 | 0.89 | -2 |
| gpt-5.6-terra | 0.87 | 0.83 | +4 |
| gpt-5.6-luna | 0.91 | 0.93 | -2 |

Open-weight models via OpenCode Go (192 cells, 2026-08-21):

| model | check | nocheck | delta |
|---|---|---|---|
| deepseek-v4-flash | 0.97 | 0.94 | +3 |
| glm-5.2 | 0.97 | 0.94 | +3 |
| minimax-m3 | 0.97 | 0.92 | +5 |
| kimi-k3 | 0.94 | 0.92 | +2 |
| qwen3.7-max | 0.94 | 0.94 | 0 |
| qwen3.6-plus | 0.92 | 0.92 | 0 |
| kimi-k2.6 | 0.86 | 0.89 | -3 |
| mimo-v2.5 | 0.83 | 0.97 | -14 |

Free-tier reference (28 of 36 cells graded after instrument exclusions;
arms not fully paired, so read as a sign check only): deepseek-v4-flash
-8, mimo-v2.5 +11, nemotron-3.5-lightning +14.

**Reading.** Across 19 lanes and 17 distinct models, only the Claude
family shows a systematic effect, and it is an inverted U: the block
harms the small tier (haiku loses injection compliance and inflates its
output by about 30 percent), helps the middle (sonnet-5, opus-4-6), and
does nothing at the top (opus-5 verifies without being told). GPT via
codex is flat within noise. The open-weight class is flat too: pooled
delta about -0.5 points; the one outlier (mimo-v2.5 at -14) flips sign
against the same family's free-tier run (+11), and at 12 cells per arm a
single cell moves a rate by about 8 points, so it reads as noise. No
haiku-style harm appeared anywhere outside the Claude family.

**Decision.** Keep the self-check blocks. They pay on the models this
system is deployed to most, cost nothing on opus-5 and GPT, and the one
tier they hurt is not a deployment target of the frontier profile.
Whether the weak profile should strip them is a token-budget question,
not a harm question.

**Limits.** n is small per cell (12 to 36 assertions per arm); the
open-weight lanes used inline delivery rather than deployed skills; the
free-tier subsets are unpaired. Instrument lessons that shaped the
numbers: a first run reported a 0-of-12 fire rate that turned out to be
the harness reading stderr instead of stdout; the OpenCode Go plan
meters usage server-side, so timed-out cells still bill and
client-observed cost sums understate real usage by about 5x.

## 2. Skill trigger rate

Skill descriptions were rewritten as trigger surfaces (the description is
what the host matches against a request) after measuring how rarely
skills fired on production-like phrasing. The trigger evals follow the
anthropics/skills skill-creator format: about 20 queries per skill (half
should fire, half are near misses), three runs each, a 60/40 train/test
split, at most five description iterations. Results per skill live in
the private harness; the repository carries only the descriptions that
came out of it.

## 3. What is not measured

Nothing here measures end-task quality of the produced code or documents,
only compliance with the behaviors the skills specify. The parent prompt
itself has been reviewed (three outside review rounds and a 67-agent
multi-lens audit, all findings verified before action) but not A/B
measured; a length A/B for the weak profile is designed and not yet run.
