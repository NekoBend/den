---
name: translate
description: Translate text from one language to another, or review an existing translation against its source. Use this skill when the user asks to translate / render / put into <language> a passage, OR to check / proofread / QA a translation for accuracy. Detects the mode (translate, or review). Preserves meaning, formatting, and non-translatable tokens (code, identifiers, URLs, placeholders); never adds or drops content. The translated content goes into the requested target language even when the surrounding conversation is in another language.
---

# Translate skill

Carry meaning across languages without changing it.
Translate the message, preserve everything that is not language:
code, formatting, and placeholders.

This skill runs under a parent system prompt.
<honesty_contract> and <language_policy> from the parent always apply;
this skill does not override them.

## Relation to the parent language policy

The parent language policy sets the language of your normal replies. In this
skill, the TRANSLATION itself goes into the user's requested target language,
which can differ from the conversation language. Any explanation you add around
the translation still follows the parent policy (the user's message language).

## Faithfulness and preservation rules (both modes)

1. Translate meaning, not words. Add nothing, drop nothing. If the source is
   ambiguous, preserve the ambiguity; do not resolve it by inventing.
2. Do NOT translate, and keep verbatim and in position: code and identifiers,
   API names, URLs and file paths, brand or product names (unless an official
   localized name exists), and placeholders or format tokens
   (`%s`, `{name}`, `{{var}}`, `<tag>`, `:variable`).
3. Preserve formatting and markup: Markdown, HTML tags, line breaks, lists, and
   code fences stay intact and in the same structure.
4. Match the source register and tone (formal or informal) unless the user
   specifies otherwise.
5. Keep numeric values, units, and dates as they are; localize their format
   only if the user asks.
6. When a term is ambiguous or has no clean target equivalent, choose the best
   option and flag it. Do not silently drop or invent.

## Detect the mode

First decide which one mode the request is, then follow that mode below:

1. translate: produce a translation of source text into a target language.
   Triggers: translate this, render this in <language>, put this into <language>.
2. review: check an existing translation against its source.
   Triggers: check this translation, proofread / QA this translation, is this
   translation accurate, did I translate this correctly.

If the request is ambiguous, ASK. Run ONE mode per request.

## Mode: translate

### Step T1: Pin source and target
Detect the source language. Confirm the target language, and any register,
audience, or locale, from the user. If the target is unclear, ASK.

### Step T2: Mark the non-translatables
Identify the code, identifiers, placeholders, URLs, and markup that must carry
over verbatim, so they are not translated by accident.

### Step T3: Translate
Render the meaning into the target language, preserving register and formatting
and keeping every non-translatable in place.

### Step T4: Check
Meaning is preserved (nothing added or dropped), every placeholder and markup
element is intact and in position, and the register is consistent. Flag any
term you were unsure about.

## Mode: review

### Step V1: Align source and translation
Put the source and the translation side by side, segment by segment.

### Step V2: Find the issues
Check each segment for: mistranslation (meaning changed), omission (source
content missing), addition (content not in the source), register mismatch, and
broken, missing, or moved placeholders or markup.

### Step V3: Report
For each issue: the location, the source span, the problem, and a corrected
suggestion. Then an overall verdict: accurate, or needs fixes.

## Output format

### translate mode

The translation, with the source's formatting preserved.
Then, only if needed:

    **Notes:** <terms you flagged: ambiguity, untranslatable kept verbatim, a
    register choice you made>

### review mode

    **Issues:**
    [mistranslation | omission | addition | register | placeholder] <location>
    Source:     "<source span>"
    Problem:    <what is wrong>
    Suggestion: <corrected translation>
    (repeat per issue)

    **Verdict:** <accurate | needs fixes>

For JSON output (when explicitly requested), follow the parent <output_format>
two-step pattern.

## Self-check (run before sending)

Common:
- [ ] I picked exactly one mode and stated it (or asked when unclear).
- [ ] Meaning is preserved: nothing was added or dropped.
- [ ] Code, identifiers, URLs, placeholders, and markup are kept verbatim and
      in position.
- [ ] Register and formatting match the source (unless the user asked otherwise).

If translate:
- [ ] The target language (and locale/register if given) was pinned, or I asked.
- [ ] I flagged any ambiguous or untranslatable term rather than guessing.

If review:
- [ ] I checked for mistranslation, omission, addition, register, and broken
      placeholders.
- [ ] Each issue has a location, the source span, the problem, and a fix.
- [ ] I gave an overall verdict.
