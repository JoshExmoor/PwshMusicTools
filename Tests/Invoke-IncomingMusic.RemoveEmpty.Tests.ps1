BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Invoke-IncomingMusic -RemoveEmptyDirectories' {

    BeforeEach {
        $script:root = New-TestDir
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    It 'removes a directory that contains no files' {
        $empty = Join-Path $root 'empty'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null

        Invoke-IncomingMusic -Path $root -RemoveEmptyDirectories -Confirm:$false 6>$null | Out-Null

        Test-Path $empty | Should -BeFalse
    }

    It 'keeps a directory that contains a file' {
        $full = Join-Path $root 'has-file'
        New-EmptyFile -Dir $full -Name 'song.flac' | Out-Null

        Invoke-IncomingMusic -Path $root -RemoveEmptyDirectories -Confirm:$false 6>$null | Out-Null

        Test-Path $full | Should -BeTrue
    }

    It 'removes a parent whose only contents are empty subdirectories (nested)' {
        # parent\child\grandchild, all empty -> the whole chain should go.
        $parent     = Join-Path $root 'parent'
        $child       = Join-Path $parent 'child'
        $grandchild = Join-Path $child 'grandchild'
        New-Item -ItemType Directory -Path $grandchild -Force | Out-Null

        Invoke-IncomingMusic -Path $root -RemoveEmptyDirectories -Confirm:$false 6>$null | Out-Null

        Test-Path $grandchild | Should -BeFalse
        Test-Path $child      | Should -BeFalse
        Test-Path $parent     | Should -BeFalse
    }

    It 'keeps a parent whose only file lives in a subdirectory' {
        # parent is "empty" of direct files, but its subtree has a file, so keep both.
        $parent = Join-Path $root 'parent'
        $child  = Join-Path $parent 'child'
        New-EmptyFile -Dir $child -Name 'deep.flac' | Out-Null

        Invoke-IncomingMusic -Path $root -RemoveEmptyDirectories -Confirm:$false 6>$null | Out-Null

        Test-Path $parent | Should -BeTrue
        Test-Path $child  | Should -BeTrue
    }

    It 'removes only the empty siblings, keeping the non-empty one' {
        $keep  = Join-Path $root 'keep'
        $drop1 = Join-Path $root 'drop1'
        $drop2 = Join-Path $root 'drop2'
        New-EmptyFile -Dir $keep -Name 'a.flac' | Out-Null
        New-Item -ItemType Directory -Path $drop1, $drop2 -Force | Out-Null

        Invoke-IncomingMusic -Path $root -RemoveEmptyDirectories -Confirm:$false 6>$null | Out-Null

        Test-Path $keep  | Should -BeTrue
        Test-Path $drop1 | Should -BeFalse
        Test-Path $drop2 | Should -BeFalse
    }

    It 'never removes the base path itself' {
        # Base path is empty of files; it must survive regardless.
        Invoke-IncomingMusic -Path $root -RemoveEmptyDirectories -Confirm:$false 6>$null | Out-Null

        Test-Path $root | Should -BeTrue
    }

    It 'does not remove anything under -WhatIf' {
        $empty = Join-Path $root 'empty'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null

        Invoke-IncomingMusic -Path $root -RemoveEmptyDirectories -WhatIf 6>$null | Out-Null

        Test-Path $empty | Should -BeTrue
    }

    It 'returns a result object per removed directory' {
        $empty = Join-Path $root 'empty'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null

        $results = @(Invoke-IncomingMusic -Path $root -RemoveEmptyDirectories -Confirm:$false 6>$null |
                     Where-Object { $_.Step -eq 'RemoveEmptyDirectories' })

        ($results | Where-Object { $_.Directory -eq $empty }).Removed | Should -BeTrue
    }
}
