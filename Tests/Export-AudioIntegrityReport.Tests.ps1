BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools

    # Builds a fake Test-AudioIntegrity result with the same shape the real
    # command emits.
    function New-FakeResult([string]$File, [string]$Status, [string]$Detail = '') {
        [PSCustomObject]@{
            File           = $File
            Name           = [System.IO.Path]::GetFileName($File)
            Format         = [System.IO.Path]::GetExtension($File).TrimStart('.').ToLower()
            SizeMB         = 1.5
            Status         = $Status
            HeaderReadable = $true
            DeclaredSec    = 200.0
            DecodedSec     = $null
            Truncated      = $null
            ErrDetect      = '+explode'
            CheckedUtc     = '2024-05-01 12:34:56'
            Detail         = $Detail
            Md5Check       = $null
            Md5Method      = $null
            Md5Detail      = $null
            Size           = 1572864
            LastWriteUtc   = '2024-04-01T10:00:00.0000000Z'
        }
    }
}

Describe 'Export-AudioIntegrityReport' {

    BeforeEach {
        $script:root  = New-TestDir
        $script:music = Join-Path $root 'Music'
        $script:out   = Join-Path $root 'out'
        New-Item -ItemType Directory -Path $music, $out -Force | Out-Null
        $script:csv  = Join-Path $out 'report.csv'
        $script:json = Join-Path $out 'report.json'

        $script:dirA = Join-Path $music 'ArtistA\Album1'   # 2 problems
        $script:dirB = Join-Path $music 'ArtistB\Album2'   # 1 problem
        $script:dirC = Join-Path $music 'ArtistC\Album3'   # clean
        $script:dirD = Join-Path $music 'ArtistD\Album4'   # 2 problems, sorts after A

        $script:fake = @(
            New-FakeResult (Join-Path $dirA '01.flac') 'CORRUPT' 'bad frame'
            New-FakeResult (Join-Path $dirA '02.flac') 'ERROR'   'cannot open'
            New-FakeResult (Join-Path $dirA '03.flac') 'OK'
            New-FakeResult (Join-Path $dirB '01.mp3')  'CORRUPT' 'invalid header'
            New-FakeResult (Join-Path $dirB '02.mp3')  'OK'
            New-FakeResult (Join-Path $dirC '01.opus') 'OK'
            New-FakeResult (Join-Path $dirC '02.opus') 'OK'
            New-FakeResult (Join-Path $dirD '01.mp3')  'CORRUPT' 'x'
            New-FakeResult (Join-Path $dirD '02.FLAC') 'CORRUPT' 'y'
        )
        $results = $script:fake
        Mock -ModuleName PwshMusicTools Test-AudioIntegrity { $results }.GetNewClosure()
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    It 'is exported by the module' {
        (Get-Command Export-AudioIntegrityReport -Module PwshMusicTools).Name | Should -Be 'Export-AudioIntegrityReport'
    }

    It 'does not prompt by default (default ConfirmImpact)' {
        $attr = (Get-Command Export-AudioIntegrityReport).ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $attr.SupportsShouldProcess | Should -BeTrue
        $attr.ConfirmImpact | Should -Be 'Medium'
    }

    It 'returns a single report object and writes no files when no export path is given' {
        $report = Export-AudioIntegrityReport -Path $music 6>$null

        $report | Should -Not -BeNullOrEmpty
        @($report).Count | Should -Be 1
        $report.PSObject.Properties.Name | Should -Be @('Summary', 'Files', 'ProblemDirectories')
        $report.Files.Count | Should -Be 9
        @(Get-ChildItem -LiteralPath $out -Force).Count | Should -Be 0
    }

    It 'passes the path to Test-AudioIntegrity and recurses by default' {
        Export-AudioIntegrityReport -Path $music -ThrottleLimit 8 6>$null | Out-Null

        Should -Invoke Test-AudioIntegrity -ModuleName PwshMusicTools -Times 1 -Exactly -ParameterFilter {
            $Path -contains $music -and $Recurse -and $ThrottleLimit -eq 8
        }
    }

    It 'allows recursion to be turned off' {
        Export-AudioIntegrityReport -Path $music -Recurse:$false 6>$null | Out-Null

        Should -Invoke Test-AudioIntegrity -ModuleName PwshMusicTools -Times 1 -Exactly -ParameterFilter { -not $Recurse }
    }

    It 'accepts pipeline input and scans all paths in one call' {
        $report = $dirA, $dirB | Export-AudioIntegrityReport 6>$null

        Should -Invoke Test-AudioIntegrity -ModuleName PwshMusicTools -Times 1 -Exactly -ParameterFilter {
            $Path.Count -eq 2 -and $Path -contains $dirA -and $Path -contains $dirB
        }
        $report.Summary.ScanRoot | Should -Be @($dirA, $dirB)
    }

    It 'builds the summary counts per status and extension' {
        $s = (Export-AudioIntegrityReport -Path $music 6>$null).Summary

        $s.TotalFiles | Should -Be 9
        $s.StatusCounts.OK | Should -Be 4
        $s.StatusCounts.CORRUPT | Should -Be 4
        $s.StatusCounts.ERROR | Should -Be 1
        $s.ExtensionCounts.'.flac' | Should -Be 4
        $s.ExtensionCounts.'.mp3' | Should -Be 3
        $s.ExtensionCounts.'.opus' | Should -Be 2
        $s.ProblemDirectoryCount | Should -Be 3
        $s.Partial | Should -BeFalse
        $s.ScanRoot | Should -Be @($music)
        { [datetime]::Parse($s.StartTime) } | Should -Not -Throw
        [datetime]::Parse($s.EndTime) | Should -BeGreaterOrEqual ([datetime]::Parse($s.StartTime))
    }

    It 'lists problem directories worst first, then by name' {
        $dirs = (Export-AudioIntegrityReport -Path $music 6>$null).ProblemDirectories

        $dirs.Directory | Should -Be @($dirA, $dirD, $dirB)
        $dirs[0].ProblemCount | Should -Be 2
        $dirs[0].CorruptCount | Should -Be 1
        $dirs[0].ErrorCount | Should -Be 1
        $dirs[0].FileCount | Should -Be 3
        $dirs[2].ProblemCount | Should -Be 1
    }

    It 'fills the per-file fields' {
        $f = (Export-AudioIntegrityReport -Path $music 6>$null).Files[0]

        $f.Path | Should -Be (Join-Path $dirA '01.flac')
        $f.Directory | Should -Be $dirA
        $f.Name | Should -Be '01.flac'
        $f.Extension | Should -Be '.flac'
        $f.Status | Should -Be 'CORRUPT'
        $f.Detail | Should -Be 'bad frame'
        $f.CheckedUtc | Should -Be '2024-05-01T12:34:56Z'
    }

    It 'writes only the CSV when -CsvPath is given' {
        Export-AudioIntegrityReport -Path $music -CsvPath $csv 6>$null | Out-Null

        Get-FileNames -Dir $out | Should -Be @('report.csv')
        $rows = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
        $rows.Count | Should -Be 9
        $rows[0].PSObject.Properties.Name | Should -Be @('Path', 'Directory', 'Name', 'Extension', 'Status', 'Detail',
            'SizeMB', 'HeaderReadable', 'DeclaredSec', 'DecodedSec', 'Truncated', 'Md5Check', 'Md5Method',
            'Md5Detail', 'CheckedUtc', 'LastWriteUtc')
        @($rows | Where-Object Status -eq 'OK').Count | Should -Be 4
    }

    It 'writes only the JSON when -JsonPath is given' {
        Export-AudioIntegrityReport -Path $music -JsonPath $json 6>$null | Out-Null

        Get-FileNames -Dir $out | Should -Be @('report.json')
    }

    It 'writes both exports in one call' {
        Export-AudioIntegrityReport -Path $music -CsvPath $csv -JsonPath $json 6>$null | Out-Null

        Get-FileNames -Dir $out | Should -Be @('report.csv', 'report.json')
        Should -Invoke Test-AudioIntegrity -ModuleName PwshMusicTools -Times 1 -Exactly
    }

    It 'overwrites existing report files' {
        Set-Content -LiteralPath $csv -Value 'old'
        Set-Content -LiteralPath $json -Value 'old'

        Export-AudioIntegrityReport -Path $music -CsvPath $csv -JsonPath $json 6>$null | Out-Null

        @(Import-Csv -LiteralPath $csv).Count | Should -Be 9
        (Get-Content -LiteralPath $json -Raw | ConvertFrom-Json).Summary.TotalFiles | Should -Be 9
    }

    It 'round-trips the JSON with every section intact' {
        $report = Export-AudioIntegrityReport -Path $music -JsonPath $json 6>$null

        $back = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        $back.PSObject.Properties.Name | Should -Be @('Summary', 'Files', 'ProblemDirectories')
        $back.Summary.TotalFiles | Should -Be 9
        $back.Summary.StatusCounts.CORRUPT | Should -Be 4
        $back.Summary.ExtensionCounts.'.mp3' | Should -Be 3
        $back.Summary.ProblemDirectoryCount | Should -Be 3
        $back.Summary.Partial | Should -BeFalse
        @($back.Summary.ScanRoot) | Should -Be @($music)
        @($back.Files).Count | Should -Be 9
        $back.Files[1].Detail | Should -Be 'cannot open'
        @($back.ProblemDirectories).Directory | Should -Be @($report.ProblemDirectories.Directory)
        $back.ProblemDirectories[0].ErrorCount | Should -Be 1

        # Timestamps are ISO 8601 in the file itself.
        $raw = Get-Content -LiteralPath $json -Raw
        $raw | Should -Match '"StartTime":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $raw | Should -Match '"CheckedUtc":\s*"2024-05-01T12:34:56Z"'
    }

    It 'writes empty sections and a CSV header when no files are found' {
        Mock -ModuleName PwshMusicTools Test-AudioIntegrity { }

        $report = Export-AudioIntegrityReport -Path $music -CsvPath $csv -JsonPath $json 6>$null

        $report.Summary.TotalFiles | Should -Be 0
        (Get-Content -LiteralPath $csv -First 1) | Should -Match '^"Path","Directory"'
        $back = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        @($back.Files).Count | Should -Be 0
        @($back.ProblemDirectories).Count | Should -Be 0
    }

    It 'fails before scanning when the output folder does not exist' {
        $bad = Join-Path $root 'missing\report.csv'

        { Export-AudioIntegrityReport -Path $music -CsvPath $bad 6>$null } | Should -Throw '*does not exist*'
        Should -Invoke Test-AudioIntegrity -ModuleName PwshMusicTools -Times 0 -Exactly
    }

    It 'fails before scanning when the JSON path is not writable' {
        Set-Content -LiteralPath $json -Value 'locked'
        $lock = [System.IO.File]::Open($json, 'Open', 'Read', 'None')
        try {
            { Export-AudioIntegrityReport -Path $music -CsvPath $csv -JsonPath $json 6>$null } | Should -Throw '*not writable*'
        }
        finally { $lock.Dispose() }
        Should -Invoke Test-AudioIntegrity -ModuleName PwshMusicTools -Times 0 -Exactly
        Test-Path -LiteralPath $csv | Should -BeFalse
    }

    It 'fails before scanning when the output path is a directory' {
        { Export-AudioIntegrityReport -Path $music -JsonPath $out 6>$null } | Should -Throw '*is a directory*'
        Should -Invoke Test-AudioIntegrity -ModuleName PwshMusicTools -Times 0 -Exactly
    }

    It 'writes no files under -WhatIf but still returns the report' {
        $report = Export-AudioIntegrityReport -Path $music -CsvPath $csv -JsonPath $json -WhatIf 6>$null

        @(Get-ChildItem -LiteralPath $out -Force).Count | Should -Be 0
        $report.Summary.TotalFiles | Should -Be 9
    }

    It 'writes the results gathered so far, marked partial, when the scan is interrupted' {
        $partial = $script:fake[0..2]
        Mock -ModuleName PwshMusicTools Test-AudioIntegrity { $partial; throw 'interrupted' }.GetNewClosure()

        { Export-AudioIntegrityReport -Path $music -CsvPath $csv -JsonPath $json 6>$null } | Should -Throw '*interrupted*'

        @(Import-Csv -LiteralPath $csv).Count | Should -Be 3
        $back = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        $back.Summary.Partial | Should -BeTrue
        $back.Summary.TotalFiles | Should -Be 3
    }

    It 'never modifies the audio files it checks' {
        $file = New-EmptyFile -Dir $dirA -Name 'song.flac'
        Set-Content -LiteralPath $file -Value 'audio'
        $before = Get-Item -LiteralPath $file
        $hash = (Get-FileHash -LiteralPath $file).Hash
        $one = New-FakeResult $file 'OK'
        Mock -ModuleName PwshMusicTools Test-AudioIntegrity { $one }.GetNewClosure()

        Export-AudioIntegrityReport -Path $music -CsvPath $csv -JsonPath $json 6>$null | Out-Null

        (Get-FileHash -LiteralPath $file).Hash | Should -Be $hash
        (Get-Item -LiteralPath $file).LastWriteTimeUtc | Should -Be $before.LastWriteTimeUtc
    }
}
