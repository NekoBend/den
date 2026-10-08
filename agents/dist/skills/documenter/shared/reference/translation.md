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
Read the Rules of translation section below for the rules of each direction,
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

The translation goes into the target language,
even when the conversation around it is in another language;
your own comments stay in the user's language.
Translate what the text says, not what a better text would say:
report an error in the source in a translator's note
instead of fixing it in the translation.

### English into Japanese

- Drop "you", "we", and "I" when the Japanese reads naturally without them.
  When a subject is needed, name the role, such as ユーザー or 管理者.
- Do not keep a thing as the doer of an action:
  "The tool detects the device" becomes デバイスが検出されます.
- Translate a modal verb by what it does in the sentence,
  and keep its strength:
  a requirement (must) as 〜する必要があります,
  a recommendation (should) as 〜することをお勧めします,
  a permission (may, can) as 〜できます,
  a possibility (may, might) as 〜する場合があります.
- Prefer a verb to a noun followed by 実行します or 行います.
- Translate "please" by its function,
  not word for word into every sentence.

### Japanese into English

- Supply the subject and the object the Japanese leaves out
  when English needs them.
- Put the subject, the verb, and the object near the start of the sentence.
- Write plain English as shared/reference/writing.md describes;
  do not turn ください into "please",
  and do not carry Japanese politeness over as extra formality.
- Explain or rewrite an idiom or a culture-bound reference
  for a reader who does not know it.

### Terms and names

- Use a term from the user's glossary or an earlier translation first,
  then the standard term of the field,
  and keep one term for one idea in the whole document.
- Use an organization's official name in the target language
  when it has one.
- Write a person's name in the order and the spelling the person uses;
  ask when you do not know them.
- For a Japanese place name, romanize the proper part
  and translate the generic part: 日比谷公園 becomes Hibiya Park.

### Numbers, dates, and units

- Convert 万, 億, and 兆 explicitly, and check each result again:
  1万 is 10,000, 1億 is 100 million, and 1兆 is 1 trillion.
- Keep every boundary exact:
  以上 is "or more", 以下 is "or less",
  超える is "more than", and 未満 is "less than".
- In English, give a Japanese era year as the Gregorian year.
  In Japanese, write a date as 2026年10月8日,
  and add an era year only when the user asks for it.
- Keep every value as it is and change only its format.
  Convert a currency or a unit only when the user asks.
