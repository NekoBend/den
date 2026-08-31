# Example: summarize mode

A worked summary showing must-survive extraction and a faithful, neutral
condensation at a stated target. This is the shape the summarize mode of
SKILL.md should produce. Adapt the shape, do not copy the wording.

## Input from the user

> Summarize this for an exec audience, 3 bullets:
>
> "On May 3, the checkout service had a 47-minute outage starting at 14:12 UTC,
> caused by a database connection pool that was exhausted after a deploy raised
> the maximum number of in-flight requests. About 8,000 orders failed and were
> not retried. The team decided to roll back the deploy and cap in-flight
> requests at 200. Action item: add a connection-pool saturation alert by
> May 17, owned by Priya."

## Worked output

- A deploy exhausted the checkout database connection pool, causing a 47-minute
  outage on May 3 (from 14:12 UTC); about 8,000 orders failed and were not
  retried.
- Resolution: the team rolled back the deploy and capped in-flight requests
  at 200.
- Action: Priya to add a connection-pool saturation alert by May 17.

**Dropped:** the precise mechanism (the deploy raised the max in-flight
requests, which then exhausted the pool) is condensed into "a deploy exhausted
the pool"; the exec summary keeps the cause at one level of detail.

## Why this is correct

- The target was honored: exactly 3 bullets for an exec reader (Step S1).
- Every must-survive item is present: the date, the 47-minute duration, the
  ~8,000 failed orders, the decision (roll back, cap at 200), and the action
  item with its owner and deadline (Step S2). None of these were dropped to
  hit the length.
- Nothing was added. The summary does not speculate about blame, impact in
  dollars, or whether the alert will prevent recurrence; none of that is in the
  source (Faithfulness rule).
- The Dropped note tells the reader exactly what level of detail was traded
  away, so they can ask for the full mechanism if they need it.
