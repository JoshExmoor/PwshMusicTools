BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Move-FileWithTree' {

    BeforeEach {
        $script:root = New-TestDir
        $script:base = Join-Path $root 'base'
        $script:dest = Join-Path $root 'newbase'
        $script:album = Join-Path $base 'genre\artist\album'
        New-Item -ItemType Directory -Path $base -Force | Out-Null
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    It 'is exported by the module' {
        (Get-Command Move-FileWithTree -Module PwshMusicTools).Name | Should -Be 'Move-FileWithTree'
    }

    It 'prompts by default (ConfirmImpact High) and limits -Depth to 1..10' {
        $cmd = Get-Command Move-FileWithTree
        $cmd.ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            ForEach-Object { $_.ConfirmImpact } | Should -Be 'High'
        $cmd.Parameters['Depth'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] } |
            ForEach-Object { $_.MinRange, $_.MaxRange } | Should -Be @(1, 10)
        $file = New-EmptyFile -Dir $album -Name 'song.mp3'
        { Move-FileWithTree -Source $file -DestinationHead $dest -Depth 11 -Confirm:$false } | Should -Throw
    }

    It 'moves base\genre\artist\album\song.mp3 to newbase\genre\artist\album\song.mp3 at depth 3' {
        $file = New-EmptyFile -Dir $album -Name 'song.mp3'

        $rows = @(Move-FileWithTree -Source $file -DestinationHead $dest -Depth 3 -Confirm:$false 6>$null)

        $expected = Join-Path $dest 'genre\artist\album\song.mp3'
        $rows.Count | Should -Be 1
        $rows[0].DestinationPath | Should -Be $expected
        $rows[0].Moved | Should -BeTrue
        Test-Path -LiteralPath $expected | Should -BeTrue
        Test-Path -LiteralPath $file | Should -BeFalse
    }

    It 'keeps only the album folder at depth 1' {
        $file = New-EmptyFile -Dir $album -Name 'song.mp3'

        $rows = @(Move-FileWithTree -Source $file -DestinationHead $dest -Depth 1 -Confirm:$false 6>$null)

        $expected = Join-Path $dest 'album\song.mp3'
        $rows[0].DestinationPath | Should -Be $expected
        Test-Path -LiteralPath $expected | Should -BeTrue
        @(Get-ChildItem -LiteralPath $dest -Directory).Name | Should -Be @('album')
    }

    It 'keeps artist\album at depth 2' {
        $file = New-EmptyFile -Dir $album -Name 'song.mp3'

        $rows = @(Move-FileWithTree -Source $file -DestinationHead $dest -Depth 2 -Confirm:$false 6>$null)

        $expected = Join-Path $dest 'artist\album\song.mp3'
        $rows[0].DestinationPath | Should -Be $expected
        Test-Path -LiteralPath $expected | Should -BeTrue
        @(Get-ChildItem -LiteralPath $dest -Directory).Name | Should -Be @('artist')
    }

    It 'creates the destination head and missing folders' {
        Test-Path -LiteralPath $dest | Should -BeFalse
        $file = New-EmptyFile -Dir $album -Name 'song.mp3'

        Move-FileWithTree -Source $file -DestinationHead $dest -Depth 3 -Confirm:$false 6>$null | Out-Null

        Test-Path -LiteralPath (Join-Path $dest 'genre\artist\album') -PathType Container | Should -BeTrue
    }

    It 'moves into folders that already exist alongside existing files' {
        $destAlbum = Join-Path $dest 'artist\album'
        New-EmptyFile -Dir $destAlbum -Name 'other.mp3' | Out-Null
        New-EmptyFile -Dir $album -Name 'song.mp3' | Out-Null

        Move-FileWithTree -Source $base -DestinationHead $dest -Depth 2 -Confirm:$false 6>$null | Out-Null

        Get-FileNames -Dir $destAlbum | Should -Be @('other.mp3', 'song.mp3')
    }

    It 'recurses into a directory source, each file keeping its own tail, any extension' {
        New-EmptyFile -Dir $album -Name '01 a.mp3' | Out-Null
        New-EmptyFile -Dir $album -Name 'cover.jpg' | Out-Null
        New-EmptyFile -Dir (Join-Path $base 'jazz\someone\record') -Name '01 b.flac' | Out-Null
        New-EmptyFile -Dir (Join-Path $base 'loose\single') -Name 'c.opus' | Out-Null

        $rows = @(Move-FileWithTree -Source $base -DestinationHead $dest -Depth 2 -Confirm:$false 6>$null)

        $rows.Count | Should -Be 4
        @($rows | Where-Object Moved).Count | Should -Be 4
        Get-FileNames -Dir (Join-Path $dest 'artist\album')   | Should -Be @('01 a.mp3', 'cover.jpg')
        Get-FileNames -Dir (Join-Path $dest 'someone\record') | Should -Be @('01 b.flac')
        Get-FileNames -Dir (Join-Path $dest 'loose\single')   | Should -Be @('c.opus')
    }

    It 'skips a file with fewer than -Depth parent folders below the root' {
        $file = New-EmptyFile -Dir $root -Name 'shallow.mp3'
        $dirName = Split-Path -Parent $file
        $parentCount = @($dirName.Substring([IO.Path]::GetPathRoot($dirName).Length) -split '[\\/]' | Where-Object { $_ }).Count
        $tooDeep = $parentCount + 1
        $tooDeep | Should -BeLessOrEqual 10 -Because 'the temp folder must be shallow enough for this test'

        $rows = @(Move-FileWithTree -Source $file -DestinationHead $dest -Depth $tooDeep -Confirm:$false -WarningVariable warn -WarningAction SilentlyContinue 6>$null)

        $rows[0].Moved | Should -BeFalse
        $rows[0].DestinationPath | Should -BeNullOrEmpty
        $rows[0].Note | Should -Be "Source path has fewer than $tooDeep parent folder(s)"
        @($warn).Count | Should -Be 1
        Test-Path -LiteralPath $file | Should -BeTrue
        Test-Path -LiteralPath $dest | Should -BeFalse
    }

    It 'does not overwrite an existing destination file' {
        $existing = New-EmptyFile -Dir (Join-Path $dest 'artist\album') -Name 'song.mp3'
        Set-Content -LiteralPath $existing -Value 'original'
        $file = New-EmptyFile -Dir $album -Name 'song.mp3'

        $rows = @(Move-FileWithTree -Source $file -DestinationHead $dest -Depth 2 -Confirm:$false -WarningVariable warn -WarningAction SilentlyContinue 6>$null)

        $rows[0].Moved | Should -BeFalse
        $rows[0].DestinationPath | Should -Be $existing
        $rows[0].Note | Should -Be "Destination file already exists: '$existing'"
        @($warn).Count | Should -Be 1
        Test-Path -LiteralPath $file | Should -BeTrue
        Get-Content -LiteralPath $existing | Should -Be 'original'
    }

    It 'skips a second source file that targets the same destination' {
        $first  = New-EmptyFile -Dir (Join-Path $base 'a\album') -Name 'song.mp3'
        $second = New-EmptyFile -Dir (Join-Path $base 'b\album') -Name 'song.mp3'

        $rows = @(Move-FileWithTree -Source $base -DestinationHead $dest -Depth 1 -Confirm:$false -WarningAction SilentlyContinue 6>$null)

        $rows[0].Moved | Should -BeTrue
        $rows[1].Moved | Should -BeFalse
        $rows[1].Note | Should -BeLike 'Another source file in this batch already targets*'
        Test-Path -LiteralPath $first | Should -BeFalse
        Test-Path -LiteralPath $second | Should -BeTrue
    }

    It 'moves nothing and creates no folders under -WhatIf but returns the planned paths' {
        $file1 = New-EmptyFile -Dir $album -Name 'song.mp3'
        $file2 = New-EmptyFile -Dir (Join-Path $base 'jazz\someone\record') -Name 'tune.flac'

        $rows = @(Move-FileWithTree -Source $base -DestinationHead $dest -Depth 3 -WhatIf 6>$null)

        Test-Path -LiteralPath $dest | Should -BeFalse
        Test-Path -LiteralPath $file1 | Should -BeTrue
        Test-Path -LiteralPath $file2 | Should -BeTrue
        $rows.Count | Should -Be 2
        $planned1 = Join-Path $dest 'genre\artist\album\song.mp3'
        $planned2 = Join-Path $dest 'jazz\someone\record\tune.flac'
        $rows[0].DestinationPath | Should -Be $planned1
        $rows[1].DestinationPath | Should -Be $planned2
        $rows | ForEach-Object { $_.Moved | Should -BeFalse }
        $rows[0].Note | Should -Be "WhatIf: would move to '$planned1'"
    }

    It 'returns one object per file with SourcePath, DestinationPath, Moved and Note' {
        $file = New-EmptyFile -Dir $album -Name 'song.mp3'

        $result = Move-FileWithTree -Source $file -DestinationHead $dest -Depth 3 -Confirm:$false 6>$null

        @($result).Count | Should -Be 1
        @($result)[0] | Should -BeOfType [pscustomobject]
        $result.PSObject.Properties.Name | Should -Be @('SourcePath', 'DestinationPath', 'Moved', 'Note')
        $result.SourcePath | Should -Be $file
        $result.Moved | Should -BeOfType [bool]
        $result.Note | Should -BeNullOrEmpty
    }

    It 'accepts pipeline input and confirms once for the batch' {
        Mock -ModuleName PwshMusicTools Move-Item { }
        New-EmptyFile -Dir $album -Name 'a.mp3' | Out-Null
        New-EmptyFile -Dir $album -Name 'b.mp3' | Out-Null

        $rows = @(Get-ChildItem -LiteralPath $album -File | Move-FileWithTree -DestinationHead $dest -Depth 1 -Confirm:$false 6>$null)

        $rows.Count | Should -Be 2
        Should -Invoke Move-Item -ModuleName PwshMusicTools -Times 2 -Exactly -ParameterFilter {
            $PesterBoundParameters.ContainsKey('Confirm') -and -not $PesterBoundParameters['Confirm'] -and
            $PesterBoundParameters.ContainsKey('WhatIf') -and -not $PesterBoundParameters['WhatIf']
        }
    }

    Context '-BaseDir' {

        It 'moves base\genre\artist\album\song.mp3 to newbase\genre\artist\album\song.mp3' {
            $file = New-EmptyFile -Dir $album -Name 'song.mp3'

            $rows = @(Move-FileWithTree -Source $file -DestinationHead $dest -BaseDir $base -Confirm:$false 6>$null)

            $expected = Join-Path $dest 'genre\artist\album\song.mp3'
            $rows.Count | Should -Be 1
            $rows[0].DestinationPath | Should -Be $expected
            $rows[0].Moved | Should -BeTrue
            Test-Path -LiteralPath $expected | Should -BeTrue
            Test-Path -LiteralPath $file | Should -BeFalse
        }

        It 'keeps each file''s own relative path when depths differ in one run' {
            New-EmptyFile -Dir $album -Name 'song.mp3' | Out-Null
            New-EmptyFile -Dir (Join-Path $base 'artist2\album2') -Name 'other.mp3' | Out-Null

            # Upper-case base with a trailing separator: matching is case-insensitive
            # and the separator is normalised.
            $rows = @(Move-FileWithTree -Source $base -DestinationHead $dest -BaseDir ($base.ToUpperInvariant() + '\') -Confirm:$false 6>$null)

            $rows.Count | Should -Be 2
            @($rows | Where-Object Moved).Count | Should -Be 2
            Get-FileNames -Dir (Join-Path $dest 'genre\artist\album') | Should -Be @('song.mp3')
            Get-FileNames -Dir (Join-Path $dest 'artist2\album2')     | Should -Be @('other.mp3')
        }

        It 'moves a file directly in -BaseDir directly into -DestinationHead' {
            $file = New-EmptyFile -Dir $base -Name 'loose.mp3'

            $rows = @(Move-FileWithTree -Source $file -DestinationHead $dest -BaseDir $base -Confirm:$false 6>$null)

            $expected = Join-Path $dest 'loose.mp3'
            $rows[0].DestinationPath | Should -Be $expected
            $rows[0].Moved | Should -BeTrue
            Test-Path -LiteralPath $expected | Should -BeTrue
        }

        It 'skips a file outside -BaseDir with a warning' {
            $file = New-EmptyFile -Dir (Join-Path $root 'elsewhere\album') -Name 'song.mp3'

            $rows = @(Move-FileWithTree -Source $file -DestinationHead $dest -BaseDir $base -Confirm:$false -WarningVariable warn -WarningAction SilentlyContinue 6>$null)

            $rows[0].Moved | Should -BeFalse
            $rows[0].DestinationPath | Should -BeNullOrEmpty
            $rows[0].Note | Should -BeLike 'Source is not under base directory*'
            @($warn).Count | Should -Be 1
            Test-Path -LiteralPath $file | Should -BeTrue
            Test-Path -LiteralPath $dest | Should -BeFalse
        }

        It 'does not treat base as a prefix of baseline' {
            $file = New-EmptyFile -Dir (Join-Path $root 'baseline\album') -Name 'x.mp3'

            $rows = @(Move-FileWithTree -Source $file -DestinationHead $dest -BaseDir $base -Confirm:$false -WarningAction SilentlyContinue 6>$null)

            $rows[0].Moved | Should -BeFalse
            $rows[0].Note | Should -BeLike 'Source is not under base directory*'
            Test-Path -LiteralPath $file | Should -BeTrue
            Test-Path -LiteralPath $dest | Should -BeFalse
        }

        It 'rejects -Depth together with -BaseDir' {
            $file = New-EmptyFile -Dir $album -Name 'song.mp3'

            { Move-FileWithTree -Source $file -DestinationHead $dest -Depth 2 -BaseDir $base -Confirm:$false } |
                Should -Throw -ErrorId 'AmbiguousParameterSet,Move-FileWithTree'
            Test-Path -LiteralPath $file | Should -BeTrue
        }

        It 'requires -BaseDir to be an existing directory' {
            $file = New-EmptyFile -Dir $album -Name 'song.mp3'

            { Move-FileWithTree -Source $file -DestinationHead $dest -BaseDir (Join-Path $root 'missing') -Confirm:$false } |
                Should -Throw '*is not an existing directory*'
            Test-Path -LiteralPath $file | Should -BeTrue
        }

        It 'moves nothing and creates no folders under -WhatIf' {
            $file1 = New-EmptyFile -Dir $album -Name 'song.mp3'
            $file2 = New-EmptyFile -Dir (Join-Path $base 'artist2\album2') -Name 'other.mp3'

            $rows = @(Move-FileWithTree -Source $base -DestinationHead $dest -BaseDir $base -WhatIf 6>$null)

            Test-Path -LiteralPath $dest | Should -BeFalse
            Test-Path -LiteralPath $file1 | Should -BeTrue
            Test-Path -LiteralPath $file2 | Should -BeTrue
            $rows.Count | Should -Be 2
            $rows | ForEach-Object { $_.Moved | Should -BeFalse; $_.Note | Should -BeLike 'WhatIf: would move to*' }
            $rows.DestinationPath | Sort-Object | Should -Be @(
                (Join-Path $dest 'artist2\album2\other.mp3'),
                (Join-Path $dest 'genre\artist\album\song.mp3'))
        }
    }

    It 'leaves emptied source folders in place' {
        New-EmptyFile -Dir $album -Name 'song.mp3' | Out-Null

        Move-FileWithTree -Source $base -DestinationHead $dest -Depth 3 -Confirm:$false 6>$null | Out-Null

        Test-Path -LiteralPath $album -PathType Container | Should -BeTrue
    }
}
