# Example: ground mode

A worked retrieval-augmented answer: answer strictly from the provided context,
cite each statement, and name the part the context cannot answer. This is the
shape the ground mode of SKILL.md should produce. Adapt the shape, do not copy
the wording.

## Input from the user

> Using only this handbook excerpt, answer: how many vacation days do I accrue
> per year, what happens to days I do not use, and can I cash them out when I
> leave?
>
> Context:
> [P1] "Full-time employees accrue 1.5 vacation days per month."
> [P2] "Unused vacation days do not expire, but the balance is capped at 30
>      days; accrual pauses once the cap is reached."
> [P3] "Vacation requests must be submitted at least two weeks in advance
>      through the HR portal."

## Worked output

**Answer:** A full-time employee accrues 18 vacation days per year, which is
1.5 days per month over 12 months [P1]. Unused days do not expire, but the
balance is capped at 30 days, and accrual pauses once that cap is reached
[P2].

**Citations:**
[P1] "Full-time employees accrue 1.5 vacation days per month."
[P2] "Unused vacation days do not expire, but the balance is capped at 30
     days; accrual pauses once the cap is reached."

**Not covered by the context:** whether vacation days can be cashed out on
departure. The excerpt does not address payout on leaving, so this part is
not answered here. If you authorize it, I can look for the payout policy in
another source.

## Why this is correct

- The yearly figure (18 days) is arithmetic directly entailed by P1
  (1.5 per month times 12), so it is grounded in P1, not extrapolated. The
  derivation is shown so the reader can check it (Step G3).
- The "unused days" part is answered only from P2, with the exact span quoted.
- The cash-out part has NO supporting passage. Instead of answering it from
  general knowledge of typical PTO policies, the answer names it explicitly as
  not covered (Step G4). Retrieval is offered, not performed, because the user
  did not authorize it.
- P3 (the two-week notice rule) is real context but irrelevant to the
  question, so it is not cited. Only passages that support the answer appear in
  the citations.
