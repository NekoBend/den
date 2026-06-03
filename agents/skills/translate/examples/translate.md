# Example: translate mode

A worked translation showing meaning preserved and non-translatable tokens
(placeholders, URLs, markup) kept verbatim and in position. This is the shape
the translate mode of SKILL.md should produce. Adapt the shape, do not copy the
wording.

## Input from the user

> Translate to Spanish:
> "Hi {name}, your order #%d shipped. Track it at https://ex.co/t/{id}. See our
> [returns policy](https://ex.co/returns)."

## Worked output

Hola {name}, tu pedido núm. %d ha sido enviado. Síguelo en
https://ex.co/t/{id}. Consulta nuestra
[política de devoluciones](https://ex.co/returns).

**Notes:** register is informal ("tu"), matching the casual source. The link
text "returns policy" is translated, but the URL inside the Markdown link is
kept verbatim.

## Why this is correct

- Meaning is preserved with nothing added or dropped (rule 1).
- The placeholders `{name}`, `%d`, and `{id}` are kept exactly and in position;
  they were not translated or reformatted (rule 2). A broken placeholder would
  break the running software, so this is the highest-value preservation.
- The URLs (`https://ex.co/t/{id}`, `https://ex.co/returns`) are kept verbatim;
  only the human-readable link text was translated (rules 2 and 3).
- The Markdown link structure `[text](url)` is intact (rule 3).
- The register choice (informal "tu" over formal "usted") was made deliberately
  and flagged in Notes, rather than left implicit (rule 4).
