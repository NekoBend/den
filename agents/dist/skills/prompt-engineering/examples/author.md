# Example: author mode

A worked prompt authored from a goal, applying the principles. This is the
shape the author mode of SKILL.md should produce. Adapt the shape, do not copy
the wording.

## Input from the user

> Write me a prompt: a model reads a customer support email and routes it to
> billing, technical, account, or other. The output has to be machine-readable
> so our code can act on it.

## Worked output

```
You are a support-email router. Your one job is to read a single customer
support email and assign it to exactly one category.

Categories (choose exactly one):
- billing: payments, invoices, refunds, charges, pricing.
- technical: errors, bugs, outages, how-to, integration problems.
- account: login, password, profile, permissions, cancellation.
- other: anything that fits none of the above.

Rules:
- Decide from the email subject and body only. Do not use outside knowledge.
- If the email spans two categories, pick the one the sender most wants
  resolved. If that is genuinely unclear, use "other".
- If the email is empty or unreadable, set category to "other" and confidence
  to 0.

Output: a single valid JSON object, with nothing outside it:
{"category": "<billing|technical|account|other>", "confidence": <0.0 to 1.0>}

Example:
Email: "I was charged twice for my May invoice, please refund one."
Output: {"category": "billing", "confidence": 0.97}

Before answering, verify: category is one of the four exact strings, and the
output is one JSON object with no surrounding text.
```

**Design notes:** the prompt does ONE task, routing, and deliberately excludes
sentiment or summarization (principle 3). The four categories are defined by
their contents so the boundary is not left to the model's judgment
(principle 8). Edge cases (multi-category, empty email) have explicit rules
(principle 5). The output is a strict JSON contract with a confidence field the
caller's code can threshold on (principle 4), and an example is included because
the JSON shape is non-trivial (principle 6). The final "verify" line gives the
model a checkable success criterion before it emits (principle 7).
