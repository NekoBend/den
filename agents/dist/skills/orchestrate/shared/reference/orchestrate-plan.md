# orchestrate: plan mode

Steps P1 to P4 of orchestrate's plan mode,
then the model guide that Step P3 uses and the core principle behind Step P1.
orchestrate's SKILL.md sends you here when the mode is plan.

### Step P1: Decide whether to divide at all
Three tests, all required: the subtasks are independent (no shared
files, no shared conclusions), the work is bigger than a handful of
tool calls, and the master would otherwise go dark on the user.
Fail any one and the right plan is to do the work directly - say so
in one line and do it. One standing exception passes P1 without the
size test: rule 2's independent review of a deliverable the master
authored.

### Step P2: Cut along independence
One worker per independent subtask; for review, one worker per lens
(correctness, security, one PR each - never "review everything").
When the outcome matters enough to survive being wrong, add one
adversarial seat briefed to build the strongest honest case AGAINST
the work or against the other workers' expected conclusions.

### Step P3: Choose each worker's engine
See "Choosing models" below. Record the choice per worker; a plan that
says only "spawn three agents" has skipped a decision.

### Step P4: Write the briefs
Rule 5, per worker, including the deliverable's format and the line
"your final message is the report". Reviewers of existing work are
briefed read-only in so many words: no file modification, no state
change, report only.

## Choosing models

The master keeps the model the user chose; dialogue quality and
judgment are its whole job. Workers are picked per role:

| Worker role                             | Engine tier            |
|-----------------------------------------|------------------------|
| wide exploration, mechanical transforms | smallest (haiku-class) |
| implementation on a scoped brief        | mid (sonnet-class)     |
| independent review (rule 2), judging    | the master's own tier  |

Two caveats. Small-model workers do not reliably load skills
(measured: a haiku-class worker fired a skill 0 times in 9 natural
scenarios where a sonnet-class one fired), so their briefs must be
self-contained - never "use the coding skill".
And delegation POSTURE follows the master's model, because the
vendor's guidance points opposite directions: a Fable-class master
delegates freely, communicates asynchronously, and uses fresh-context
verifier workers; an Opus-5-class master delegates sparingly, keeps
spawn counts low, and keeps its own verification in its own loop -
the vendor's words are "do NOT use subagents to verify your own work".
Rule 2 deliberately overrides that on every tier, posture
notwithstanding: a deliverable the
master authored gets independent read-only review before it ships, and
that review is also the one delegation exempt from the
handful-of-tool-calls test.

Provenance note: the widely cited orchestrator result (an Opus lead
with Sonnet workers beating a single Opus by 90%) is a 2025 study on
since-retired models. Treat it as a pattern to test, not as a current
recommendation.

## Core principle: the master's attention belongs to the user

The master is the only agent the user can talk to.
Its context and its turn time go to dialogue, decisions, and judgment;
work that needs none of those goes to workers in the background.
A master buried in a long tool run has traded the one thing only it can
do for something any worker could have done.

The inverse keeps the pattern honest: delegation is overhead.
Each worker re-establishes context and reports back, and a multi-agent
run costs several times the tokens of an equivalent single-agent run
(Anthropic's published figure, 2026: 3-10x over a single agent
for equivalent tasks). Work
that fits in a handful of tool calls is done directly, never
delegated.
