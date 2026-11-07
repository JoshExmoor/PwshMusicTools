# Private seam around $PSCmdlet.ShouldProcess.

function Confirm-ShouldProcess {
    <#
        Calls ShouldProcess on the caller's cmdlet and returns its answer. It
        behaves exactly like calling $PSCmdlet.ShouldProcess directly (-WhatIf,
        -Confirm, and the prompt's Yes to All / No to All all carry across calls
        made with the same cmdlet object), but as a module function it can be
        mocked in tests with `Mock -ModuleName PwshMusicTools`, so a declined
        prompt can be simulated.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Action
    )

    return $Cmdlet.ShouldProcess($Target, $Action)
}
