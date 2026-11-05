BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools

    # Sorted full paths of every directory under (not including) $Root.
    function Get-DirTree {
        param([Parameter(Mandatory)][string]$Root)
        @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force | Select-Object -ExpandProperty FullName | Sort-Object)
    }
}

BeforeDiscovery {
    $script:canJunction = $IsWindows -or ($PSVersionTable.PSEdition -eq 'Desktop')
}

Describe 'Remove-EmptyDirectories' {

    BeforeEach {
        $script:root = New-TestDir
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    It 'is exported by the module' {
        (Get-Command -Module PwshMusicTools -Name Remove-EmptyDirectories).Name | Should -Be 'Remove-EmptyDirectories'
    }

    It 'removes a nested chain of empty directories in one run, deepest first' {
        $a = Join-Path $root 'a'
        $b = Join-Path $a 'b'
        $c = Join-Path $b 'c'
        New-Item -ItemType Directory -Path $c -Force | Out-Null

        $result = @(Remove-EmptyDirectories -Path $root -Confirm:$false 6>$null)

        Test-Path $a | Should -BeFalse
        $result | Should -Be @($c, $b, $a)
    }

    It 'keeps a parent alive when a sibling holds a file' {
        $parent = Join-Path $root 'parent'
        $keep   = Join-Path $parent 'keep'
        $drop   = Join-Path $parent 'drop'
        New-EmptyFile -Dir $keep -Name 'song.flac' | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $drop 'deeper') -Force | Out-Null

        $result = @(Remove-EmptyDirectories -Path $root -Confirm:$false 6>$null)

        Test-Path $parent | Should -BeTrue
        Test-Path $keep   | Should -BeTrue
        Test-Path $drop   | Should -BeFalse
        $result | Should -Be @((Join-Path $drop 'deeper'), $drop)
    }

    It 'never removes the -Path root, even when it ends up empty' {
        New-Item -ItemType Directory -Path (Join-Path $root 'x\y') -Force | Out-Null

        Remove-EmptyDirectories -Path $root -Confirm:$false 6>$null | Out-Null

        Test-Path $root | Should -BeTrue
        @(Get-ChildItem -LiteralPath $root -Force).Count | Should -Be 0
    }

    It 'treats a hidden file as content' {
        $dir  = Join-Path $root 'hidden-only'
        $file = New-EmptyFile -Dir $dir -Name 'desktop.ini'
        (Get-Item -LiteralPath $file -Force).Attributes = 'Hidden, System'

        $result = @(Remove-EmptyDirectories -Path $root -Confirm:$false 6>$null)

        Test-Path $dir | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It '-WhatIf deletes nothing but returns the same cascade a real run removes' {
        # a\b\c and a\d are empty, so a empties only by cascade; e holds a file.
        New-Item -ItemType Directory -Path (Join-Path $root 'a\b\c'), (Join-Path $root 'a\d') -Force | Out-Null
        New-EmptyFile -Dir (Join-Path $root 'e\f') -Name 'song.opus' | Out-Null
        $before = Get-DirTree -Root $root

        $whatIf = @(Remove-EmptyDirectories -Path $root -WhatIf 6>$null)

        Get-DirTree -Root $root | Should -Be $before
        $whatIf | Should -Contain (Join-Path $root 'a')

        $real = @(Remove-EmptyDirectories -Path $root -Confirm:$false 6>$null)

        $real.Count | Should -Be 4
        $whatIf | Should -Be $real
        Get-DirTree -Root $root | Should -Be @((Join-Path $root 'e'), (Join-Path $root 'e\f'))
    }

    It 'returns the removed paths as a flat array of full paths' {
        New-Item -ItemType Directory -Path (Join-Path $root 'one'), (Join-Path $root 'two') -Force | Out-Null

        $result = @(Remove-EmptyDirectories -Path $root -Confirm:$false 6>$null)

        $result.Count | Should -Be 2
        $result | ForEach-Object { $_ | Should -BeOfType [string] }
        ($result | Sort-Object) | Should -Be @((Join-Path $root 'one'), (Join-Path $root 'two'))
    }

    It 'returns nothing when there is nothing to remove' {
        New-EmptyFile -Dir (Join-Path $root 'full') -Name 'a.mp3' | Out-Null

        @(Remove-EmptyDirectories -Path $root -Confirm:$false 6>$null).Count | Should -Be 0
    }

    It 'accepts directories from the pipeline' {
        New-Item -ItemType Directory -Path (Join-Path $root 'p\q') -Force | Out-Null

        $result = @(Get-Item -LiteralPath (Join-Path $root 'p') | Remove-EmptyDirectories -Confirm:$false 6>$null)

        $result | Should -Be @((Join-Path $root 'p\q'))
        Test-Path (Join-Path $root 'p') | Should -BeTrue
    }

    It 'writes an error for a path that is not a directory' {
        $file = New-EmptyFile -Dir $root -Name 'f.txt'

        { Remove-EmptyDirectories -Path $file -Confirm:$false -ErrorAction Stop 6>$null } | Should -Throw '*not a valid directory*'
    }

    It 'keeps processing piped paths after a bad one' {
        $good = Join-Path $root 'good'
        New-Item -ItemType Directory -Path (Join-Path $good 'x') -Force | Out-Null
        $missing = Join-Path $root 'nope'

        $result = @($missing, $good | Remove-EmptyDirectories -Confirm:$false -ErrorAction Continue -ErrorVariable errs 2>$null 6>$null)

        $errs.Count | Should -Be 1
        "$($errs[0])" | Should -BeLike '*not a valid directory*'
        Test-Path (Join-Path $good 'x') | Should -BeFalse
        $result | Should -Be @((Join-Path $good 'x'))
    }

    It 'warns when a directory cannot be deleted and keeps its parent' -Skip:(-not $IsWindows) {
        # Windows refuses to delete a directory that is the process's current directory.
        $parent = Join-Path $root 'p'
        $locked = Join-Path $parent 'locked'
        $other  = Join-Path $parent 'other'
        New-Item -ItemType Directory -Path $locked, $other -Force | Out-Null
        $savedCwd = [System.Environment]::CurrentDirectory
        try {
            [System.Environment]::CurrentDirectory = $locked
            $result = @(Remove-EmptyDirectories -Path $root -Confirm:$false -WarningVariable warns 3>$null 6>$null)
        }
        finally {
            [System.Environment]::CurrentDirectory = $savedCwd
        }

        @($warns | Where-Object { "$_" -like "*failed to remove '$locked'*" }).Count | Should -Be 1
        Test-Path $locked | Should -BeTrue
        Test-Path $parent | Should -BeTrue
        Test-Path $other  | Should -BeFalse
        $result | Should -Be @($other)
    }

    It 'refuses a -Path that is itself a junction' -Skip:(-not $canJunction) {
        $target = New-TestDir
        $link = Join-Path $root 'rootlink'
        try {
            New-Item -ItemType Directory -Path (Join-Path $target 'inner') -Force | Out-Null
            New-Item -ItemType Junction -Path $link -Target $target | Out-Null

            $result = @(Remove-EmptyDirectories -Path $link -Confirm:$false -ErrorAction Continue -ErrorVariable errs 2>$null 6>$null)

            $result.Count | Should -Be 0
            $errs.Count | Should -Be 1
            "$($errs[0])" | Should -BeLike '*Junction*refusing*'
            Test-Path (Join-Path $target 'inner') | Should -BeTrue
        }
        finally {
            if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) }
            Remove-TestDir -Path $target
        }
    }

    It 'does not follow or remove a junction, and keeps its parent' -Skip:(-not $canJunction) {
        $target = New-TestDir
        try {
            $holder = Join-Path $root 'holder'
            New-Item -ItemType Directory -Path $holder -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $target 'inner') -Force | Out-Null
            $link = Join-Path $holder 'link'
            New-Item -ItemType Junction -Path $link -Target $target | Out-Null

            $result = @(Remove-EmptyDirectories -Path $root -Confirm:$false 6>$null)

            $result.Count | Should -Be 0
            Test-Path $link | Should -BeTrue
            Test-Path (Join-Path $target 'inner') | Should -BeTrue
        }
        finally {
            if (Test-Path -LiteralPath (Join-Path $root 'holder\link')) {
                [System.IO.Directory]::Delete((Join-Path $root 'holder\link'))
            }
            Remove-TestDir -Path $target
        }
    }
}
