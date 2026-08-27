# PowerShell worked example

A worked example demonstrating the rules in
`shared/reference/powershell.md`. The domain matches the shell example:
a small order-management CLI. One fragment, illustrating the rules the
reference pins; cross-references in the prose point at its sections.

Code in the block contains only natural comments (the kind a real
developer writes for non-obvious WHY). Instructional / meta comments
belong in this prose, never in the code.

## An advanced function with strict posture and a destructive gate

This block demonstrates powershell.md section 1 (pwsh 7 target),
section 4 (strict posture, `$LASTEXITCODE` after a native call),
section 5 (objects out, `[CmdletBinding()]`, validation attributes,
`ShouldProcess` on the destructive path), and section 7 (argument
tokens, no `Invoke-Expression`).

```powershell
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Order {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OrderId
    )
    # curl is a native command: it does not throw, so the exit code is
    # the only failure signal (reference section 4).
    $json = & curl --silent --fail "https://orders.internal/api/$OrderId"
    if ($LASTEXITCODE -ne 0) {
        throw "order service returned exit code $LASTEXITCODE for $OrderId"
    }
    $order = $json | ConvertFrom-Json
    [PSCustomObject]@{
        Id     = $order.id
        Status = $order.status
        Total  = [decimal]$order.total
    }
}

function Remove-StaleOrder {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OrderId
    )
    if ($PSCmdlet.ShouldProcess($OrderId, 'delete stale order')) {
        & curl --silent --fail -X DELETE "https://orders.internal/api/$OrderId"
        if ($LASTEXITCODE -ne 0) {
            throw "delete failed with exit code $LASTEXITCODE for $OrderId"
        }
    }
}
```

A Pester test for the pure part lives in `Get-Order.Tests.ps1`
(reference section 2; the lint gate lints test files, Pester runs them):

```powershell
Describe 'Get-Order' {
    It 'returns a typed object for a well-formed payload' {
        Mock curl { '{"id":"o1","status":"open","total":"12.50"}' }
        $o = Get-Order -OrderId o1
        $o.Total | Should -BeOfType [decimal]
    }
}
```

Points a reviewer should recognize from the reference: no
`Write-Host` in library code, no `Format-*` in the function, the
`$LASTEXITCODE` check after every native call, `ShouldProcess` gating
the delete so `-WhatIf` works, and arguments passed as separate tokens
rather than an interpolated command string.
