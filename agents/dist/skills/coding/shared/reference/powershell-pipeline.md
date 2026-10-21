# PowerShell reference: objects and the pipeline

Sections 5 and 6 of the PowerShell reference:
functions that return objects, and the pipeline and comparison traps.
shared/reference/powershell.md lists where every section lives.

## 5. Functions return objects

**Rule:** Functions emit objects (`[PSCustomObject]@{...}`), never
formatted text. `Format-*` appears only at the end of an interactive
pipeline. `Write-Host` is for user-facing interactive text only;
library code communicates through the pipeline, `Write-Verbose`,
`Write-Warning`, and errors.

**Why:** the pipeline is typed; a function that emits strings has
discarded the structure every downstream consumer needs.

- Advanced functions: `[CmdletBinding()]` plus a typed `param()` block
  with validation attributes (`[ValidateNotNullOrEmpty()]`,
  `[ValidateSet(...)]`) instead of hand-rolled `if` checks.
- Anything destructive declares `SupportsShouldProcess` and gates on
  `$PSCmdlet.ShouldProcess(...)`, so `-WhatIf` / `-Confirm` work.

## 6. Pipeline and comparison traps

- PowerShell unrolls single-element results: wrap in `@(...)` whenever
  `.Count` or array semantics matter.
- Comparison operators are case-INSENSITIVE by default (`-eq`, `-like`,
  `-match`); use the `c`-prefixed forms (`-ceq`) when case matters.
- `-eq` against an array FILTERS it (returns matching elements) rather
  than testing equality; put the scalar on the left, or test `.Count`.
- `$null` comparisons put `$null` on the LEFT (`$null -eq $x`), because
  the array-filter rule above makes `$x -eq $null` wrong for arrays
  (the analyzer flags the wrong order at Warning severity).
