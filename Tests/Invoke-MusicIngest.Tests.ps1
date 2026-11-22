BeforeDiscovery {
    # Junction support is needed for the "not followed" cases.
    $script:canJunction = $false
    try {
        $base = Join-Path ([System.IO.Path]::GetTempPath()) ('pmt-junc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $base 'real') -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $base 'link') -Target (Join-Path $base 'real') -ErrorAction Stop | Out-Null
        $script:canJunction = $true
    } catch { $script:canJunction = $false }
    finally {
        if (Test-Path -LiteralPath (Join-Path $base 'link')) { (Get-Item -LiteralPath (Join-Path $base 'link')).Delete() }
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools

    function New-Music {
        param([string]$Dir)
        New-EmptyFile -Dir $Dir -Name '01 Song.mp3' | Out-Null
    }

    function Invoke-Ingest {
        # Runs the command quietly; returns rows only. Warnings go to $script:warn.
        param(
            [string]$SourceDirectory, [string]$TargetDirectory, [string]$DestinationDirectory,
            [switch]$Fuzzy, [double]$Threshold = -1, [switch]$WhatIf, $Confirm
        )
        $p = @{ SourceDirectory = $SourceDirectory }
        $p.TargetDirectory = if ($DestinationDirectory) { $DestinationDirectory } else { $TargetDirectory }
        if ($Fuzzy) { $p.Fuzzy = $true }
        if ($Threshold -ge 0) { $p.Threshold = $Threshold }
        if ($WhatIf) { $p.WhatIf = $true }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $p.Confirm = [bool]$Confirm }
        $out = Invoke-MusicIngest @p -WarningVariable w -WarningAction SilentlyContinue 6>$null
        $script:warn = @($w)
        return , @($out)
    }
}

Describe 'Invoke-MusicIngest' {
    BeforeEach {
        $script:root = New-TestDir
        $script:src = Join-Path $script:root 'src'
        $script:tgt = Join-Path $script:root 'tgt'
        New-Item -ItemType Directory -Path $script:src, $script:tgt | Out-Null
        Mock -ModuleName PwshMusicTools Sync-SongFiles { }
    }
    AfterEach { Remove-TestDir -Path $script:root }

    Context 'Command shape' {
        It 'is exported' {
            Get-Command -Module PwshMusicTools -Name Invoke-MusicIngest | Should -Not -BeNullOrEmpty
            (Get-Module PwshMusicTools).ExportedFunctions.Keys | Should -Contain 'Invoke-MusicIngest'
        }

        It 'has exactly the expected parameters' {
            $common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
            $names = @((Get-Command Invoke-MusicIngest).Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object)
            $names | Should -Be @('Fuzzy', 'SourceDirectory', 'TargetDirectory', 'Threshold')
        }

        It 'accepts DestinationDirectory as an alias' {
            New-Music (Join-Path $src 'Artist\Album')
            $out = Invoke-Ingest -SourceDirectory $src -DestinationDirectory $tgt
            $out[0].Count | Should -Be 1
        }

        It 'rejects a Threshold outside 0 to 1' {
            { Invoke-MusicIngest -SourceDirectory $src -TargetDirectory $tgt -Threshold 1.5 } | Should -Throw
        }

        It 'writes an error for a missing directory' {
            { Invoke-MusicIngest -SourceDirectory (Join-Path $root 'nope') -TargetDirectory $tgt -ErrorAction Stop } | Should -Throw
            { Invoke-MusicIngest -SourceDirectory $src -TargetDirectory (Join-Path $root 'nope') -ErrorAction Stop } | Should -Throw
        }

        It 'declares an object array and returns exactly the nine result properties' {
            New-Music (Join-Path $src 'Artist\Album')
            $out = Invoke-MusicIngest -SourceDirectory $src -TargetDirectory $tgt 6>$null -WarningAction SilentlyContinue
            (Get-Command Invoke-MusicIngest).OutputType.Type | Should -Be ([object[]])
            @($out).Count | Should -Be 1
            @($out)[0].PSObject.Properties.Name | Should -Be @('SourceFolder', 'CurrentSourceFolder', 'Depth', 'MatchType', 'TargetFolder', 'Score', 'Renamed', 'SyncResult', 'Note')
        }

        It 'keeps Step 3 an empty region and has no Step 4 code' {
            $text = (Get-Command Invoke-MusicIngest).ScriptBlock.ToString()
            $m = [regex]::Match($text, '#region Step 3(.*?)#endregion', 'Singleline')
            $m.Success | Should -BeTrue
            $body = $m.Groups[1].Value -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            @($body | Where-Object { $_ -notlike '#*' }).Count | Should -Be 0
            $text | Should -Not -Match '(?i)\$holder'
            $text | Should -Not -Match '(?i)\$transcode'
        }
    }

    Context 'Depth' {
        It 'uses 2 for Artist\Album' {
            New-Music (Join-Path $src 'Artist\Album')
            (Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt)[0].Depth | Should -Be 2
        }

        It 'uses 1 for a single folder' {
            New-Music (Join-Path $src 'VA - Some Album')
            (Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt)[0].Depth | Should -Be 1
        }

        It 'uses 3 for Artist\Album\CD1' {
            New-Music (Join-Path $src 'Artist\Album\CD1')
            (Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt)[0].Depth | Should -Be 3
        }

        It 'uses the last 3 segments of a 4-level source' {
            New-Music (Join-Path $src 'Genre\Artist\Album\CD1')
            New-Music (Join-Path $tgt 'Artist\Album\CD1')
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt
            $out[0].Depth | Should -Be 3
            $out[0].MatchType | Should -Be 'Exact'
            $out[0].TargetFolder | Should -Be (Join-Path $tgt 'Artist\Album\CD1')
            Test-Path -LiteralPath (Join-Path $src 'Genre\Artist\Album\CD1') | Should -BeTrue
        }
    }

    Context 'Exact matching' {
        It 'matches into a target with an extra Genre level' {
            New-Music (Join-Path $src 'Artist\Album')
            New-Music (Join-Path $tgt 'Rock\Artist\Album')
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt
            $out[0].MatchType | Should -Be 'Exact'
            $out[0].TargetFolder | Should -Be (Join-Path $tgt 'Rock\Artist\Album')
            $script:s = Join-Path $src 'Artist\Album'
            $script:t = Join-Path $tgt 'Rock\Artist\Album'
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 1 -Exactly -ParameterFilter {
                $RenameDir -eq $script:s -and $ReferenceDir -eq $script:t
            }
        }

        It 'renames case-only differences to the target casing without prompting' {
            New-Music (Join-Path $src 'artist\album')
            New-Music (Join-Path $tgt 'Rock\Artist\Album')
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $true }
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt

            Should -Invoke Confirm-ShouldProcess -ModuleName PwshMusicTools -Times 0 -Exactly
            @(Get-ChildItem -LiteralPath $src -Directory).Name | Should -BeExactly 'Artist'
            @(Get-ChildItem -LiteralPath (Join-Path $src 'Artist') -Directory).Name | Should -BeExactly 'Album'
            $out[0].MatchType | Should -Be 'Exact'
            $out[0].Renamed | Should -BeTrue
            $out[0].SourceFolder | Should -Be (Join-Path $src 'artist\album')
            $out[0].CurrentSourceFolder | Should -Be (Join-Path $src 'Artist\Album')
            $script:s = Join-Path $src 'Artist\Album'
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 1 -Exactly -ParameterFilter { $RenameDir -eq $script:s }
        }

        It 'reports None and leaves the folder alone when nothing matches' {
            New-Music (Join-Path $src 'Artist\Album')
            New-Music (Join-Path $tgt 'Other\Thing')
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt
            $out[0].MatchType | Should -Be 'None'
            $out[0].Renamed | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $src 'Artist\Album') | Should -BeTrue
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 0 -Exactly
        }

        It 'skips an ambiguous exact match with a warning' {
            New-Music (Join-Path $src 'Artist\Album')
            New-Music (Join-Path $tgt 'G1\Artist\Album')
            New-Music (Join-Path $tgt 'G2\Artist\Album')
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt
            $out[0].MatchType | Should -Be 'Ambiguous'
            $out[0].TargetFolder | Should -BeNullOrEmpty
            $script:warn.Count | Should -BeGreaterThan 0
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 0 -Exactly
        }
    }

    Context 'Fuzzy matching' {
        It 'does not fuzzy match without -Fuzzy' {
            New-Music (Join-Path $src 'Radiohed\OK Computer')
            New-Music (Join-Path $tgt 'Radiohead\OK Computer')
            (Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt)[0].MatchType | Should -Be 'None'
        }

        It 'prompts once, renames each differing segment and syncs the new path' {
            New-Music (Join-Path $src 'Radiohed\OK Computers')
            New-Music (Join-Path $tgt 'Rock\Radiohead\OK Computer')
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $true }
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy

            Should -Invoke Confirm-ShouldProcess -ModuleName PwshMusicTools -Times 1 -Exactly
            $out[0].MatchType | Should -Be 'Fuzzy'
            $expected = InModuleScope PwshMusicTools { [Math]::Round([Math]::Min((Get-NameSimilarity 'Radiohed' 'Radiohead'), (Get-NameSimilarity 'OK Computers' 'OK Computer')), 2) }
            $out[0].Score | Should -Be $expected
            $out[0].Renamed | Should -BeTrue
            @(Get-ChildItem -LiteralPath $src -Directory).Name | Should -BeExactly 'Radiohead'
            @(Get-ChildItem -LiteralPath (Join-Path $src 'Radiohead') -Directory).Name | Should -BeExactly 'OK Computer'
            $script:s = Join-Path $src 'Radiohead\OK Computer'
            $script:t = Join-Path $tgt 'Rock\Radiohead\OK Computer'
            $out[0].CurrentSourceFolder | Should -Be $script:s
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 1 -Exactly -ParameterFilter {
                $RenameDir -eq $script:s -and $ReferenceDir -eq $script:t
            }
        }

        It 'accepts without prompting under -Confirm:$false' {
            New-Music (Join-Path $src 'Radiohed\OK Computer')
            New-Music (Join-Path $tgt 'Radiohead\OK Computer')
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy -Confirm:$false
            $out[0].Renamed | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $src 'Radiohead\OK Computer') | Should -BeTrue
        }

        It 'does not match below the threshold' {
            New-Music (Join-Path $src 'Radiohed\OK Computer')
            New-Music (Join-Path $tgt 'Radiohead\OK Computer')
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $true }
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy -Threshold 0.95
            $out[0].MatchType | Should -Be 'None'
            Should -Invoke Confirm-ShouldProcess -ModuleName PwshMusicTools -Times 0 -Exactly
        }

        It 'changes result with a custom threshold' {
            New-Music (Join-Path $src 'Radiohed\OK Computer')
            New-Music (Join-Path $tgt 'Radiohead\OK Computer')
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $false }
            (Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy -Threshold 0.7)[0].MatchType | Should -Be 'Fuzzy'
            (Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy -Threshold 0.99)[0].MatchType | Should -Be 'None'
        }

        It 'requires every segment to be similar' {
            New-Music (Join-Path $src 'Radiohead\Kid A')
            New-Music (Join-Path $tgt 'Radiohead\OK Computer')
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $true }
            # Averaging would give 0.5 or more; the minimum is far below 0.4.
            (Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy -Threshold 0.4)[0].MatchType | Should -Be 'None'
        }

        It 'leaves a declined folder unrenamed and does not sync it' {
            New-Music (Join-Path $src 'Radiohed\OK Computer')
            New-Music (Join-Path $tgt 'Radiohead\OK Computer')
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $false }
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy
            $out[0].MatchType | Should -Be 'Fuzzy'
            $out[0].Renamed | Should -BeFalse
            $out[0].CurrentSourceFolder | Should -Be $out[0].SourceFolder
            @(Get-ChildItem -LiteralPath $src -Directory).Name | Should -BeExactly 'Radiohed'
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 0 -Exactly
        }

        It 'passes the same cmdlet to every prompt and accepts every folder on Yes to All' {
            New-Music (Join-Path $src 'Radiohed\OK Computer')
            New-Music (Join-Path $src 'Bjork\Homogenic')
            New-Music (Join-Path $tgt 'Radiohead\OK Computer')
            New-Music (Join-Path $tgt 'Björk\Homogenic')
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $true }
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy -Threshold 0.7
            Should -Invoke Confirm-ShouldProcess -ModuleName PwshMusicTools -Times 2 -Exactly -ParameterFilter { $Cmdlet -is [System.Management.Automation.PSCmdlet] }
            @($out | Where-Object Renamed).Count | Should -Be 2
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 2 -Exactly
        }

        It 'declines every folder on No to All' {
            New-Music (Join-Path $src 'Radiohed\OK Computer')
            New-Music (Join-Path $src 'Bjork\Homogenic')
            New-Music (Join-Path $tgt 'Radiohead\OK Computer')
            New-Music (Join-Path $tgt 'Björk\Homogenic')
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $false }
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy -Threshold 0.7
            Should -Invoke Confirm-ShouldProcess -ModuleName PwshMusicTools -Times 2 -Exactly
            @($out | Where-Object Renamed).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $src -Directory).Name | Should -Be @('Bjork', 'Radiohed')
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 0 -Exactly
        }

        It 'skips a tie between fuzzy candidates as Ambiguous' {
            New-Music (Join-Path $src 'Radiohed\OK Computer')
            New-Music (Join-Path $tgt 'Radiohead\OK Computer')
            New-Music (Join-Path $tgt 'Radiohedd\OK Computer')
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $true }
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy
            $out[0].MatchType | Should -Be 'Ambiguous'
            Should -Invoke Confirm-ShouldProcess -ModuleName PwshMusicTools -Times 0 -Exactly
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 0 -Exactly
            $script:warn.Count | Should -BeGreaterThan 0
        }
    }

    Context 'Rename safety' {
        BeforeEach { Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $true } }

        It 'skips a rename whose target already exists and merges nothing' {
            New-Music (Join-Path $src 'Radiohed\OK Computer')
            New-Music (Join-Path $src 'Radiohead\Other')
            New-Music (Join-Path $tgt 'Radiohead\OK Computer')
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy
            $row = $out | Where-Object { $_.SourceFolder -like '*Radiohed\OK Computer' }
            $row.MatchType | Should -Be 'Fuzzy'
            $row.Renamed | Should -BeFalse
            $script:warn.Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath (Join-Path $src 'Radiohed\OK Computer\01 Song.mp3') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $src 'Radiohead\Other\01 Song.mp3') | Should -BeTrue
            @(Get-ChildItem -LiteralPath (Join-Path $src 'Radiohead') -Directory).Name | Should -Be @('Other')
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 0 -Exactly
        }

        It 'moves two sibling albums under one renamed parent' {
            New-Music (Join-Path $src 'Radiohed\Album One')
            New-Music (Join-Path $src 'Radiohed\Album Two')
            New-Music (Join-Path $tgt 'Radiohead\Album One')
            New-Music (Join-Path $tgt 'Radiohead\Album Two')
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy
            $out.Count | Should -Be 2
            foreach ($r in $out) {
                $r.Renamed | Should -BeTrue
                $r.CurrentSourceFolder | Should -BeLike (Join-Path $src 'Radiohead\*')
                Test-Path -LiteralPath $r.CurrentSourceFolder | Should -BeTrue
            }
            @(Get-ChildItem -LiteralPath $src -Directory).Name | Should -BeExactly 'Radiohead'
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 2 -Exactly
        }

        It 'rejects a rename target claimed by a different folder in the same parent' {
            New-Music (Join-Path $src 'Radiohad\Album')
            New-Music (Join-Path $src 'Radiohed\Album')
            New-Music (Join-Path $tgt 'Radiohead\Album')
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy
            @($out | Where-Object Renamed).Count | Should -Be 1
            $script:warn.Count | Should -BeGreaterThan 0
            @(Get-ChildItem -LiteralPath $src -Directory).Name | Should -Be @('Radiohead', 'Radiohed')
        }
    }

    Context 'Root audio' {
        It 'skips audio directly in the source directory with a warning' {
            New-EmptyFile -Dir $src -Name 'loose.mp3' | Out-Null
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt
            $out.Count | Should -Be 1
            $out[0].MatchType | Should -Be 'Skipped'
            $out[0].Depth | Should -Be 0
            $script:warn.Count | Should -BeGreaterThan 0
        }
    }

    Context '-WhatIf' {
        It 'renames nothing and syncs with -WhatIf only when no rename is pending' {
            New-Music (Join-Path $src 'Radiohed\OK Computer')
            New-Music (Join-Path $src 'artist\album')
            New-Music (Join-Path $src 'Same\Case')
            New-Music (Join-Path $tgt 'Radiohead\OK Computer')
            New-Music (Join-Path $tgt 'Artist\Album')
            New-Music (Join-Path $tgt 'Same\Case')
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt -Fuzzy -WhatIf

            @(Get-ChildItem -LiteralPath $src -Directory).Name | Should -Be @('artist', 'Radiohed', 'Same')
            @($out | Where-Object Renamed).Count | Should -Be 0
            ($out | Where-Object { $_.SourceFolder -like '*Radiohed*' }).MatchType | Should -Be 'Fuzzy'
            ($out | Where-Object { $_.SourceFolder -like '*Radiohed*' }).Note | Should -BeLike 'WhatIf:*'
            ($out | Where-Object { $_.SourceFolder -like '*artist*' }).SyncResult | Should -BeLike 'Not run*'
            ($out | Where-Object { $_.SourceFolder -like '*Same*' }).SyncResult | Should -Be 'WhatIf'
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 1 -Exactly
            Should -Invoke Sync-SongFiles -ModuleName PwshMusicTools -Times 1 -Exactly -ParameterFilter { $WhatIf }
        }
    }

    Context 'Junctions' {
        It 'does not scan a junction in the source' -Skip:(-not $script:canJunction) {
            $ext = Join-Path $root 'external'
            New-Music (Join-Path $ext 'Artist\Album')
            New-Item -ItemType Junction -Path (Join-Path $src 'link') -Target $ext | Out-Null
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt
            $out.Count | Should -Be 0
            (Get-Item -LiteralPath (Join-Path $src 'link')).Delete()
        }

        It 'does not index a junction in the target' -Skip:(-not $script:canJunction) {
            $ext = Join-Path $root 'external'
            New-Music (Join-Path $ext 'Artist\Album')
            New-Item -ItemType Junction -Path (Join-Path $tgt 'link') -Target $ext | Out-Null
            New-Music (Join-Path $src 'Artist\Album')
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt
            $out[0].MatchType | Should -Be 'None'
            (Get-Item -LiteralPath (Join-Path $tgt 'link')).Delete()
        }
    }

    Context 'Step 2 failures and integration' {
        It 'continues after Sync-SongFiles fails on one folder' {
            New-Music (Join-Path $src 'Artist\Bad')
            New-Music (Join-Path $src 'Artist\Good')
            New-Music (Join-Path $tgt 'Artist\Bad')
            New-Music (Join-Path $tgt 'Artist\Good')
            Mock -ModuleName PwshMusicTools Sync-SongFiles { if ((Split-Path $RenameDir -Leaf) -eq 'Bad') { throw 'boom' } }
            $out = Invoke-Ingest -SourceDirectory $src -TargetDirectory $tgt
            $out.Count | Should -Be 2
            $out[0].SyncResult | Should -Be 'Failed: boom'
            $out[1].SyncResult | Should -Be 'Completed'
            $script:warn.Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Invoke-MusicIngest with the real Sync-SongFiles' {
    BeforeEach {
        $script:root = New-TestDir
        $script:src = Join-Path $script:root 'src'
        $script:tgt = Join-Path $script:root 'tgt'
        New-Item -ItemType Directory -Path $script:src, $script:tgt | Out-Null
    }
    AfterEach { Remove-TestDir -Path $script:root }

    It 'renames a song file in an exact-matched folder' {
        New-EmptyFile -Dir (Join-Path $src 'Artist\Album') -Name '01 hello world.flac' | Out-Null
        New-EmptyFile -Dir (Join-Path $tgt 'Artist\Album') -Name '01 Hello World.flac' | Out-Null
        $out = Invoke-MusicIngest -SourceDirectory $src -TargetDirectory $tgt -Confirm:$false 6>$null
        $out[0].SyncResult | Should -Be 'Completed'
        Get-FileNames -Dir (Join-Path $src 'Artist\Album') | Should -Be @('01 Hello World.flac')
    }
}