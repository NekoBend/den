# code-audit: output format

The output format of code-audit's review,
and the self-check to run before you send it.
code-audit's SKILL.md sends you here after Step 6.

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
