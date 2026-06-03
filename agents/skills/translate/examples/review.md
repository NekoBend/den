# Example: review mode

A worked QA of an existing translation against its source, catching a
mistranslation and a broken placeholder. This is the shape the review mode of
SKILL.md should produce. Adapt the shape, do not copy the wording.

## Input from the user

> Check this Spanish translation against the English source.
>
> Source: "Your password must be at least 8 characters. Click {link} to reset
> it."
> Translation: "Tu contraseña debe tener 8 caracteres. Haz clic en LINK para
> restablecerla."

## Worked output

**Issues:**

[mistranslation] sentence 1
Source:     "must be at least 8 characters"
Problem:    "debe tener 8 caracteres" says exactly 8, dropping "at least", so the
            rule reads as a fixed length instead of a minimum.
Suggestion: "debe tener al menos 8 caracteres"

[placeholder] sentence 2
Source:     "Click {link} to reset it"
Problem:    the `{link}` placeholder was translated to the literal word "LINK",
            so the app will show "LINK" instead of the real link.
Suggestion: "Haz clic en {link} para restablecerla"

**Verdict:** needs fixes.

## Why this is correct

- The review aligned the translation to the source segment by segment before
  judging (Step V1).
- It caught a mistranslation that changes meaning: "at least 8" became
  "8" exactly. This is a semantic error, not a style nit, so it matters
  (Step V2, rule 1).
- It caught a broken placeholder: `{link}` was turned into the literal text
  "LINK", which would break the rendered message. Placeholder integrity is a
  high-value check (Step V2, rule 2).
- Each issue names the location, quotes the source span, states the problem, and
  gives a concrete corrected suggestion (Step V3).
- The verdict ("needs fixes") follows from the issues found, rather than a vague
  "looks mostly fine".
