BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Find-MatchingDirectories' {

    BeforeEach {
        $script:root = New-TestDir
        $script:a = Join-Path $root 'first'
        $script:b = Join-Path $root 'second'
        New-Item -ItemType Directory -Path $a, $b -Force | Out-Null
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    Context 'exact matching' {

        It 'pairs directories with identical relative paths' {
            New-Item -ItemType Directory -Path (Join-Path $a 'Band\Album') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $b 'Band\Album') -Force | Out-Null

            $result = @(Find-MatchingDirectories -FirstDir $a -SecondDir $b -Depth 2)

            # Every sub-directory level is enumerated, so both 'Band' (depth 0)
            # and 'Band\Album' (depth 1) are matched.
            $result.Count | Should -Be 2
            $albumPair = $result | Where-Object { $_.First -eq (Join-Path $a 'Band\Album') }
            $albumPair.Second     | Should -Be (Join-Path $b 'Band\Album')
            $albumPair.MatchScore | Should -Be 1.0
            $albumPair.Depth      | Should -Be 1
        }

        It 'does not pair directories at different relative paths' {
            New-Item -ItemType Directory -Path (Join-Path $a 'Band\Studio\Album') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $b 'Band\Live\Album')   -Force | Out-Null

            $result = @(Find-MatchingDirectories -FirstDir $a -SecondDir $b -Depth 3)

            # Only the shared 'Band' prefix matches; the diverging leaf paths
            # ('Band\Studio\Album' vs 'Band\Live\Album') do not pair.
            ($result | Where-Object { (Split-Path $_.First -Leaf) -eq 'Album' }) | Should -BeNullOrEmpty
            ($result | Where-Object { (Split-Path $_.First -Leaf) -eq 'Band' }).Count | Should -Be 1
        }

        It 'is case-insensitive' {
            New-Item -ItemType Directory -Path (Join-Path $a 'BAND\album') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $b 'band\ALBUM') -Force | Out-Null

            $result = @(Find-MatchingDirectories -FirstDir $a -SecondDir $b -Depth 2)

            # 'BAND'/'band' and 'album'/'ALBUM' match despite case differences,
            # giving one pair per level (depth 0 and depth 1).
            ($result | Where-Object { (Split-Path $_.First -Leaf) -ieq 'album' }).Count | Should -Be 1
            $result.Count | Should -Be 2
        }

        It 'collects a single match as a one-element array' {
            New-Item -ItemType Directory -Path (Join-Path $a 'Solo') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $b 'Solo') -Force | Out-Null

            # @() is the normal way a caller collects the output; it must yield a
            # flat one-element array (not a scalar, not a nested array).
            $result = @(Find-MatchingDirectories -FirstDir $a -SecondDir $b -Depth 1)

            $result -is [array]     | Should -BeTrue
            $result.Count           | Should -Be 1
            $result[0] -is [array]  | Should -BeFalse
            $result[0].First        | Should -Be (Join-Path $a 'Solo')
        }

        It 'collects no matches as an empty array' {
            New-Item -ItemType Directory -Path (Join-Path $a 'OnlyLeft')  -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $b 'OnlyRight') -Force | Out-Null

            $result = @(Find-MatchingDirectories -FirstDir $a -SecondDir $b -Depth 1)

            $result -is [array] | Should -BeTrue
            $result.Count | Should -Be 0
        }

        It 'does not re-nest when the call is wrapped in @()' {
            # Regression guard: the function returns a typed [object[]], so @(...)
            # must NOT produce a 1-element array holding the real result array.
            New-Item -ItemType Directory -Path (Join-Path $a 'Band\Album') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $b 'Band\Album') -Force | Out-Null

            $wrapped = @(Find-MatchingDirectories -FirstDir $a -SecondDir $b -Depth 2)

            $wrapped.Count       | Should -Be 2
            $wrapped[0] -is [array] | Should -BeFalse
            $wrapped[0].First    | Should -Not -BeNullOrEmpty
        }
    }

    Context 'fuzzy matching' {

        It 'pairs a base name with a qualified variant via -Fuzzy' {
            New-Item -ItemType Directory -Path (Join-Path $a 'Band\Album')        -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $b 'Band\Album (live)') -Force | Out-Null

            $result = @(Find-MatchingDirectories -FirstDir $a -SecondDir $b -Depth 2 -Fuzzy -Threshold 0.5)

            $pair = $result | Where-Object { (Split-Path $_.First -Leaf) -eq 'Album' }
            $pair | Should -Not -BeNullOrEmpty
            (Split-Path $pair.Second -Leaf) | Should -Be 'Album (live)'
        }

        It 'does not pair across different parents even when leaves are similar' {
            New-Item -ItemType Directory -Path (Join-Path $a 'Band\Studio\Album') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $b 'Band\Live\Album')   -Force | Out-Null

            $result = @(Find-MatchingDirectories -FirstDir $a -SecondDir $b -Depth 3 -Fuzzy -Threshold 0.5)

            # Same leaf 'Album' but parents differ (Studio vs Live) -> no pair.
            ($result | Where-Object { $_.First -like '*Studio*' }) | Should -BeNullOrEmpty
        }

        It 'drops pairs below the threshold' {
            New-Item -ItemType Directory -Path (Join-Path $a 'Artist\Alpha')   -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $b 'Artist\Omegaxx') -Force | Out-Null

            $result = @(Find-MatchingDirectories -FirstDir $a -SecondDir $b -Depth 2 -Fuzzy -Threshold 0.9)

            ($result | Where-Object { $_.First -like '*Alpha' }) | Should -BeNullOrEmpty
        }

        It 'pairs one-to-one (greedy best match wins)' {
            # Two left leaves could both match the one right leaf; only the best
            # scoring pair is kept and each directory is used at most once.
            New-Item -ItemType Directory -Path (Join-Path $a 'P\Greatest Hits')         -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $a 'P\Greatest Hits Deluxe')  -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $b 'P\Greatest Hits')         -Force | Out-Null

            $result = @(Find-MatchingDirectories -FirstDir $a -SecondDir $b -Depth 2 -Fuzzy -Threshold 0.5)

            $leafPairs = @($result | Where-Object { (Split-Path $_.Second -Leaf) -eq 'Greatest Hits' })
            $leafPairs.Count | Should -Be 1
            # The exact-name 'Greatest Hits' should win over the longer variant.
            (Split-Path $leafPairs[0].First -Leaf) | Should -Be 'Greatest Hits'
        }
    }

    Context 'input validation' {

        It 'throws when a directory does not exist' {
            { Find-MatchingDirectories -FirstDir (Join-Path $root 'missing') -SecondDir $b } |
                Should -Throw
        }
    }
}
