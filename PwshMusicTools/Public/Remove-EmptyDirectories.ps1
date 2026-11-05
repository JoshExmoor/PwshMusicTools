function Remove-EmptyDirectories {
    <#
    .SYNOPSIS
        Recursively removes empty directories under a path, deepest first, so
        parents that only held empty directories are removed in the same run.

    .DESCRIPTION
        Walks the directory tree under -Path and removes every directory that is
        empty, processing the deepest directories first. A directory whose only
        contents were empty sub-directories becomes empty once they are removed,
        so the whole empty chain (e.g. a\b\c) goes in a single run.

        Rules:
          - The -Path root itself is never removed, even if it ends up empty.
          - Any file counts as content, including hidden or system files such as
            desktop.ini and Thumbs.db. Hidden items are enumerated.
          - Junctions and symbolic links are never followed or removed. A
            reparse-point directory counts as content of its parent. A -Path that
            is itself a junction or symbolic link is refused.
          - A directory that cannot be read or deleted (access denied, locked)
            produces a warning and the run continues; its parent then counts as
            non-empty and is kept.

        The set of directories to remove is planned first, then all removals are
        confirmed once per -Path, not once per directory. With pipeline input,
        each piped directory is its own -Path, so it gets its own prompt ("Yes to
        All" covers the rest). A bad piped item (not a directory, or a link)
        writes an error and the remaining items are still processed. Each directory is
        deleted non-recursively, so a directory that gained content after
        planning fails to delete (with a warning) instead of losing that content.

        Under -WhatIf nothing is deleted, but the plan treats every directory that
        would be removed as gone, so the WhatIf message and the returned paths show
        the full cascade a real run would remove.

        Returns the full paths of the removed directories (under -WhatIf, the
        directories that would be removed), deepest first.

    .PARAMETER Path
        The directory to clean. Only directories below it are removed. Accepts
        pipeline input, including directory objects from Get-Item/Get-ChildItem.

    .EXAMPLE
        Remove-EmptyDirectories -Path 'D:\Incoming' -WhatIf

        Lists every directory under D:\Incoming that would be removed, including
        parents that only become empty once their empty children are removed.
        Nothing is deleted.

    .EXAMPLE
        Remove-EmptyDirectories -Path 'D:\Incoming'

        Prompts once, then removes all empty directories under D:\Incoming and
        returns their paths.

    .EXAMPLE
        Get-ChildItem 'D:\Music' -Directory | Remove-EmptyDirectories -Confirm:$false

        Cleans each top-level folder of D:\Music without prompting. The top-level
        folders themselves are kept, as each one is a -Path root.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [ValidateNotNullOrEmpty()]
        [String]$Path
    )

    process {
        Set-StrictMode -Version Latest
        # No function-wide ErrorActionPreference = 'Stop': a bad piped item must
        # write a non-terminating error and let the remaining items run. Inner
        # calls that must stop use -ErrorAction Stop inside try/catch.

        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-Error "Path '$Path' is not a valid directory."
            return
        }
        try {
            $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        catch {
            Write-Error "Path '$Path' cannot be read: $($_.Exception.Message)"
            return
        }
        if ($rootItem.LinkType -in @('Junction', 'SymbolicLink')) {
            Write-Error "Path '$Path' is a $($rootItem.LinkType); refusing to remove directories through it."
            return
        }
        $rootFull = $rootItem.FullName

        # --- Plan --------------------------------------------------------------
        # Post-order walk: children are decided before their parent, so the plan
        # is naturally deepest-first and a parent sees its children as already
        # removed. Nothing is deleted here, so -WhatIf gets the full cascade.
        $plan = [System.Collections.Generic.List[string]]::new()

        $walk = {
            param([string]$Dir)
            try {
                $children = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Stop)
            }
            catch {
                Write-Warning "Remove-EmptyDirectories: cannot read '$Dir': $($_.Exception.Message)"
                return $false
            }

            $empty = $true
            foreach ($child in $children) {
                if (-not $child.PSIsContainer) { $empty = $false; continue }
                # Junctions/symlinks are content: never followed, never removed.
                if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $empty = $false; continue }
                if (& $walk $child.FullName) { $plan.Add($child.FullName) }
                else { $empty = $false }
            }
            return $empty
        }
        $null = & $walk $rootFull

        $removed = [System.Collections.Generic.List[string]]::new()

        # --- Remove (confirmed once for the whole batch) -----------------------
        if ($plan.Count -gt 0) {
            $target = "$($plan.Count) empty director(ies) under '$rootFull':`n  " + ($plan -join "`n  ")
            if ($PSCmdlet.ShouldProcess($target, 'Remove empty directories')) {
                # Parents of a directory that failed (or was skipped) are not empty.
                $blocked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($dir in $plan) {
                    $parent = [System.IO.Path]::GetDirectoryName($dir)
                    if ($blocked.Contains($dir)) {
                        Write-Verbose "Keeping '$dir': a sub-directory could not be removed."
                        $null = $blocked.Add($parent)
                        continue
                    }
                    $info = [System.IO.DirectoryInfo]::new($dir)
                    $attrs = $info.Attributes
                    try {
                        # A read-only flag would block deletion of an empty folder.
                        if ($attrs -band [System.IO.FileAttributes]::ReadOnly) {
                            $info.Attributes = $attrs -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                        }
                        # Non-recursive: fails rather than deleting anything that
                        # appeared since planning.
                        $info.Delete()
                        $removed.Add($dir)
                    }
                    catch {
                        Write-Warning "Remove-EmptyDirectories: failed to remove '$dir': $($_.Exception.Message)"
                        try { if ($info.Exists) { $info.Attributes = $attrs } } catch { }
                        $null = $blocked.Add($parent)
                    }
                }
            }
            elseif ($WhatIfPreference) {
                $removed.AddRange($plan)
            }
        }

        Write-Host ("Remove-EmptyDirectories: {0} {1} empty director(ies) under '{2}'." -f $(if ($WhatIfPreference) { 'would remove' } else { 'removed' }), $removed.Count, $rootFull) -ForegroundColor $(if ($removed.Count) { 'Green' } else { 'Yellow' })

        # Typed array rather than a unary comma, so @() callers don't get a nested array.
        return [object[]]$removed.ToArray()
    }
}
