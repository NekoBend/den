# documenter: guide mode

Steps G0 to G4 of documenter's guide mode,
with its output format and its checklist.
documenter's SKILL.md sends you here when the mode is guide.

### Step G0: Pick the format and the destination

Markdown by default. Choose HTML when the document's own structure is what
makes it hard to read as plain text:

- a specification, or anything with numbered requirements that get
  cross-referenced
- a summary that has to hold several dimensions at once (comparison tables,
  a matrix, results per case)
- anything carrying a diagram, or where layout is part of the meaning

Markdown stays right for a README, an API reference, CONTRIBUTING, and any
file the user said lives in the repository: anything reviewed, versioned, or
edited there stays Markdown, since its diffs must show content, not markup.
Anything an agent re-reads as working state (memory files, imprints, context
payloads) stays plain minimal text with no markup that multiplies its token
cost; that rule wins even inside a repository, so a committed memory or
context file stays minimal Markdown or plain text, never styled markup. Do
not infer repository residence from the
working directory - code files sitting nearby are not a signal that this
document gets committed. When the request carries numbered requirements or a
per-case table and the user did not say where the file goes, choose HTML.

When you pick HTML, write ONE self-contained file: styles inline, no external
fonts, scripts, or images, readable by opening it in a browser with no
server. Say which format you chose and why in one line, so the user can ask
for the other one.

When the destination is a Confluence page:

1. Read shared/reference/confluence.md.
2. Use the edition and the route the user named.
   When the user named none,
   assume Data Center and its page editor,
   and say so on an ASSUMED: line.
3. Write the first draft in Markdown,
   so the user can check the content before it goes into Confluence.
4. When the user says the draft is fine,
   write the same content again in the Confluence storage format
   (XHTML with ac: macros).
   Change no content in this step; only the format changes.
   Tell the user to paste it into a source editor
   that edits the storage format:
   the <> icon in the editor toolbar
   (built into Data Center 10.2.3 and later,
   a Marketplace app on earlier versions),
   or an Open in source editor button.
   When the page has no source editor,
   give Confluence wiki markup for Insert > Markup instead.

This two-step flow is for Confluence pages only.
The storage format is not the self-contained HTML file described above;
do not mix the two.

### Step G1: Pin the reader, the goal, and the scope

Write down three things before you write the document:

- the reader: their role, and how much they already know about the topic
- the goal: what the reader can do, decide, or understand after reading
- the scope: what the document covers, and what it does not cover

Put the reader and the scope near the top of the document itself.
When two kinds of readers need different things,
write one document or one clearly separated section for each.
Ask when the reader or the goal is unclear.

### Step G2: Pick the genre and outline

Read shared/reference/doc-genres.md now,
pick one genre from its table,
and outline the sections in the table's order.

### Step G3: Write the sections

Read shared/reference/writing.md and follow it.
When the document is in Japanese,
also read shared/reference/japanese-style.md,
and write the whole document in です・ます
unless the user asks for another style.

Put the conclusion, the recommendation, or the request
in the first paragraph,
then the reasons and the details.
Mark anything the source does not support
as a proposal, a plan, or an open question (Source rule).

When the request is to revise a draft:
keep every claim, number, name, and date the draft contains,
and change only how it is written.
Do not add a fact or a claim.
If a sentence is unclear in meaning, not only in wording,
ask instead of guessing what it meant.

### Step G4: Reader check

Read the document as the reader from Step G1 and check:

- the title and the headings alone give the conclusion and the flow
- the conclusion or the request is in the first paragraph
- every term is defined at its first use, and one idea keeps one term
- every number, date, name, owner, and due date matches the source
- a procedure works when followed from the first step, with nothing assumed but unstated
- the row's check in the genre table holds

## Output format

The document itself, with section headings in reading order. End with:

    **Assumes:** <prerequisites or environment the reader must already have>

For a Confluence page, start the reply with one line that names the format
(the Markdown draft, the storage format, or wiki markup)
and how it goes into the page.

For a revised draft, after the document, list what you changed:

    **Changed:**
    - <what changed, and why>   (one line each)

## Checklist (run before sending)

- [ ] I chose the format on the document's structure and said which and why;
      for Confluence, I gave the Markdown draft first,
      and the storage format only after the user said the draft is fine.
- [ ] The reader, the goal, and the scope are pinned and stated near the top.
- [ ] The document has one genre, its sections follow the table,
      every heading states its point, and the row's check holds.
- [ ] The conclusion or the request is in the first paragraph.
- [ ] A Japanese document is in です・ます from start to end
      (unless the user asked for another style).
- [ ] For a revision, every claim, number, name, and date is kept,
      and I listed what I changed.
