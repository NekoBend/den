# troubleshoot: diagnose and repair modes

Steps D1 to D4 of troubleshoot's diagnose mode
and Steps P1 to P3 of its repair mode,
whose Step P4 stays in SKILL.md.
troubleshoot's SKILL.md sends you here when the mode is diagnose or repair.

## Mode: diagnose

### Step D1: Write down what changed
A failure that is new has a cause that is new. Ask the same three
questions before opening the code, because two of the answers are not in
it: what changed in the code (a diff, a commit, a release), what changed
in the environment (a dependency version, a runtime, an OS, a config, a
clock, a network path), and what changed in the data (size, encoding,
a null that was never there before).

"The code is wrong" and "the code is unchanged and the world moved" both
produce this failure, and they need different fixes. Deciding between
them is the first real step, not an afterthought.

### Step D2: State competing hypotheses
At least two, written down. A single hypothesis is a conclusion you have
already reached, and you will read the evidence to fit it.

### Step D3: Find the observation that separates them
For each pair, name a check whose result differs depending on which is
true, then run it. Prefer a check that can FALSIFY - a test that passes
under both hypotheses tells you nothing.
Useful separators: bisect the history until the first bad commit; bisect
the input until the first bad element; run the same code in the other
environment; print the value at the boundary rather than reasoning about
what it must be.

### Step D4: Name the cause
One sentence, with the observation that establishes it. If two candidates
survive, say so and name what would separate them, rather than picking
the more likely one and presenting it as settled.

## Mode: repair

### Step P1: Fix the cause
Not the symptom. If you are catching an exception, suppressing a warning,
adding a retry, or special-casing a value, say explicitly whether that is
the cause or a workaround; both are legitimate, and the difference is
what the next reader needs.

### Step P2: Write the test that would have caught it
It must FAIL before the fix and PASS after. Run it both ways and report
both results. A regression test you did not see fail is not known to test
anything.

### Step P3: Check the blast radius
The same mistake usually appears more than once. Search for the pattern
you just fixed elsewhere in the codebase and report what you find,
whether or not you fix it in this pass.
