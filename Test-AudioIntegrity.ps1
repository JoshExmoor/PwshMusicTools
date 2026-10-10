function Test-AudioIntegrity {
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

        [string[]]$Extension = @('flac','mp3','m4a','aac','ogg','opus','wav','wma','ape','wv')
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
            if ($UseCache -and $c -and $c.Status -eq 'OK' `
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

        # The per-file work as a reusable scriptblock for -Parallel.
        $worker = {
            $file = $_
            $tol     = $using:tol
            $measure = $using:measure

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