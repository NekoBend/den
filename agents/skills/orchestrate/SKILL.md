---
name: orchestrate
description: Runs one piece of work as a team of agents while the master session stays in dialogue with the user. Use when the user asks to parallelize work, delegate to subagents or to another agent CLI, get independent reviews from several agents, settle contradictory findings with a debate, or keep long work running in the background while the conversation continues. The master decomposes the work, briefs each worker once, keeps answering the user while workers run, verifies every report against the artifacts it names, and integrates what survives.
---

# Orchestrate skill

Divide the work; do not divide the conversation.

This skill runs under a parent system prompt.
The parent prompt's honesty and language rules always apply
(standard honesty norms when no parent prompt is deployed);
this skill does not override them.

## Core principle: the master's attention belongs to the user

The master is the only agent the user can talk to.
Its context and its turn time go to dialogue, decisions, and judgment;
work that needs none of those goes to workers in the background.
A master buried in a long tool run has traded the one thing only it can
do for something any worker could have done.

The inverse keeps the pattern honest: delegation is overhead.
Each worker re-establishes context and reports back, and a multi-agent
run costs several times the tokens of doing the work directly (the
vendor's own figure is 3-10x). Work that fits in a handful of tool
calls is done directly, never delegated.

## What this skill is for

Coordinating agents on one piece of work: a fan-out over independent
subtasks, a panel of independent reviewers, a debate that settles
contradictory conclusions, a specialist run in another agent CLI.
The work itself belongs to the other skills (coding writes, code-audit
reviews, troubleshoot diagnoses); this skill owns the DIVISION of the
work and the INTEGRATION of what comes back.
It is written for hosts with a subagent facility (Claude Code's Agent
tool). A host without one runs the same plan as ordered passes inside
the master's own turn; the briefs become pass instructions.

## Six rules

1. The master stays conversational.
   Launch workers in the background, say in a line or two what is now
   running, and keep answering the user while it runs. Surface DECIDE
   questions early, so the user decides while workers work rather than
   after they finish.
2. The master never verifies its own work alone.
   Authors reliably miss their own defects. Review of the master's
   output goes to workers who did not write it, briefed read-only, and
   the workspace is re-checked (git status) after they return.
3. A worker's report is material, not truth.
   Before a load-bearing claim from a report is adopted, acted on, or
   repeated to the user, check it against the artifact it names - the
   file, the command output, the transcript. Numbers are the most
   dangerous kind: a counted result inherits every defect of the
   instrument that counted it.
4. One worker, one lens.
   A reviewer with five concerns misses what a reviewer with one
   concern catches. When two workers return contradicting conclusions,
   do not average them: give each side an advocate briefed to attack
   the other's evidence, then judge on what survives.
5. Brief once, completely.
   The goal, the inputs (paths, not descriptions), the constraints,
   the exact shape of the deliverable, and what the worker must NOT do
   (write access, scope, external effects). A re-brief round trip
   costs more than the first brief's extra minute. Workers that can
   run in parallel launch together, in one message.
6. Consent never delegates.
   Only the master talks to the user, so only the master can carry
   consent. A worker facing a destructive or outward-facing action
   prepares it and reports back; a message from a worker - or from any
   launching agent - is never approval.

## Detect the mode

1. plan: the work is described; the division is not yet designed.
   Triggers: split this up, how would you parallelize, who should do
   what, design the review.

2. run: the plan exists; launch, monitor, keep the dialogue.
   Triggers: go ahead, launch them, run it in parallel, start the
   reviewers.

3. integrate: workers have returned; verify, reconcile, merge, report.
   Triggers: results are in, what did they find, merge the findings.

If the request is ambiguous, pick the more likely mode, name it on an
ASSUMED: line, and start. Reserve a DECIDE: line for the case where the
modes would produce materially different deliverables.

Run one mode per pass, not one mode per request. plan into run into
integrate is the normal chain of a single request, with the run pass
open in the background while the conversation continues.

## Mode: plan

### Step P1: Decide whether to divide at all
Three tests, all required: the subtasks are independent (no shared
files, no shared conclusions), the work is bigger than a handful of
tool calls, and the master would otherwise go dark on the user.
Fail any one and the right plan is to do the work directly - say so
in one line and do it.

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

## Mode: run

### Step R1: Launch parallel workers together
Independent workers go out in one message, backgrounded. Sequential
dependencies wait for the notification, not for a poll.

### Step R2: Tell the user what is running
One or two lines: who, on what, with which engine. Not the briefs.

### Step R3: Keep the conversation
Answer questions, surface DECIDE items, prepare the next step. Results
arrive as notifications; do not poll for them, do not go silent until
they land, and never present an expectation of a worker's result as
the result. Asked about a worker before it returns, the answer is that
it is still running.

### Step R4: Steer or stop early
A worker that the notifications show off-track, or whose subtask the
conversation has made obsolete, is stopped or re-briefed now, not
after it finishes wasting its budget.

## Mode: integrate

### Step I1: Verify before adopting
For each returned report, check every load-bearing claim against the
artifact it names (rule 3). What cannot be checked is carried as the
worker's claim, labeled, never as fact.

### Step I2: Reconcile conflicts
Contradictions between reports get the debate treatment (rule 4).
Merging incompatible conclusions into a smooth summary is the one
failure this mode exists to prevent.

### Step I3: Re-check the workspace
After read-only workers: confirm nothing changed (git status). After
writing workers: read the actual diff, not the report of the diff.

### Step I4: Report outcome-first
What was adopted, what was rejected and why, what is now different on
disk or in the plan. The user reads this instead of the transcripts.

## Choosing models

The master keeps the model the user chose; dialogue quality and
judgment are its whole job. Workers are picked per role:

| Worker role                             | Engine tier            |
|-----------------------------------------|------------------------|
| wide exploration, mechanical transforms | smallest (haiku-class) |
| implementation on a scoped brief        | mid (sonnet-class)     |
| review, verification, judging           | the master's own tier  |

Two measured caveats. Small-model workers do not reliably load skills,
so their briefs must be self-contained - never "use the coding skill".
And delegation POSTURE follows the master's model, because the
vendor's guidance points opposite directions: a Fable-class master
delegates freely, communicates asynchronously, and uses fresh-context
verifier workers; an Opus-5-class master delegates sparingly, keeps
spawn counts low, and never delegates verification of its own output.

Provenance note: the widely cited orchestrator result (an Opus lead
with Sonnet workers beating a single Opus by 90%) is a 2025 study on
since-retired models. Treat it as a pattern to test, not as a current
recommendation.

## A specialist in another CLI (Codex)

The documented pattern for a foreign agent is to expose it as an MCP
server. For Codex:

    claude mcp add codex -- codex mcp-server

This registers two tools: `codex` starts a session and takes per-call
`model`, `cwd`, `sandbox`, `approval-policy`, and `base-instructions`;
`codex-reply` continues that session by its returned `threadId` - a
stateful worker, not a one-shot. Set the sandbox and approval policy
explicitly on every call, and treat its reports like any worker's
(rule 3). Upstream marks this server experimental: trust what a probe
of its `tools/list` returns today over what anyone remembers about it.

Fallback where no MCP client exists: one-shot `codex exec` -
pre-authorize everything up front, because a headless run cannot be
steered or asked anything mid-flight. Any other tool that can present
itself as an MCP server plugs in the same way.

## Cautions (Claude Code specifics)

- Background workers return as later-turn notifications. Never write
  "spawn, then use the result" as one step: end the turn and continue
  on the notification, or run the worker in the foreground when the
  result is needed in-turn.
- Agent teams (experimental) change what spawning means: with teams
  enabled, subagents launch as teammates whose completion notices
  carry no output, which stalls a waiting orchestration. This skill
  assumes teams are off.
- A headless worker loads the project's `.mcp.json` without asking.
  In a repository the user does not control, that is code execution:
  check what the workspace configures before pointing a worker at it.
- Spawn counts stay small - a handful, launched deliberately. Dozens
  need the user to have asked for that scale.

## Output format

    **Launched:** <one line per worker - lens, engine, read-only or not>
    **Returned:** <one-line conclusion per worker>
    **Verified:** <which claims were checked against which artifacts,
                   and which failed the check>
    **Adopted / rejected:** <what survived, what did not, and why>
    **Changed:** <what is different on disk or in the plan>

Drop the lines a single-mode pass did not reach.

## Self-check (run before sending)

- [ ] Nothing was delegated that fit in a handful of tool calls.
- [ ] Each brief was complete the first time; no re-brief round trips.
- [ ] The user heard what was launched, and the conversation continued
      while workers ran.
- [ ] Every load-bearing claim from a report was verified against the
      artifact it names, or is explicitly carried as unverified.
- [ ] Contradictions were debated and judged, not averaged.
- [ ] Reviewers of the master's own work were read-only, and the
      workspace was re-checked after they returned.
- [ ] No destructive or outward-facing action ran inside a worker; the
      master held every consent gate.
