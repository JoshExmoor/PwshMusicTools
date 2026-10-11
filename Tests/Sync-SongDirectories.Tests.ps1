BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Sync-SongDirectories' {

    BeforeEach {
        $script:root = New-TestDir
        $script:ren  = Join-Path $root 'rename'
        $script:ref  = Join-Path $root 'reference'
        New-Item -ItemType Directory -Path $ren, $ref -Force | Out-Null
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    It 'syncs album sub-folders present in both parents' {
        # Album A exists in both parents and should be synced.
        New-EmptyFile -Dir (Join-Path $ref 'Album A') -Name '01 Song One.flac' | Out-Null
        New-EmptyFile -Dir (Join-Path $ren 'Album A') -Name '1 song one.flac'  | Out-Null

        Sync-SongDirectories -RenameDir $ren -ReferenceDir $ref -Confirm:$false

        Get-FileNames -Dir (Join-Path $ren 'Album A') | Should -Be @('01 Song One.flac')
    }

    It 'ignores folders that exist in only one parent' {
        New-EmptyFile -Dir (Join-Path $ref 'Shared') -Name '01 Keep.flac'  | Out-Null
        New-EmptyFile -Dir (Join-Path $ren 'Shared') -Name '1 keep.flac'   | Out-Null
        # 'RenameOnly' has no counterpart under the reference parent.
        New-EmptyFile -Dir (Join-Path $ren 'RenameOnly') -Name '1 untouched.flac' | Out-Null

        Sync-SongDirectories -RenameDir $ren -ReferenceDir $ref -Confirm:$false

        Get-FileNames -Dir (Join-Path $ren 'Shared')     | Should -Be @('01 Keep.flac')
        Get-FileNames -Dir (Join-Path $ren 'RenameOnly') | Should -Be @('1 untouched.flac')
    }

    It 'forwards -WhatIf so nothing is renamed' {
        New-EmptyFile -Dir (Join-Path $ref 'Album A') -Name '01 Song One.flac' | Out-Null
        New-EmptyFile -Dir (Join-Path $ren 'Album A') -Name '1 song one.flac'  | Out-Null

        Sync-SongDirectories -RenameDir $ren -ReferenceDir $ref -WhatIf

        Get-FileNames -Dir (Join-Path $ren 'Album A') | Should -Be @('1 song one.flac')
    }

    It 'does nothing when no folders are shared' {
        New-EmptyFile -Dir (Join-Path $ren 'Only Here') -Name '1 song.flac' | Out-Null

        Sync-SongDirectories -RenameDir $ren -ReferenceDir $ref -Confirm:$false

        Get-FileNames -Dir (Join-Path $ren 'Only Here') | Should -Be @('1 song.flac')
    }
}
