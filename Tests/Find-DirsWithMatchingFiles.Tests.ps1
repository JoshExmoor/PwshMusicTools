BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Find-DirsWithMatchingFiles' {

    BeforeEach {
        $script:root = New-TestDir
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    It 'returns a directory that meets the default count of 2' {
        $d = Join-Path $root 'album'
        New-EmptyFile -Dir $d -Name '01 a.mp3' | Out-Null
        New-EmptyFile -Dir $d -Name '02 b.mp3' | Out-Null

        $result = Find-DirsWithMatchingFiles -Filter '*.mp3' -Path $root

        $result.Directory | Should -Be $d
        $result.Count     | Should -Be 2
    }

    It 'excludes a directory below the count threshold' {
        $d = Join-Path $root 'single'
        New-EmptyFile -Dir $d -Name '01 only.mp3' | Out-Null

        $result = Find-DirsWithMatchingFiles -Filter '*.mp3' -Path $root

        $result | Should -BeNullOrEmpty
    }

    It 'honors a higher -Count' {
        $d = Join-Path $root 'album'
        1..4 | ForEach-Object { New-EmptyFile -Dir $d -Name ("{0:00} track.mp3" -f $_) | Out-Null }

        (Find-DirsWithMatchingFiles -Filter '*.mp3' -Path $root -Count 5) | Should -BeNullOrEmpty
        (Find-DirsWithMatchingFiles -Filter '*.mp3' -Path $root -Count 4).Count | Should -Be 4
    }

    It 'applies the wildcard filter to file names' {
        $d = Join-Path $root 'mixed'
        New-EmptyFile -Dir $d -Name '01 keep.mp3' | Out-Null
        New-EmptyFile -Dir $d -Name '02 keep.mp3' | Out-Null
        New-EmptyFile -Dir $d -Name 'cover.jpg'   | Out-Null
        New-EmptyFile -Dir $d -Name 'notes.txt'   | Out-Null

        (Find-DirsWithMatchingFiles -Filter '*.mp3' -Path $root).Count | Should -Be 2
    }

    It 'counts only a directory''s own files, not its subdirectories' {
        # Parent has 1 matching file directly; its child has 2. The parent must
        # NOT be counted as having 3 - each directory is evaluated on its own files.
        $parent = Join-Path $root 'parent'
        $child  = Join-Path $parent 'child'
        New-EmptyFile -Dir $parent -Name '01 parent.mp3' | Out-Null
        New-EmptyFile -Dir $child  -Name '01 child.mp3'  | Out-Null
        New-EmptyFile -Dir $child  -Name '02 child.mp3'  | Out-Null

        $result = @(Find-DirsWithMatchingFiles -Filter '*.mp3' -Path $root)

        # Only the child qualifies (2 files); the parent (1 file) does not.
        $result.Count | Should -Be 1
        $result[0].Directory | Should -Be $child
    }

    It 'finds matching directories recursively under the root' {
        $a = Join-Path $root 'artist1\album1'
        $b = Join-Path $root 'artist2\album2'
        New-EmptyFile -Dir $a -Name '01 x.flac' | Out-Null
        New-EmptyFile -Dir $a -Name '02 y.flac' | Out-Null
        New-EmptyFile -Dir $b -Name '01 p.flac' | Out-Null
        New-EmptyFile -Dir $b -Name '02 q.flac' | Out-Null

        $dirs = @(Find-DirsWithMatchingFiles -Filter '*.flac' -Path $root | Select-Object -ExpandProperty Directory)

        $dirs | Should -Contain $a
        $dirs | Should -Contain $b
    }
}
