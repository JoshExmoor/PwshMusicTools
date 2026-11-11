function Export-AudioIntegrityReport {
    <#
    .SYNOPSIS
        Checks a music collection with Test-AudioIntegrity and builds a report,
        optionally exported to CSV and/or JSON.

    .DESCRIPTION
        Runs Test-AudioIntegrity over -Path (recursively by default) and turns its
        results into a single report object with three sections:

          Summary             ScanRoot, StartTime, EndTime, Duration,
                              DurationSeconds, Partial, TotalFiles, StatusCounts
                              (OK, CORRUPT, ERROR, plus any other status seen),
                              ExtensionCounts and ProblemDirectoryCount.
          Files               One row per file checked, OK files included: Path,
                              Directory, Name, Extension, Status, Detail, SizeMB,
                              HeaderReadable, DeclaredSec, DecodedSec, Truncated,
                              Md5Check, Md5Method, Md5Detail, CheckedUtc and
                              LastWriteUtc.
          ProblemDirectories  Every directory with at least one file whose status
                              is not OK, with Directory, ProblemCount,
                              CorruptCount, ErrorCount and FileCount, sorted by
                              ProblemCount (worst first), then by Directory.

        -CsvPath writes the Files rows (UTF-8). -JsonPath writes the whole
        report, with ISO 8601 timestamps. Both can be given in one call. With
        neither, nothing is written. The report object is always returned and a
        one-line summary is printed to the console.

        Both output paths are checked before the scan starts: the folder must
        exist and the file must be writable. Existing report files are
        overwritten. The exports are written even when some files are CORRUPT or
        ERROR. If the scan is interrupted (Ctrl+C or an unexpected error), the
        results gathered so far are still written and Summary.Partial is True.

        Audio files are only read, never modified. With -UseCache,
        Test-AudioIntegrity may write its own cache file; files it skips as
        cached-OK appear with status OK.

    .PARAMETER Path
        The collection root: a directory or a single audio file. Accepts several
        paths and pipeline input (including objects with a FullName property).

    .PARAMETER CsvPath
        Where to write the per-file CSV. Overwritten if it exists.

    .PARAMETER JsonPath
        Where to write the full report as JSON. Overwritten if it exists.

    .PARAMETER Recurse
        Scan subdirectories. On by default, since a collection is a tree; use
        -Recurse:$false to check only the top level of each directory.

    .PARAMETER ShowProgress
        Passed to Test-AudioIntegrity.

    .PARAMETER MeasureDecoded
        Passed to Test-AudioIntegrity.

    .PARAMETER TruncationToleranceSec
        Passed to Test-AudioIntegrity.

    .PARAMETER ThrottleLimit
        Passed to Test-AudioIntegrity: how many files are checked in parallel.

    .PARAMETER UseCache
        Passed to Test-AudioIntegrity.

    .PARAMETER CachePath
        Passed to Test-AudioIntegrity.

    .PARAMETER Extension
        Passed to Test-AudioIntegrity: the audio extensions to check.

    .PARAMETER VerifyFlacMD5
        Passed to Test-AudioIntegrity.

    .OUTPUTS
        A single PSCustomObject with Summary, Files and ProblemDirectories.

    .EXAMPLE
        Export-AudioIntegrityReport -Path 'D:\Music' -CsvPath 'C:\Temp\integrity.csv'

        Checks the whole collection and writes one CSV row per file.

    .EXAMPLE
        Export-AudioIntegrityReport -Path 'D:\Music' -JsonPath 'C:\Temp\integrity.json' -VerifyFlacMD5

        Checks the collection, including FLAC MD5 signatures, and writes the full
        report as JSON.

    .EXAMPLE
        $report = Export-AudioIntegrityReport -Path 'D:\Music' -CsvPath 'C:\Temp\integrity.csv' -JsonPath 'C:\Temp\integrity.json' -ThrottleLimit 8
        $report.ProblemDirectories | Select-Object -First 10

        Writes both exports in one scan and lists the ten worst directories.

    .EXAMPLE
        Get-ChildItem 'D:\Music' -Directory | Export-AudioIntegrityReport

        Checks each top-level folder (recursively), writes nothing, and returns
        the report object.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvPath,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$JsonPath,

        [switch]$Recurse,

        [switch]$ShowProgress,

        [switch]$MeasureDecoded,

        [double]$TruncationToleranceSec,

        [int]$ThrottleLimit,

        [switch]$UseCache,

        [string]$CachePath,

        [string[]]$Extension,

        [switch]$VerifyFlacMD5
    )

    begin {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        # --- Validate output paths before the (possibly hours-long) scan --------
        # Get-WritableReportPath is a shared helper in Private\ReportPath.ps1.

        $csvFull  = $null
        $jsonFull = $null
        if ($PSBoundParameters.ContainsKey('CsvPath'))  { $csvFull  = Get-WritableReportPath $CsvPath 'CsvPath' }
        if ($PSBoundParameters.ContainsKey('JsonPath')) { $jsonFull = Get-WritableReportPath $JsonPath 'JsonPath' }
        if ($csvFull -and $jsonFull -and $csvFull -eq $jsonFull) {
            throw "CsvPath and JsonPath must be different files ('$csvFull')."
        }

        # Ask now rather than after the scan, so -Confirm never holds back the
        # results of a long run and nothing prompts while an interrupt unwinds.
        $writeCsv  = [bool]$csvFull  -and (Confirm-ShouldProcess -Cmdlet $PSCmdlet -Target $csvFull  -Action 'Write CSV integrity report')
        $writeJson = [bool]$jsonFull -and (Confirm-ShouldProcess -Cmdlet $PSCmdlet -Target $jsonFull -Action 'Write JSON integrity report')

        # --- Options passed through to Test-AudioIntegrity -----------------------

        $taiParams = @{ Recurse = $true }
        if ($PSBoundParameters.ContainsKey('Recurse')) { $taiParams.Recurse = [bool]$Recurse }
        foreach ($name in 'ShowProgress', 'MeasureDecoded', 'TruncationToleranceSec', 'ThrottleLimit',
                          'UseCache', 'CachePath', 'Extension', 'VerifyFlacMD5') {
            if ($PSBoundParameters.ContainsKey($name)) { $taiParams[$name] = $PSBoundParameters[$name] }
        }

        $paths = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($p in $Path) { $paths.Add($p) }
    }

    end {
        function Get-Field($Object, [string]$Name) {
            $prop = $Object.PSObject.Properties[$Name]
            if ($prop) { return $prop.Value }
            return $null
        }

        # Test-AudioIntegrity writes CheckedUtc as 'yyyy-MM-dd HH:mm:ss' (UTC), and
        # a cached LastWriteUtc may come back from JSON as a DateTime; normalise both
        # to ISO 8601.
        function ConvertTo-IsoUtc($Value) {
            if ($null -eq $Value -or $Value -eq '') { return $null }
            if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact([string]$Value, 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal,
                    [ref]$parsed)) {
                return $parsed.ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            return [string]$Value
        }

        $fileColumns = 'Path', 'Directory', 'Name', 'Extension', 'Status', 'Detail', 'SizeMB', 'HeaderReadable',
                       'DeclaredSec', 'DecodedSec', 'Truncated', 'Md5Check', 'Md5Method', 'Md5Detail',
                       'CheckedUtc', 'LastWriteUtc'

        $results   = [System.Collections.Generic.List[object]]::new()
        $startTime = Get-Date
        $completed = $false
        $report    = $null

        try {
            # Collect as results stream in, so an interrupted scan keeps what it has.
            Test-AudioIntegrity -Path $paths.ToArray() @taiParams | ForEach-Object { $results.Add($_) }
            $completed = $true
        }
        finally {
            $endTime = Get-Date

            # --- Build the report ------------------------------------------------

            $files = [System.Collections.Generic.List[object]]::new()
            foreach ($r in $results) {
                $filePath = [string](Get-Field $r 'File')
                $files.Add([PSCustomObject][ordered]@{
                    Path           = $filePath
                    Directory      = [System.IO.Path]::GetDirectoryName($filePath)
                    Name           = [System.IO.Path]::GetFileName($filePath)
                    Extension      = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()
                    Status         = [string](Get-Field $r 'Status')
                    Detail         = Get-Field $r 'Detail'
                    SizeMB         = Get-Field $r 'SizeMB'
                    HeaderReadable = Get-Field $r 'HeaderReadable'
                    DeclaredSec    = Get-Field $r 'DeclaredSec'
                    DecodedSec     = Get-Field $r 'DecodedSec'
                    Truncated      = Get-Field $r 'Truncated'
                    Md5Check       = Get-Field $r 'Md5Check'
                    Md5Method      = Get-Field $r 'Md5Method'
                    Md5Detail      = Get-Field $r 'Md5Detail'
                    CheckedUtc     = ConvertTo-IsoUtc (Get-Field $r 'CheckedUtc')
                    LastWriteUtc   = ConvertTo-IsoUtc (Get-Field $r 'LastWriteUtc')
                })
            }

            $statusCounts = [ordered]@{ OK = 0; CORRUPT = 0; ERROR = 0 }
            foreach ($f in $files) { $statusCounts[$f.Status] = [int]$statusCounts[$f.Status] + 1 }

            $extensionCounts = [ordered]@{}
            foreach ($g in @($files | Group-Object Extension | Sort-Object Name)) {
                $extensionCounts[$(if ($g.Name) { $g.Name } else { '(none)' })] = $g.Count
            }

            $problemDirs = [System.Collections.Generic.List[object]]::new()
            foreach ($g in @($files | Group-Object Directory)) {
                $problems = @($g.Group | Where-Object Status -ne 'OK')
                if ($problems.Count -eq 0) { continue }
                $problemDirs.Add([PSCustomObject][ordered]@{
                    Directory    = $g.Name
                    ProblemCount = $problems.Count
                    CorruptCount = @($problems | Where-Object Status -eq 'CORRUPT').Count
                    ErrorCount   = @($problems | Where-Object Status -eq 'ERROR').Count
                    FileCount    = $g.Count
                })
            }
            $sortedDirs = @($problemDirs | Sort-Object @{ Expression = 'ProblemCount'; Descending = $true },
                                                       @{ Expression = 'Directory'; Descending = $false })

            $duration = $endTime - $startTime
            $report = [PSCustomObject][ordered]@{
                Summary            = [PSCustomObject][ordered]@{
                    ScanRoot              = [object[]]@($paths | ForEach-Object {
                                                $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) })
                    StartTime             = $startTime.ToString('o')
                    EndTime               = $endTime.ToString('o')
                    Duration              = $duration.ToString('c')
                    DurationSeconds       = [math]::Round($duration.TotalSeconds, 2)
                    Partial               = -not $completed
                    TotalFiles            = $files.Count
                    StatusCounts          = [PSCustomObject]$statusCounts
                    ExtensionCounts       = [PSCustomObject]$extensionCounts
                    ProblemDirectoryCount = $sortedDirs.Count
                }
                Files              = [object[]]$files.ToArray()
                ProblemDirectories = [object[]]$sortedDirs
            }

            # --- Write exports ---------------------------------------------------
            # In 'finally' so an interrupted scan still saves what it gathered.
            # -WhatIf was resolved up front ($writeCsv/$writeJson).

            if ($writeCsv) {
                try {
                    if ($files.Count -gt 0) {
                        $files | Export-Csv -LiteralPath $csvFull -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false
                    }
                    else {
                        # No rows: still write the header so the file reflects the scan.
                        $header = ($fileColumns | ForEach-Object { '"' + $_ + '"' }) -join ','
                        [System.IO.File]::WriteAllText($csvFull, $header + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
                    }
                }
                catch { Write-Warning "Could not write CSV report '$csvFull': $($_.Exception.Message)" }
            }
            if ($writeJson) {
                try {
                    $json = $report | ConvertTo-Json -Depth 10
                    [System.IO.File]::WriteAllText($jsonFull, $json, [System.Text.UTF8Encoding]::new($false))
                }
                catch { Write-Warning "Could not write JSON report '$jsonFull': $($_.Exception.Message)" }
            }
        }

        # --- Console summary ---------------------------------------------------

        $s = $report.Summary
        $line = 'Export-AudioIntegrityReport: {0} file(s) checked: {1} OK, {2} CORRUPT, {3} ERROR; {4} problem director{5}.' -f
            $s.TotalFiles, $s.StatusCounts.OK, $s.StatusCounts.CORRUPT, $s.StatusCounts.ERROR,
            $s.ProblemDirectoryCount, $(if ($s.ProblemDirectoryCount -eq 1) { 'y' } else { 'ies' })
        if ($writeCsv)  { $line += " CSV: $csvFull." }
        if ($writeJson) { $line += " JSON: $jsonFull." }
        $clean = $s.StatusCounts.CORRUPT -eq 0 -and $s.StatusCounts.ERROR -eq 0 -and $s.ProblemDirectoryCount -eq 0
        Write-Host $line -ForegroundColor $(if ($clean) { 'Green' } else { 'Yellow' })

        return $report
    }
}
