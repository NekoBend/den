# Example: improve mode

A worked diagnosis-and-rewrite of a weak prompt, with each fix tied to a
principle. This is the shape the improve mode of SKILL.md should produce. Adapt
the shape, do not copy the wording.

## Input from the user

> Improve this prompt:
> "You're a helpful assistant for our app. Answer the user's questions,
> summarize how they feel, translate your answer to Spanish if needed, and
> always be friendly and concise."

## Worked output

**Diagnosis:**
- Four unrelated jobs in one prompt: answer, summarize sentiment, conditional
  translation, and tone (principle 3).
- No output format, so a caller cannot separate the answer from the sentiment
  from the translation (principle 4).
- "translate ... if needed" has no defined trigger (principle 5).
- "friendly and concise" are vague qualifiers with no measurable target
  (principle 8).
- No success criteria the model can check before answering (principle 7).

```
You are a support assistant for <app>. For each user message, do exactly these
three steps in order and return them in the structure below.

1. Answer: answer the user's question using only <app>'s documented behavior.
   If you do not know, say so; do not invent.
2. Language: if the user's message is in Spanish, write Answer in Spanish;
   otherwise write Answer in English. The trigger is the user's input language,
   not a guess about preference.
3. Sentiment: label the user's tone as exactly one of: positive, neutral,
   negative.

Keep Answer to at most 4 sentences. Do not add greetings or sign-offs.

Output exactly:
Answer: <text>
Sentiment: <positive | neutral | negative>
```

**What changed:** the implicit four tasks became three explicit, ordered steps,
and the unmeasurable "be friendly" was dropped in favor of concrete rules (at
most 4 sentences, no greetings) (principles 3, 8). The translation trigger is
now defined as the input language rather than "if needed" (principle 5). The
output is a fixed structure the caller can parse (principle 4), and an abstain
rule was added for unknown answers (honesty). Scope change, flagged: the
open-ended "summarize how they feel" was narrowed to a fixed sentiment label;
if you need a narrative sentiment summary, that is a separate job and is better
as its own prompt (principle 3).
