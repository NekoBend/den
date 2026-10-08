# documenter: rules for every mode

The source rule that every mode of documenter follows,
and the JSON output format.
documenter's SKILL.md sends you here before you detect the mode.

## Source rule (all modes)

Write only what a source supports.
For reference mode and for a guide about software,
the source is the code or the system.
For any other document,
the source is the material the user gave you:
notes, decisions, data, an earlier draft.

When the document needs something no source supports,
ask for it,
or mark it in the text as a proposal, a plan, or an open question.
Never state it as fact.
Do not add a feature, a decision, a date, a number, or an owner
that the source does not contain.

In translate mode the source is the original text:
render all of it,
and add nothing.

## Output format

### JSON output

For JSON output (when explicitly requested), use the two-step pattern:
a short reasoning block first, then a single fenced ```json``` block
with nothing after the closing fence.
