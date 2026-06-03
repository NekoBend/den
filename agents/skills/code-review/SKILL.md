---
name: code-review
description: Review existing code (a diff, a file, a set of files, or a pull request) and return severity-rated, actionable findings. Use this skill when the user asks to review, audit, critique, check, or give feedback on code they already have, including security review and performance review (both are dimensions of this skill, not separate skills). Runs one focused dimension at a time (correctness, security, performance, maintainability, tests) so each pass stays narrow. Reuses the shared verification scripts to ground findings in tool output.
---

# Code review skill

Review code that already exists and return findings the author can act on.
Every finding names a location, states the problem, explains why it matters,
and proposes a concrete fix.
No vague praise, no "looks good" without evidence.

This skill runs under a parent system prompt.
<honesty_contract> and <language_policy> from the parent always apply;
this skill does not override them.

## What this skill reviews

This skill evaluates code; it does not write features.
If the user wants new code written, that is the `coding` skill, not this one.

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
<work_discipline> Clarification discipline before reviewing.
Do not invent intent.

### Step 2: Choose the dimensions to run

Default dimensions, in this order:

1. correctness
2. security
3. performance
4. maintainability
5. tests

If the user scoped the request
(for example "just check this for security", or "is this fast enough"),
run ONLY the dimensions they asked for.
State which dimensions you are running before you start.

### Step 3: Ground the review in tool output (when a toolchain exists)

When the code is on disk and the language toolchain is available,
run the shared scripts against the files under review
and fold the results into the relevant dimension:

- ../../shared/scripts/run-checks.sh <file>      format / lint / typecheck (correctness, maintainability)
- ../../shared/scripts/verify-imports.py <file>  imported APIs exist (correctness)
- ../../shared/scripts/doc-coverage.py <file>    public API documentation (maintainability)
- ../../shared/scripts/find-references.py --uses <symbol>
                                                 blast radius of a changed symbol (correctness)

If a script cannot run (no toolchain, code only pasted in chat),
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
| Go         | ../../shared/reference/go.md          |
| Rust       | ../../shared/reference/rust.md        |
| Java       | ../../shared/reference/java.md        |
| C#         | ../../shared/reference/csharp.md      |
| Shell      | ../../shared/reference/shell.md       |

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

    **Ran:** <which dimensions, and which scripts actually executed>

If the user requested JSON output,
follow the parent <output_format> two-step pattern
(reasoning block first, then a single fenced ```json``` block).

## Self-check (run before sending)

- [ ] I stated what was under review and confirmed the author's intent
      (or asked when it was unclear).
- [ ] I stated which dimensions I ran.
- [ ] I ran each dimension as its own focused pass,
      reading that dimension's reference file.
- [ ] I ran the shared scripts where the toolchain allowed,
      or stated which could not run and why.
- [ ] Every finding has location, problem, impact, and a concrete fix.
- [ ] Every finding has a severity from the rubric.
- [ ] The verdict matches the severities
      (any blocker or major means request changes).
- [ ] I did not pad the review with vague praise
      or invent findings to look thorough.
