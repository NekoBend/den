# PowerShell reference

Decision pins for PowerShell (pwsh). Like the Python reference, this file
does not teach the language - it fixes one convention where the model knows
several, and defers to an explicit project choice when one exists.
Boundary: `shell.md` owns POSIX sh/bash; this file owns PowerShell; the
legacy cmd shims are compatibility surface, not a target for new code.

## 1. Target runtime: pwsh 7+

**Rule:** New scripts target PowerShell 7 or later and state it with
`#Requires -Version 7.0` when they use 7-only behavior.
Windows PowerShell 5.1 is a compatibility target only:
support it when the project says so, never by default.

**Why:** 5.1 diverges (no `$IsWindows`, different default encodings,
missing operators), and silently writing to the lowest common denominator
costs the features that make cross-platform scripts tractable.

- Cross-platform guards use `$IsWindows` / `$IsLinux` / `$IsMacOS`,
  not `$env:OS` string checks.
- Windows-only cmdlets (`Get-Acl`, registry providers, WMI/CIM) are
  gated or isolated, not sprinkled through shared code paths.

## 2. Tooling: PSScriptAnalyzer + Pester

**Rule:** Lint gate is `Invoke-ScriptAnalyzer` clean at `-Severity Error` -
the same bar the originating repository's CI applies. (Eight rules nominally; for a non-DSC
script the live set is four, none of which cover the conventions
below.) The conventions in sections
3, 5, 6, and 7 report at Warning severity: review enforces them, the
gate does not. Tests are Pester 5 (`Describe` / `It` / `Should`) in
`*.Tests.ps1` files, invoked separately (`Invoke-Pester`); the gate
lints test files, it does not run them.

**Why:** both tools are the ecosystem defaults and run on Linux, so the
gate works in CI without a Windows runner.

## 3. Naming

**Rule:** Functions are `Verb-Noun` with an approved verb (`Get-Verb`),
singular noun, PascalCase. Parameters PascalCase; locals camelCase.

- Unapproved verbs trigger analyzer warnings and break discoverability
  (`Get-Command -Verb`).
- Aliases (`dir`, `%`, `?`) are interactive conveniences:
  scripts spell out `Get-ChildItem`, `ForEach-Object`, `Where-Object`.
  On Linux and macOS, `ls` / `cat` / `cp` are NOT aliases - they resolve
  to the native binaries, so in a script they are native-command calls
  under section 4's `$LASTEXITCODE` rule.

## 4. Strict posture

**Rule:** Scripts open with `Set-StrictMode -Version Latest` and
`$ErrorActionPreference = 'Stop'`; recoverable paths use `try/catch`.

**Why:** the defaults (undefined variables expand to nothing,
errors continue) turn typos into silent wrong behavior;
strict mode turns them into failures at the fault line.

- Native-command failures are a pinned DECISION, not a language fact:
  since 7.4, `$PSNativeCommandUseErrorActionPreference = $true` makes
  native commands throw under `$ErrorActionPreference`. Pin: leave it
  at its default (`$false`) and check `$LASTEXITCODE` after every
  native call - identical behavior on 7.0-7.3, and the failure
  handling stays visible at the call site. `$?` is a last-command
  boolean, not an exit code.
- Terminating vs non-terminating matters: cmdlet failures obey
  `$ErrorActionPreference`; add `-ErrorAction Stop` on the calls whose
  failure must be caught even if a caller relaxed the preference.

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

## 7. Strings and injection

**Rule:** Single quotes by default; double quotes only when
interpolating, with `$(...)` for expressions. `Invoke-Expression` does
not appear in new code - it is PowerShell's `shell=True`.

- Build native-command arguments as separate tokens
  (`& $exe --flag $value`), never by concatenating a command string.
- Paths join with `Join-Path` and anchor on `$PSScriptRoot`,
  not string concatenation with a hardcoded separator
  (forward slashes work on Windows; backslashes do not work elsewhere).

## 8. When the toolchain runs this file

The checks for `.ps1` / `.psm1` are a syntax parse
(`[System.Management.Automation.Language.Parser]::ParseFile`) followed by
`Invoke-ScriptAnalyzer -Severity Error`; both degrade to SKIPPED when pwsh
or PSScriptAnalyzer is absent - say so rather than claiming a check that
did not run. `find-references.py` resolves `function` / `filter` /
`class` / `enum` definitions with no pwsh dependency.
