# Example: contradicting reports become a debate, and the metric was the bug

A worked integrate pass where two workers disagree and the decisive
fact turns out to be a broken instrument. This is the shape rules 3
and 4 of SKILL.md should produce together. Adapt the shape, do not
copy the wording.

## Situation

An earlier review round left two contradicting conclusions on the
table:

- worker 1: "feature X almost never activates - 0 of 12 in the logs -
  so add a routing section to make it activate."
- worker 2: "the activation data is worthless, and the feature's
  output is no better than doing nothing; do not add anything."

Both cannot be right, and a decision (ship 20 permanent lines, or
not) hangs on which is.

## Worked output

**Plan** (rule 4: do not average - "add a smaller routing section" is
the merge this pass exists to prevent): one advocate per side, each
briefed with the OTHER side's report and told to attack its evidence;
each must also name the cheapest experiment that would prove their own
side wrong. Read-only. Engines at the master's tier - this is
judgment work.

**Launched:** two adversarial advocates, one message, background.
The user got the one-line version and a DECIDE on an unrelated matter
while the debate ran.

**Returned:** both advocates, independently, attacked the same thing -
the number. The "0 of 12" was counted by grepping log files that turn
out to be empty for this tool: the harness captured the wrong output
stream, so the count measured the logger, not the feature. One
advocate reconstructed the real rate from primary records (the
session transcripts) as 6 of 54; the other showed the "no better than
nothing" claim rested on a benchmark that never exercised the feature.

**Verified** (rule 3, by the master, before deciding): re-counted the
primary records directly - the transcripts confirm 6 activations; the
log files confirm 0 bytes. Both advocates' central claims reproduce.

**Adopted / rejected:** both original conclusions rejected - each was
built on the broken number in a different way. Adopted instead: fix
the instrument first, re-measure, and only then decide the feature
question. The published claim that used the wrong number was
retracted at its source, not just corrected going forward.

**Changed:** the harness captures the right stream now; the decision
record states the falsifier ("revisit only if the re-measured rate
stays under N"); the routing section was not shipped.
