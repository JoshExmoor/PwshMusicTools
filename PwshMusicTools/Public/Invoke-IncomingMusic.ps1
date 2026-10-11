function Invoke-IncomingMusic {
<#
.SYNOPSIS
    Run optional processing steps over the music files in a directory tree.

.DESCRIPTION
    Invoke-IncomingMusic walks the sub-directories of a given path and performs
    one or more opt-in processing steps on the audio files it finds. Each step is
    enabled by its own switch; with no step switch the function does nothing but
    warn, so it is safe to run exploratively.

    Steps currently available:

    -AudioIntegrity
        For every sub-directory that directly contains audio files, run
        Test-AudioIntegrity over that folder. Any file reported CORRUPT or ERROR
        is renamed with a 'CORRUPTED ' prefix so it stands out and sorts together.
        Files already prefixed are left alone (so re-runs are idempotent). Every
        flagged file is listed at the end of the run and returned as output.

        This step requires ffmpeg and ffprobe on the PATH (used by
        Test-AudioIntegrity); the function stops with an error if they are missing.

    The function supports -WhatIf and -Confirm: under -WhatIf the renames are
    previewed without touching any files.

.PARAMETER Path
    The root directory whose sub-directories will be processed. Audio files
    directly in this root are included as well.

.PARAMETER AudioIntegrity
    Enable the audio-integrity step described above.

.PARAMETER Extension
    Audio file extensions to consider (without the leading dot). Forwarded to
    Test-AudioIntegrity. Defaults to the common lossless/lossy set.

.OUTPUTS
    For -AudioIntegrity, one PSCustomObject per flagged file with:
      OriginalPath - the path before renaming (or the path checked, under -WhatIf)
      NewName      - the 'CORRUPTED '-prefixed name it was renamed to
      Status       - 'CORRUPT' or 'ERROR' as reported by Test-AudioIntegrity
      Detail       - the diagnostic detail from Test-AudioIntegrity
      Renamed      - [bool] whether the file was actually renamed

.EXAMPLE
    Invoke-IncomingMusic -Path 'D:\Incoming' -AudioIntegrity

    Checks every album folder under D:\Incoming and prefixes any corrupt or
    unreadable files with 'CORRUPTED '.

.EXAMPLE
    Invoke-IncomingMusic -Path 'D:\Incoming' -AudioIntegrity -WhatIf

    Previews which files would be flagged and renamed, changing nothing.
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string] $Path,

        [switch] $AudioIntegrity,

        [string[]] $Extension = @('flac','mp3','m4a','aac','ogg','opus','wav','wma','ape','wv')
    )

    begin {
        $prefix = 'CORRUPTED '
    }

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-Error "Path '$Path' is not a valid directory."
            return
        }

        # No step selected: do nothing but tell the caller why.
        if (-not $AudioIntegrity) {
            Write-Warning "No processing step was requested. Use -AudioIntegrity (and future step switches) to select work to perform."
            return
        }

        # --- Audio integrity step ---------------------------------------------
        if ($AudioIntegrity) {
            # Hard dependency: Test-AudioIntegrity shells out to ffmpeg / ffprobe.
            foreach ($tool in 'ffmpeg', 'ffprobe') {
                if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
                    Write-Error "-AudioIntegrity requires '$tool' on the PATH, but it was not found."
                    return
                }
            }

            $extRegex = '\.(' + (($Extension | ForEach-Object { [regex]::Escape($_.TrimStart('.')) }) -join '|') + ')$'

            # Find the directories (the root plus every sub-directory) that
            # directly contain at least one audio file. Test-AudioIntegrity is run
            # per such folder, as requested.
            $allDirs = @(Get-Item -LiteralPath $Path) +
                       @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -ErrorAction SilentlyContinue)

            $audioDirs = foreach ($dir in $allDirs) {
                $hasAudio = Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Extension -match $extRegex } |
                            Select-Object -First 1
                if ($hasAudio) { $dir }
            }

            $flagged = [System.Collections.Generic.List[object]]::new()

            foreach ($dir in $audioDirs) {
                Write-Verbose "Checking integrity of audio files in '$($dir.FullName)'."

                # Non-recursive: this folder's own files only (we iterate folders).
                $checkResults = Test-AudioIntegrity -Path $dir.FullName -Extension $Extension

                foreach ($r in $checkResults) {
                    if ($r.Status -ne 'CORRUPT' -and $r.Status -ne 'ERROR') { continue }

                    $file = Get-Item -LiteralPath $r.File -ErrorAction SilentlyContinue
                    if (-not $file) { continue }

                    # Idempotent: don't double-prefix a file flagged on a prior run.
                    if ($file.Name.StartsWith($prefix)) {
                        Write-Verbose "Already flagged, skipping: $($file.Name)"
                        continue
                    }

                    $newName = $prefix + $file.Name
                    $renamed = $false

                    if ($PSCmdlet.ShouldProcess($file.FullName, "Rename to '$newName' ($($r.Status))")) {
                        try {
                            Rename-Item -LiteralPath $file.FullName -NewName $newName -ErrorAction Stop
                            $renamed = $true
                        }
                        catch {
                            Write-Warning "Failed to rename '$($file.FullName)': $($_.Exception.Message)"
                        }
                    }

                    $flagged.Add([PSCustomObject][ordered]@{
                        OriginalPath = $file.FullName
                        NewName      = $newName
                        Status       = $r.Status
                        Detail       = $r.Detail
                        Renamed      = $renamed
                    })
                }
            }

            # Emit the per-file results to the pipeline.
            $flagged

            # End-of-run report of everything flagged.
            if ($flagged.Count -eq 0) {
                Write-Host "Audio integrity: no corrupt or unreadable files found." -ForegroundColor Green
            }
            else {
                Write-Host ("Audio integrity: {0} file(s) flagged as corrupt or unreadable:" -f $flagged.Count) -ForegroundColor Yellow
                foreach ($f in $flagged) {
                    Write-Host ("  [{0}] {1}" -f $f.Status, $f.OriginalPath) -ForegroundColor Yellow
                }
            }
        }
    }
}
