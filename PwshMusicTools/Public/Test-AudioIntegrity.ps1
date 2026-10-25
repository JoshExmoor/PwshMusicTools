function Test-AudioIntegrity {
<#
.SYNOPSIS
    Check audio files for corruption by fully decoding them with ffmpeg.

.DESCRIPTION
    Decodes each file with ffmpeg using strict error detection and reports
    OK, CORRUPT, or ERROR per file. Requires ffmpeg and ffprobe on the PATH.

    For FLAC, ffmpeg verifies each frame's CRCs but not the whole-file MD5
    signature stored in STREAMINFO. Use -VerifyFlacMD5 to also check that
    signature.

.PARAMETER VerifyFlacMD5
    For FLAC files, also verify the decoded audio against the MD5 signature in
    STREAMINFO. Uses 'flac -t' (the reference decoder) when flac is on the PATH;
    otherwise falls back to hashing ffmpeg's decoded PCM, which supports 8, 16,
    24 and 32-bit files. A mismatch marks the file CORRUPT. Files with no stored
    signature are reported with Md5Check 'Unset' rather than as a pass.

.OUTPUTS
    One PSCustomObject per file. With -VerifyFlacMD5, FLAC results also carry
    Md5Check (Match, Mismatch, Failed, Unset, Unchecked, Error), Md5Method
    ('flac' or 'ffmpeg') and Md5Detail.

.EXAMPLE
    Test-AudioIntegrity D:\Music -Recurse -VerifyFlacMD5 | Where-Object Status -ne 'OK'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string[]]$Path,

        [switch]$Recurse,

        [switch]$ShowProgress,

        [switch]$MeasureDecoded,

        [double]$TruncationToleranceSec = 1.0,

        [int]$ThrottleLimit = 4,

        [switch]$UseCache,

        [string]$CachePath = (Join-Path $env:LOCALAPPDATA 'Test-AudioIntegrity\cache.json'),

        [string[]]$Extension = @('flac','mp3','m4a','aac','ogg','opus','wav','wma','ape','wv'),

        [switch]$VerifyFlacMD5
    )

    begin {
        $allFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        $extRegex = '\.(' + (($Extension | ForEach-Object { [regex]::Escape($_.TrimStart('.')) }) -join '|') + ')$'
    }

    process {
        foreach ($p in $Path) {
            if (Test-Path -LiteralPath $p -PathType Container) {
                $gciParams = @{ Path = $p; File = $true }
                if ($Recurse) { $gciParams.Recurse = $true }
                $files = Get-ChildItem @gciParams -ErrorAction SilentlyContinue |
                         Where-Object { $_.Extension -match $extRegex }
            }
            elseif ((Test-Path -LiteralPath $p -PathType Leaf) -and $p -match $extRegex) {
                $files = @(Get-Item -LiteralPath $p)
            }
            else {
                Write-Warning "No matching audio files found at '$p'."
                continue
            }
            foreach ($f in $files) { $allFiles.Add($f) }
        }
    }

    end {
        $total = $allFiles.Count
        if ($total -eq 0) { return }

        # --- Load cache (path -> {Size, LastWriteUtc, Status, ...}) ---
        $cache = @{}
        if ($UseCache -and (Test-Path -LiteralPath $CachePath)) {
            try {
                $raw = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
                foreach ($entry in $raw) { $cache[$entry.File] = $entry }
            } catch { Write-Warning "Could not read cache at '$CachePath': $($_.Exception.Message)" }
        }

        # --- Partition: cached-OK-and-unchanged (skip) vs. needs-check ---
        $toCheck = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        $cachedResults = [System.Collections.Generic.List[object]]::new()
        foreach ($file in $allFiles) {
            $c = $cache[$file.FullName]
            # A cached FLAC 'OK' from a run without -VerifyFlacMD5 never had its
            # MD5 checked, so it must be re-checked when that switch is used now.
            $md5Pending = $VerifyFlacMD5 -and $c -and $file.Extension -ieq '.flac' -and
                          (-not $c.PSObject.Properties['Md5Check'] -or $c.Md5Check -notin 'Match', 'Unset')
            if ($UseCache -and $c -and $c.Status -eq 'OK' -and -not $md5Pending `
                -and [double]$c.Size -eq $file.Length `
                -and $c.LastWriteUtc -eq $file.LastWriteTimeUtc.ToString('o')) {
                $cachedResults.Add($c)
            } else {
                $toCheck.Add($file)
            }
        }

        # Emit cached (skipped) results immediately.
        foreach ($r in $cachedResults) { $r }

        $tol     = $TruncationToleranceSec
        $measure = [bool]$MeasureDecoded
        $skipped = $cachedResults.Count

        # FLAC MD5 verification: parallel runspaces cannot see private module
        # functions, so pass their source in and recreate them per runspace.
        $verifyMd5     = [bool]$VerifyFlacMD5
        $flacExe       = $null
        $flacHelperSrc = $null
        if ($verifyMd5) {
            $flacCmd = Get-Command flac -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($flacCmd) { $flacExe = $flacCmd.Source }
            Write-Verbose ("FLAC MD5 verification via {0}." -f $(if ($flacExe) { "flac -t ($flacExe)" } else { 'the ffmpeg fallback' }))

            # Read the helpers from the module's Private folder on disk rather than
            # from the loaded functions, so this works however the module was loaded
            # (normal import, an older loader, or this file dot-sourced on its own).
            $flacHelperFile = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Private') 'FlacMD5.ps1'
            if (-not (Test-Path -LiteralPath $flacHelperFile -PathType Leaf)) {
                throw ("-VerifyFlacMD5 needs '{0}', which was not found. Make sure the module's Private " +
                       "folder is present, then re-import the module with Import-Module <path>\PwshMusicTools.psd1 -Force.") -f $flacHelperFile
            }
            $flacHelperSrc = Get-Content -LiteralPath $flacHelperFile -Raw
        }

        # The per-file work as a reusable scriptblock for -Parallel.
        $worker = {
            $file = $_
            $tol     = $using:tol
            $measure = $using:measure
            $verifyMd5 = $using:verifyMd5
            $flacExe   = $using:flacExe
            if ($verifyMd5) { . ([scriptblock]::Create($using:flacHelperSrc)) }

            $ext = $file.Extension.TrimStart('.').ToLower()
            $errDetect = switch -Regex ($ext) {
                '^flac$'          { 'crccheck+bitstream'; break }
                '^(wav|ape|wv)$'  { 'crccheck+bitstream'; break }
                '^(ogg|opus)$'    { 'crccheck+bitstream'; break }
                '^(m4a|aac)$'     { '+explode'; break }
                default           { '+explode' }
            }

            $headerReadable = $false; $declaredSec = $null
            try {
                $probe = & ffprobe -v error -show_entries format=duration `
                                   -of default=noprint_wrappers=1:nokey=1 $file.FullName 2>&1
                if ($LASTEXITCODE -eq 0 -and $probe -match '^\s*[\d.]+\s*$') {
                    $headerReadable = $true; $declaredSec = [math]::Round([double]$probe, 2)
                }
            } catch { }

            try {
                $errs = & ffmpeg -v error -err_detect $errDetect -i $file.FullName -f null - 2>&1
                if ($LASTEXITCODE -ne 0 -or $errs) {
                    $status = "CORRUPT"
                    $detail = ($errs | Out-String).Trim() -replace '\s*\r?\n\s*', ' | '
                    if (-not $detail) { $detail = "ffmpeg exit code $LASTEXITCODE" }
                } else { $status = "OK"; $detail = "" }
            } catch { $status = "ERROR"; $detail = $_.Exception.Message }

            $decodedSec = $null; $truncated = $null
            if ($measure) {
                $truncated = $false
                try {
                    $statLines = & ffmpeg -nostats -i $file.FullName -f null - 2>&1
                    $timeMatch = [regex]::Matches(($statLines | Out-String), 'time=(\d+):(\d+):(\d+(?:\.\d+)?)')
                    if ($timeMatch.Count -gt 0) {
                        $last = $timeMatch[$timeMatch.Count - 1]
                        $decodedSec = [math]::Round(
                            [int]$last.Groups[1].Value * 3600 +
                            [int]$last.Groups[2].Value * 60 +
                            [double]$last.Groups[3].Value, 2)
                    }
                    if ($null -ne $declaredSec -and $null -ne $decodedSec -and
                        ($declaredSec - $decodedSec) -gt $tol) {
                        $truncated = $true
                        if ($status -eq 'OK') {
                            $status = 'CORRUPT'
                            $detail = "Silent truncation: declared ${declaredSec}s vs decoded ${decodedSec}s"
                        }
                    }
                } catch { }
            }

            # FLAC STREAMINFO MD5 check (frame CRCs don't cover the whole-file
            # signature). Skipped when the file already failed to decode at all.
            $md5Check = $null; $md5Method = $null; $md5Detail = $null
            if ($verifyMd5 -and $ext -eq 'flac' -and $status -ne 'ERROR') {
                try { $m = Test-FlacMD5 -Path $file.FullName -FlacExe $flacExe }
                catch { $m = [PSCustomObject]@{ Result = 'Error'; Method = $null; Detail = $_.Exception.Message } }
                # Never leave the check silently blank: no result means it didn't run.
                if ($null -eq $m -or -not $m.Result) {
                    $m = [PSCustomObject]@{ Result = 'Error'; Method = $null; Detail = 'FLAC MD5 check returned no result' }
                }

                $md5Check  = $m.Result
                $md5Method = $m.Method
                $md5Detail = $m.Detail
                if ($m.Result -in 'Mismatch', 'Failed') {
                    if ($status -eq 'OK') { $status = 'CORRUPT'; $detail = $m.Detail }
                    else { $detail = "$detail | $($m.Detail)" }
                }
            }

            [PSCustomObject]@{
                File           = $file.FullName
                Name           = $file.Name
                Format         = $ext
                SizeMB         = [math]::Round($file.Length / 1MB, 2)
                Status         = $status
                HeaderReadable = $headerReadable
                DeclaredSec    = $declaredSec
                DecodedSec     = $decodedSec
                Truncated      = $truncated
                ErrDetect      = $errDetect
                CheckedUtc     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
                Detail         = $detail
                Md5Check       = $md5Check
                Md5Method      = $md5Method
                Md5Detail      = $md5Detail
                Size           = $file.Length
                LastWriteUtc   = $file.LastWriteTimeUtc.ToString('o')
            }
        }

        # --- Process in batches of ThrottleLimit so progress updates per batch ---
        $checkTotal   = $toCheck.Count
        $corruptCount = 0
        $errorCount   = 0
        $done         = 0
        $freshResults = [System.Collections.Generic.List[object]]::new()

        for ($start = 0; $start -lt $checkTotal; $start += $ThrottleLimit) {
            $end   = [math]::Min($start + $ThrottleLimit, $checkTotal) - 1
            $batch = $toCheck[$start..$end]

            $batchResults = $batch | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel $worker

            foreach ($r in $batchResults) {
                switch ($r.Status) { 'CORRUPT' { $corruptCount++ } 'ERROR' { $errorCount++ } }
                $freshResults.Add($r)
                $r   # emit to pipeline
            }

            $done += $batch.Count
            if ($ShowProgress) {
                Write-Progress -Activity "Checking audio files" `
                               -Status "$done of $checkTotal : $corruptCount corrupt, $errorCount error" `
                               -PercentComplete (($done / $checkTotal) * 100)
            }
        }

        if ($ShowProgress) {
            Write-Progress -Activity "Checking audio files" -Completed
            $okCount = $checkTotal - $corruptCount - $errorCount
            Write-Information -MessageData (
                "Checked $checkTotal file(s), skipped $skipped cached-OK: $okCount OK, $corruptCount corrupt, $errorCount error."
            ) -InformationAction Continue
        }

        # --- Write cache back (merge fresh results over old) ---
        if ($UseCache) {
            try {
                $dir = Split-Path $CachePath
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                foreach ($r in $freshResults) { $cache[$r.File] = $r }
                $cache.Values | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $CachePath -Encoding UTF8
            } catch { Write-Warning "Could not write cache at '$CachePath': $($_.Exception.Message)" }
        }
    }
}
