# grounding: ground mode

Steps G1 to G3 of grounding's ground mode,
whose Step G4 stays in SKILL.md.
grounding's SKILL.md sends you here when the mode is ground.

### Step G1: Read the provided context
Treat ONLY the supplied context as ground truth.
Note each passage's id so you can cite it.

### Step G2: Locate support for the answer
For each part of the question, find the passage span that answers it.
If the context does not answer a part, that part is Not enough information;
say so explicitly. Do not answer it from outside knowledge.

### Step G3: Compose the answer
Write the answer using only supported statements.
Attach a citation (passage id plus quoted span) to each statement.
Stay within what the context supports; do not extrapolate.
