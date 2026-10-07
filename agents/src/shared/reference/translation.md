# documenter: translate mode

Steps T1 to T4 of documenter's translate mode,
with its output format, its checklist, and the rules of translation.
documenter's SKILL.md sends you here when the mode is translate.

### Step T1: Pin the brief

Before translating, settle:

- the source language and the target language
- who reads the translation, and where it is used
  (an internal reference, a published document, a UI)
- the register: a Japanese translation uses です・ます
  unless the user asks for another style;
  an English translation keeps the source's level of formality
- a glossary or an earlier translation to follow, if the user has one

Ask when the target language or the reader is unclear.

### Step T2: Mark what stays as it is

Before translating, mark these so they carry over unchanged and in place:
code, commands, identifiers, file paths, URLs,
placeholders such as {name}, %s, and $VAR,
markup and its tags,
UI labels that must match the product,
and proper nouns that have no established form in the target language.
When a name has an established form in the target language,
such as an organization's official English name,
use that form.

### Step T3: Translate the meaning

Read the whole paragraph before you translate its first sentence.
Translate what the text means, not its word order.
You may split a long sentence or join short ones
when the target language reads more naturally that way;
keep every piece of information.
Write the result the way a native writer of the target language
would write the same document.
Read shared/reference/translation.md for the rules of each direction,
and for numbers, dates, units, and names.
Into Japanese, also read shared/reference/japanese-style.md.
Keep the headings, lists, tables, and emphasis in the same structure.

When a sentence can be read two ways and the context does not decide it,
ask.
When you cannot ask,
translate the more likely reading,
and add a translator's note that gives the other reading.

### Step T4: Check against the source

After the whole draft is done, as a separate step,
compare it with the source:

- every sentence of the source is translated, and nothing is added
- every number, date, unit, name, URL, code span, and placeholder
  matches the source
- each term is translated the same way everywhere
- the register is the same from start to end

### Checking an existing translation

When the user asks to check a translation,
compare it with the source by the checks in Step T4.
Report each problem with its location, the source text,
the translated text, what is wrong, and a fix.
Rewrite the whole translation only when the user asks for it.

## Output format

The translation as one block, apart from your own comments.
After it, when there are any:

    **Translator's notes:**
    1. <location>: <the other reading, or the choice you made and why>

For a check of an existing translation:

    | Location | Source | Translation | Problem | Fix |

## Checklist (run before sending)

- [ ] The translation is in the target language.
- [ ] Nothing is added or dropped; I ran Step T4 as a separate step.
- [ ] Code, paths, URLs, placeholders, and markup are unchanged and in place.
- [ ] Each term is translated the same way, and the register stays the same.
- [ ] Each ambiguity is asked about or given a translator's note.

## Rules of translation

### Faithfulness

Preserve meaning exactly: nothing added, nothing dropped, register and
formatting kept. Translate what the text says, not what a better text would
have said.

### Non-translatables

Code, identifiers, URLs, placeholders (`{name}`, `%s`, `$VAR`), and markup
carry over verbatim, in position. Mark them before translating so they are
not converted by accident.

### Output language

The translated content goes into the requested target language even when the
surrounding conversation is in another language.

### Review of a translation

Check meaning preservation (nothing added or dropped), placeholder and markup
integrity, and register consistency against the SOURCE text, and flag any
term you were unsure about rather than silently guessing.
