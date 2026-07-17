# Worked review example

A sample of the output this skill produces.
The code under review is shown first,
then the review the skill should return.
The code is an object of review, NOT a pattern to copy:
each defect in it is flagged and corrected by the review.

## Code under review

The author submitted this Python function (file `pricing.py`)
and asked for a general review.

```python
def proc(items, rates=[]):
    total = 0
    for it in items:
        if it["rate"] == None:
            r = rates[0]
        else:
            r = it["rate"]
        total = total + it["qty"] * r
    return total / len(items)
```

## The review this skill should produce

**Verdict:** request changes
The function crashes on empty input and does not handle a missing rate.

**Findings:**

[blocker] correctness - pricing.py, final return
Problem: `total / len(items)` divides by zero when `items` is empty.
Impact: every call with an empty list raises ZeroDivisionError.
Fix: handle the empty case explicitly before dividing
(return 0, or raise a documented error).

[major] correctness - pricing.py, `rates` parameter and `rates[0]`
Problem: when an item has no rate the code falls back to `rates[0]`,
which raises IndexError if `rates` is empty,
so the "no rate" case is not actually handled.
The `rates=[]` default is also a latent trap: one list is shared across calls.
Impact: a missing rate crashes instead of being handled.
Fix: default `rates` to None, build a fresh list inside,
and handle the no-rate case explicitly (skip, error, or a documented default).

[minor] correctness - pricing.py, `it["rate"] == None`
Problem: a None check should use `is`, not `==`.
Impact: `== None` calls `__eq__` and can behave unexpectedly on custom types.
Fix: write `if it["rate"] is None`.

[minor] maintainability - pricing.py, `def proc`
Problem: the names `proc` and `it` do not reveal intent,
and the function has no docstring.
Impact: a reader cannot tell what the function computes without tracing it.
Fix: rename to something like `average_order_total`, use `item`,
and add a one-line docstring.

[minor] tests - pricing.py
Problem: no test covers the empty-input or missing-rate paths.
Impact: the two correctness defects above would ship uncaught.
Fix: add tests for an empty list and for an item whose rate is missing.

**Ran:** correctness, security, performance, maintainability, tests,
all by reading (the code was pasted in chat,
so run-checks.sh could not run).
Security and performance found nothing material at the expected scale.
