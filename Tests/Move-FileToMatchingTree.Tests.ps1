BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Move-FileToMatchingTree' {

    BeforeEach {
        $script:root = New-TestDir
        $script:src  = Join-Path $root 'NewMusic'
        $script:dest = Join-Path $root 'Music'
        $script:csv  = Join-Path $root 'report.csv'
        # Destination library: Genre\Artist\Album
        $script:destAlbum = Join-Path $dest 'Rock\Artist\Album'
        New-Item -ItemType Directory -Path $src, $destAlbum -Force | Out-Null
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    It 'is exported by the module' {
        (Get-Command Move-FileToMatchingTree -Module PwshMusicTools).Name | Should -Be 'Move-FileToMatchingTree'
    }

    It 'prompts by default (ConfirmImpact High)' {
        (Get-Command Move-FileToMatchingTree).ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            ForEach-Object { $_.ConfirmImpact } | Should -Be 'High'
    }

    It 'does not prompt again per file once the batch is confirmed' {
        Mock -ModuleName PwshMusicTools Move-Item { }
        New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name 'song.opus' | Out-Null

        Move-FileToMatchingTree -Source $src -DestinationHead $dest -OutputCSV $csv -Confirm:$false 6>$null | Out-Null

        Should -Invoke Move-Item -ModuleName PwshMusicTools -Times 1 -Exactly -ParameterFilter {
            $PesterBoundParameters.ContainsKey('Confirm') -and -not $PesterBoundParameters['Confirm'] -and
            $PesterBoundParameters.ContainsKey('WhatIf') -and -not $PesterBoundParameters['WhatIf']
        }
    }

    It 'moves a single file at depth 2 into a Genre\Artist\Album tree' {
        $file = New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name 'song.opus'

        $rows = @(Move-FileToMatchingTree -Source $file -DestinationHead $dest -OutputCSV $csv -Depth 2 -Confirm:$false 6>$null)

        $rows.Count | Should -Be 1
        $rows[0].MovedToPath | Should -Be (Join-Path $destAlbum 'song.opus')
        Test-Path -LiteralPath (Join-Path $destAlbum 'song.opus') | Should -BeTrue
        Test-Path -LiteralPath $file | Should -BeFalse
    }

    It 'defaults to depth 2' {
        (Get-Command Move-FileToMatchingTree).Parameters['Depth'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] } |
            ForEach-Object { $_.MinRange, $_.MaxRange } | Should -Be @(1, 4)
        # A different artist with the same album name: depth 2 must not match it.
        $file = New-EmptyFile -Dir (Join-Path $src 'Other\Album') -Name 'song.opus'

        $rows = @(Move-FileToMatchingTree -Source $file -DestinationHead $dest -OutputCSV $csv -Confirm:$false 6>$null)

        $rows[0].MovedToPath | Should -Be 'Could not find destination'
        Test-Path -LiteralPath $file | Should -BeTrue
    }

    It 'moves a single file at depth 1 matching on the album folder only' {
        $file = New-EmptyFile -Dir (Join-Path $src 'Different Artist\Album') -Name 'song.opus'

        $rows = @(Move-FileToMatchingTree -Source $file -DestinationHead $dest -OutputCSV $csv -Depth 1 -Confirm:$false 6>$null)

        $rows[0].MovedToPath | Should -Be (Join-Path $destAlbum 'song.opus')
        Test-Path -LiteralPath (Join-Path $destAlbum 'song.opus') | Should -BeTrue
    }

    It 'rejects a depth above 4' {
        $file = New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name 'song.opus'
        { Move-FileToMatchingTree -Source $file -DestinationHead $dest -OutputCSV $csv -Depth 5 -Confirm:$false } |
            Should -Throw
    }

    It 'recurses into a source directory' {
        $otherAlbum = Join-Path $dest 'Jazz\Someone\Record'
        New-Item -ItemType Directory -Path $otherAlbum -Force | Out-Null
        New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name '01 a.opus' | Out-Null
        New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name '02 b.opus' | Out-Null
        New-EmptyFile -Dir (Join-Path $src 'Someone\Record') -Name '01 c.opus' | Out-Null

        $rows = @(Move-FileToMatchingTree -Source $src -DestinationHead $dest -OutputCSV $csv -Confirm:$false 6>$null)

        $rows.Count | Should -Be 3
        Get-FileNames -Dir $destAlbum  | Should -Be @('01 a.opus', '02 b.opus')
        Get-FileNames -Dir $otherAlbum | Should -Be @('01 c.opus')
    }

    It 'reports Could not find destination and leaves the file when nothing matches' {
        $file = New-EmptyFile -Dir (Join-Path $src 'Nobody\Nothing') -Name 'song.opus'

        $rows = @(Move-FileToMatchingTree -Source $src -DestinationHead $dest -OutputCSV $csv -Confirm:$false 6>$null)

        $rows[0].MovedToPath | Should -Be 'Could not find destination'
        $rows[0].DestinationBaseFileNameMatch | Should -BeFalse
        Test-Path -LiteralPath $file | Should -BeTrue
        (Import-Csv -LiteralPath $csv)[0].MovedToPath | Should -Be 'Could not find destination'
    }

    It 'does not move the file when more than one destination matches' {
        New-Item -ItemType Directory -Path (Join-Path $dest 'Pop\Artist\Album') -Force | Out-Null
        $file = New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name 'song.opus'

        $rows = @(Move-FileToMatchingTree -Source $file -DestinationHead $dest -OutputCSV $csv -Confirm:$false 6>$null)

        $rows[0].MovedToPath | Should -Be 'Could not find destination'
        $rows[0].Note | Should -BeLike 'Multiple destination matches:*'
        Test-Path -LiteralPath $file | Should -BeTrue
        Get-FileNames -Dir $destAlbum | Should -BeNullOrEmpty
    }

    It 'sets DestinationBaseFileNameMatch True when the same base name exists with another extension' {
        New-EmptyFile -Dir $destAlbum -Name 'song.mp3' | Out-Null
        $file = New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name 'song.opus'

        $rows = @(Move-FileToMatchingTree -Source $file -DestinationHead $dest -OutputCSV $csv -Confirm:$false 6>$null)

        $rows[0].DestinationBaseFileNameMatch | Should -BeTrue
        Get-FileNames -Dir $destAlbum | Should -Be @('song.mp3', 'song.opus')
    }

    It 'sets DestinationBaseFileNameMatch False when no file shares the base name' {
        New-EmptyFile -Dir $destAlbum -Name 'other.mp3' | Out-Null
        $file = New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name 'song.opus'

        $rows = @(Move-FileToMatchingTree -Source $file -DestinationHead $dest -OutputCSV $csv -Confirm:$false 6>$null)

        $rows[0].DestinationBaseFileNameMatch | Should -BeFalse
        $rows[0].MovedToPath | Should -Be (Join-Path $destAlbum 'song.opus')
    }

    It 'does not overwrite an identical file name in the destination' {
        $existing = New-EmptyFile -Dir $destAlbum -Name 'song.opus'
        Set-Content -LiteralPath $existing -Value 'original'
        New-EmptyFile -Dir $destAlbum -Name 'song.mp3' | Out-Null
        $file = New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name 'song.opus'

        $rows = @(Move-FileToMatchingTree -Source $file -DestinationHead $dest -OutputCSV $csv -Confirm:$false 6>$null)

        $rows[0].MovedToPath | Should -BeNullOrEmpty
        $rows[0].Note | Should -BeLike 'Destination file already exists*'
        $rows[0].DestinationBaseFileNameMatch | Should -BeTrue
        Test-Path -LiteralPath $file | Should -BeTrue
        Get-Content -LiteralPath $existing | Should -Be 'original'
    }

    It 'moves nothing under -WhatIf but still writes the report' {
        $file = New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name 'song.opus'

        $rows = @(Move-FileToMatchingTree -Source $src -DestinationHead $dest -OutputCSV $csv -WhatIf 6>$null)

        Test-Path -LiteralPath $file | Should -BeTrue
        Get-FileNames -Dir $destAlbum | Should -BeNullOrEmpty
        $rows[0].MovedToPath | Should -BeNullOrEmpty
        $rows[0].Note | Should -Be "WhatIf: would move to '$(Join-Path $destAlbum 'song.opus')'"
        Test-Path -LiteralPath $csv | Should -BeTrue
    }

    It 'moves nothing when the OutputCSV folder does not exist' {
        $file = New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name 'song.opus'
        $badCsv = Join-Path $root 'missing\report.csv'

        { Move-FileToMatchingTree -Source $src -DestinationHead $dest -OutputCSV $badCsv -Confirm:$false 6>$null } |
            Should -Throw '*does not exist*'

        Test-Path -LiteralPath $file | Should -BeTrue
        Get-FileNames -Dir $destAlbum | Should -BeNullOrEmpty
    }

    It 'does not process the report file when it lies inside the source directory' {
        # Library folder named like the source root, so a depth-1 report would match.
        $newMusicLib = Join-Path $dest 'NewMusic'
        New-Item -ItemType Directory -Path $newMusicLib -Force | Out-Null
        $inSourceCsv = Join-Path $src 'report.csv'
        Set-Content -LiteralPath $inSourceCsv -Value 'old report'
        New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name 'song.opus' | Out-Null

        $rows = @(Move-FileToMatchingTree -Source $src -DestinationHead $dest -OutputCSV $inSourceCsv -Depth 1 -Confirm:$false 6>$null)

        $rows.Count | Should -Be 1
        $rows[0].SourcePath | Should -Be (Join-Path $src 'Artist\Album\song.opus')
        Get-FileNames -Dir $newMusicLib | Should -BeNullOrEmpty
        Test-Path -LiteralPath $inSourceCsv | Should -BeTrue
    }

    It 'matches folder names case-insensitively and keeps destination casing' {
        $file = New-EmptyFile -Dir (Join-Path $src 'artist\album') -Name 'Song.opus'

        $rows = @(Move-FileToMatchingTree -Source $file -DestinationHead $dest -OutputCSV $csv -Confirm:$false 6>$null)

        $rows[0].MovedToPath | Should -BeExactly (Join-Path $destAlbum 'Song.opus')
        Get-FileNames -Dir $destAlbum | Should -Be @('Song.opus')
    }

    It 'still writes the report when the move stage is interrupted' {
        New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name '01 a.opus' | Out-Null
        New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name '02 b.opus' | Out-Null
        New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name '03 c.opus' | Out-Null
        $script:moveCalls = 0
        # First move really happens; the second fails and the per-file error
        # handler itself throws, so a terminating error escapes the move loop
        # mid-batch. (A real PipelineStoppedException can't be contained inside
        # a Pester test: it aborts the run.)
        Mock -ModuleName PwshMusicTools Move-Item {
            $script:moveCalls++
            if ($script:moveCalls -eq 1) {
                Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination
            }
            else {
                throw 'disk gone'
            }
        }
        Mock -ModuleName PwshMusicTools Write-Warning { throw 'Simulated interruption' }

        { Move-FileToMatchingTree -Source $src -DestinationHead $dest -OutputCSV $csv -Confirm:$false 6>$null } |
            Should -Throw '*Simulated interruption*'

        Test-Path -LiteralPath $csv | Should -BeTrue
        $data = @(Import-Csv -LiteralPath $csv | Sort-Object SourcePath)
        $data.Count | Should -Be 3
        $data[0].MovedToPath | Should -Be (Join-Path $destAlbum '01 a.opus')
        $data[0].Note | Should -BeNullOrEmpty
        foreach ($r in $data[1..2]) {
            $r.MovedToPath | Should -BeNullOrEmpty
            $r.Note | Should -Be 'Not processed (interrupted)'
        }
        Get-FileNames -Dir $destAlbum | Should -Be @('01 a.opus')
    }

    It 'writes a CSV with the expected columns and one row per file' {
        New-EmptyFile -Dir $destAlbum -Name 'a.mp3' | Out-Null
        New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name 'a.opus' | Out-Null
        New-EmptyFile -Dir (Join-Path $src 'Nobody\Nothing') -Name 'b.opus' | Out-Null

        Move-FileToMatchingTree -Source $src -DestinationHead $dest -OutputCSV $csv -Confirm:$false 6>$null | Out-Null

        $first = (Get-Content -LiteralPath $csv -TotalCount 1)
        $first | Should -Be '"SourcePath","MovedToPath","DestinationBaseFileNameMatch","Note"'
        $data = @(Import-Csv -LiteralPath $csv | Sort-Object SourcePath)
        $data.Count | Should -Be 2
        $data[0].SourcePath | Should -Be (Join-Path $src 'Artist\Album\a.opus')
        $data[0].MovedToPath | Should -Be (Join-Path $destAlbum 'a.opus')
        $data[0].DestinationBaseFileNameMatch | Should -Be 'True'
        $data[1].SourcePath | Should -Be (Join-Path $src 'Nobody\Nothing\b.opus')
        $data[1].MovedToPath | Should -Be 'Could not find destination'
        $data[1].DestinationBaseFileNameMatch | Should -Be 'False'
    }
}
