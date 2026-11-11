# Private: validation for report output paths.
# Shared by Export-AudioIntegrityReport and Find-CoverArt.

function Get-WritableReportPath {
    <#
        Resolves a report path to a full file path and checks, before any work
        starts, that it can be written: it must not be a directory, its parent
        folder must exist, and the file must open for writing. An existing file
        is left untouched; a new one is probed with a delete-on-close file, so
        nothing is left behind (e.g. under -WhatIf). Throws a message naming
        the parameter on failure; returns the full path on success.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Value)
    if (Test-Path -LiteralPath $full -PathType Container) {
        throw "$Name '$full' is a directory, not a file."
    }
    $dir = Split-Path -Parent $full
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "$Name folder '$dir' does not exist."
    }
    try {
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            # Opening for write without truncating leaves the file as is.
            $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write)
        }
        else {
            # Probe file is deleted on close, so -WhatIf leaves nothing behind.
            $stream = [System.IO.FileStream]::new($full, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)
        }
        $stream.Dispose()
    }
    catch {
        throw "$Name '$full' is not writable: $($_.Exception.Message)"
    }
    return $full
}
