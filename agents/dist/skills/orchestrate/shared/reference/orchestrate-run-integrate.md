# orchestrate: run and integrate modes

Steps R1 to R4 of orchestrate's run mode
and Steps I1 to I4 of its integrate mode,
then the Codex setup, the Claude Code cautions, and the output format.
orchestrate's SKILL.md sends you here when the mode is run or integrate.

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
A worker whose subtask the conversation has made obsolete is stopped
or re-briefed now, not after it finishes wasting its budget.
Off-track detection needs an interim signal; a background worker's
only notification is its completion, so where the host provides
nothing in between, the lever is what the conversation learns, not
worker telemetry.

## Mode: integrate

### Step I1: Verify before adopting
For each returned report, check every claim the result rests on against
the artifact it names (rule 3). What cannot be checked is carried as the
worker's claim, marked as not verified, never as fact.

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

## A specialist in another CLI (Codex)

The documented pattern for a foreign agent is to expose it as an MCP
server. For Codex:

    claude mcp add codex -- codex mcp-server

This registers two tools: `codex` starts a session, `codex-reply`
continues it by its returned `threadId` - a stateful worker, not a
one-shot. Sandbox, approval policy, and model are per-call parameters:
set the first two explicitly on every call, and treat its reports like
any worker's (rule 3). Upstream marks this server experimental: trust what a probe
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
- Agent teams (experimental, as of writing) change what spawning
  means: with teams
  enabled, subagents launch as teammates whose completion notices
  carry no output, which stalls a waiting orchestration. This skill
  assumes teams are off.
- Skill names are not agent types. Spawn workers as general agents
  and let each load the skill its brief calls for; asking the host for
  an agent TYPE named after a skill fails (measured: three spawn
  attempts of type "code-audit" all errored before the master
  corrected course).

## Output format

    **Launched:** <who, on what, engine, read-only or not - one or
                   two lines total>
    **Returned:** <one-line conclusion per worker>
    **Verified:** <which claims were checked against which artifacts,
                   and which failed the check>
    **Adopted / rejected:** <what survived, what did not, and why>
    **Changed:** <what is different on disk or in the plan>

Drop the lines a single-mode pass did not reach.
