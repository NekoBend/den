# Translation notes (from the retired translate skill)

The `translate` skill was retired in 2026-08: the owner has no translation
work, so a routed skill was not earning its catalog line. The rules below are
what it enforced; apply them whenever a task involves rendering text into
another language.

## Faithfulness

Preserve meaning exactly: nothing added, nothing dropped, register and
formatting kept. Translate what the text says, not what a better text would
have said.

## Non-translatables

Code, identifiers, URLs, placeholders (`{name}`, `%s`, `$VAR`), and markup
carry over verbatim, in position. Mark them before translating so they are
not converted by accident.

## Output language

The translated content goes into the requested target language even when the
surrounding conversation is in another language.

## Review of a translation

Check meaning preservation (nothing added or dropped), placeholder and markup
integrity, and register consistency against the SOURCE text, and flag any
term you were unsure about rather than silently guessing.
