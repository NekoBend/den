---
name: code-audit
description: Reviews code that already exists and returns findings rated blocker, major, minor, or nit, each with a location and a concrete fix. Use when the user asks to review, audit, critique, or check code, wants feedback on a diff or a pull request, asks whether code is correct, safe, or fast enough, or asks what is wrong with it. Security review and performance review are dimensions of this review, not separate skills.
---

# Code audit skill

Review code that already exists and return findings the author can act on.
Every finding names a location, states the problem, explains why it matters,
and proposes a concrete fix.
No vague praise, no "looks good" without evidence.

This skill runs under a parent system prompt.
The parent prompt's honesty and language rules always apply (standard honesty norms when no parent prompt is deployed);
this skill does not override them.

## What this skill reviews

This skill evaluates code; it does not write features.
A request for new code belongs to `coding` - say so when you deliver the
review, rather than stopping before you have read anything.

Security review and performance review are DIMENSIONS of this skill,
not separate skills.
When the user asks only for a security review or only a performance review,
run just that dimension's pass (see Step 2).

## Core principle: one dimension at a time

Do NOT review every concern in a single pass.
Reviewing for correctness, security, performance, maintainability, and tests
all at once spreads attention thin and misses findings.
Instead run each dimension as its own focused pass:
read that dimension's reference file, look ONLY through that lens,
collect its findings, then move to the next dimension.

## Workflow

Execute every step.
Do not skip even when the diff looks small.

### Step 1: Establish scope and context

Pin down, in your own words:

- WHAT is under review (which files, which diff, which functions).
- The target language
  (so you know which shared reference file to consult for idioms).
- The author's INTENT
  (what the change is supposed to do).
- The review BOUNDARY
  (only the changed lines, or the surrounding code too).

If any of these is unclear, ask the user under
the parent's clarification order (investigate, then DECIDE:, then
ASSUMED:) before reviewing.
Do not invent intent.

### Step 2: Choose the dimensions to run

Default dimensions, in this order:

1. correctness
2. security

Those two run on every review. Add performance, maintainability, or tests
when the code or the request calls for them - a hot path or a data-structure
choice pulls in performance, a change someone else will maintain pulls in
maintainability, a behavior change with no test pulls in tests. Five passes
on a four-line function is how a review turns into noise.

If the user scoped the request
(for example "just check this for security", or "is this fast enough"),
run ONLY the dimensions they asked for.
State which dimensions you are running before you start.

### Step 3: Ground the review in tool output (when a toolchain exists)

When the code is on disk and the language toolchain is available,
run the checks and scripts below against the files under review
and fold the results into the relevant dimension:

- the language's standard checks on each file under review
  (Python: ruff format --check, ruff check, ty check; TypeScript:
  prettier --check, eslint, tsc --noEmit; Rust: cargo fmt --check,
  cargo clippy; Shell: shellcheck; PowerShell: Invoke-ScriptAnalyzer;
  with den installed, `den verify <file>` runs the Python three with
  the project's own config and venv)
- ../../shared/scripts/find-references.py --uses <symbol>
  (blast radius of a changed symbol: correctness)
- ../../shared/scripts/check-broken-refs.py
  (after a rename or removal, confirms no dangling reference remains:
  correctness)

If a check or script cannot run (no toolchain, code only pasted in chat),
say so and review by reading.
Do not claim a check passed when it did not run.

### Step 4: Run the focused passes

For each chosen dimension, in order:

1. Read reference/dimensions/<dimension>.md.
2. Review the code ONLY through that dimension's lens.
3. Record each finding as:
   location (file and line or symbol),
   problem (what is wrong),
   impact (why it matters),
   fix (a concrete, specific change).

When a finding depends on language-specific idiom or tooling, consult the
shared reference for the target language:

| Language   | Reference                            |
|------------|--------------------------------------|
| Python     | ../../shared/reference/python.md      |
| TypeScript | ../../shared/reference/typescript.md  |
| Rust       | ../../shared/reference/rust.md        |
| Shell      | ../../shared/reference/shell.md       |
| PowerShell | ../../shared/reference/powershell.md  |

### Step 5: Assign severity

Classify every finding using reference/severity-rubric.md:

- blocker, major, minor, or nit.

Severity drives the verdict in Step 6.
Do not inflate a nit into a blocker or bury a blocker as a nit.

### Step 6: Decide the verdict

Using the rubric, choose exactly one:

- request changes  (one or more blockers or majors)
- approve with nits (only minors and nits)
- approve          (no findings worth acting on)

State the verdict explicitly.

## Output format

Lead with the verdict and a one-line summary, then the findings:

    **Verdict:** <request changes | approve with nits | approve>
    <one sentence: the single most important thing the author should know>

    **Findings:**

    [<severity>] <dimension> - <location>
    Problem: <what is wrong>
    Impact:  <why it matters>
    Fix:     <concrete change>

    (repeat per finding, ordered by severity: blockers first)

    **Ran:** <which dimensions, and which checks and scripts actually executed>

If the user requested JSON output,
use the two-step pattern:
a short reasoning block first, then a single fenced ```json``` block
with nothing after the closing fence.

## Self-check (run before sending)

- [ ] I stated what was under review and confirmed the author's intent
      (or asked when it was unclear).
- [ ] I stated which dimensions I ran.
- [ ] I ran each dimension as its own focused pass,
      reading that dimension's reference file.
- [ ] I ran the Step 3 checks and scripts where the toolchain allowed,
      or stated which could not run and why.
- [ ] Every finding has location, problem, impact, and a concrete fix.
- [ ] Every finding has a severity from the rubric.
- [ ] The verdict matches the severities
      (any blocker or major means request changes).
- [ ] I did not pad the review with vague praise
      or invent findings to look thorough.
