function Find-DirsWithMatchingFiles {
<#
.SYNOPSIS
    Finds directories containing at least a given number of files matching a filter.

.DESCRIPTION
    Recursively walks a directory tree and returns each directory that directly
    contains at least -Count files whose names match -Filter. Matches in
    subdirectories are not counted toward a parent directory's total; each
    directory is evaluated on its own immediate files only. Hidden and system
    files and directories are included in the search.

    Output is one object per qualifying directory, with the directory's full
    path and the number of matching files it contains.

.PARAMETER Filter
    A Windows wildcard filter applied to file names, e.g. '01*.*' or 'IMG_*.jpg'.
    This uses the provider's simple wildcard matching (* and ?), not regex.
    This parameter is mandatory.

.PARAMETER Count
    The minimum number of matching files a directory must contain to be
    returned. Must be 2 or greater. Defaults to 2.

.PARAMETER Path
    The root directory to search from. Defaults to the current directory ('.').

.INPUTS
    None. This function does not accept pipeline input.

.OUTPUTS
    PSCustomObject with two properties:
      Directory [string] - the full path of the matching directory.
      Count     [int]    - the number of matching files in that directory.

.EXAMPLE
    Find-DirsWithMatchingFiles -Filter '01*.*'

    Lists directories under the current location that contain two or more files
    whose names start with '01'.

.EXAMPLE
    Find-DirsWithMatchingFiles -Filter 'IMG_*.jpg' -Count 5

    Lists directories containing five or more matching JPEG files.

.EXAMPLE
    Find-DirsWithMatchingFiles -Filter '*.mp3' -Path 'D:\Music'

    Searches the D:\Music tree for directories with two or more MP3 files.

.NOTES
    -Filter uses simple wildcards only. For regex matching, replace the inner
    Get-ChildItem's -Filter with a Where-Object { $_.Name -match '<pattern>' }.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Filter,

        [ValidateRange(2, [int]::MaxValue)]
        [int]$Count = 2,

        [string]$Path = '.'
    )

    # Walk every subdirectory of $Path, including hidden/system ones (-Force).
    Get-ChildItem -Path $Path -Directory -Recurse -Force |
        ForEach-Object {
            # Count only the matching files directly in this directory,
            # not those in its subdirectories.
            $matches = Get-ChildItem -LiteralPath $_.FullName -File -Filter $Filter -Force
            if ($matches.Count -ge $Count) {
                # Emit one result object per qualifying directory.
                [PSCustomObject]@{
                    Directory = $_.FullName
                    Count     = $matches.Count
                }
            }
        }
}
