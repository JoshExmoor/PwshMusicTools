# -Skip is evaluated during discovery, before BeforeAll runs. The real
# Get-EmbeddedPicture test needs TagLibSharp already cached (the suite never
# downloads it) and ffmpeg to create a tagged mp3.
BeforeDiscovery {
    $tagLibCached    = Test-Path (Join-Path $env:LOCALAPPDATA 'TagLibSharp\TagLibSharp.dll')
    $ffmpegAvailable = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
    # Import-TagLibSharp returns at once when TagLib# is already loaded.
    $tagLibLoaded    = [bool]('TagLib.File' -as [type])
}

BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Find-CoverArt' {

    BeforeEach {
        $script:root  = New-TestDir
        $script:album = Join-Path $root 'Artist\Album'
        New-EmptyFile -Dir $album -Name '01 - Song.flac' | Out-Null
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    It 'is exported by the module' {
        (Get-Command Find-CoverArt -Module PwshMusicTools).Name | Should -Be 'Find-CoverArt'
    }

    It 'finds folder.jpg as the expected cover' {
        New-TestImage -Dir $album -Name 'cover.jpg' | Out-Null
        $folderJpg = New-TestImage -Dir $album -Name 'folder.jpg'

        $rows = @(Find-CoverArt -Path $root 6>$null)

        $rows.Count | Should -Be 1
        $rows[0].Directory | Should -Be $album
        $rows[0].CoverPresent | Should -BeTrue
        $rows[0].CoverPath | Should -Be $folderJpg
        $rows[0].Method | Should -Be 'Expected'
        $rows[0].Comment | Should -Be ''
    }

    It 'finds a hidden folder.jpg' {
        $folderJpg = New-TestImage -Dir $album -Name 'Folder.jpg'
        (Get-Item -LiteralPath $folderJpg).Attributes = 'Hidden'

        $rows = @(Find-CoverArt -Path $root 6>$null)

        $rows[0].CoverPath | Should -Be $folderJpg
        $rows[0].Method | Should -Be 'Expected'
    }

    It 'finds cover.jpg when folder.* is missing' {
        $cover = New-TestImage -Dir $album -Name 'cover.jpg'

        $rows = @(Find-CoverArt -Path $root 6>$null)

        $rows[0].CoverPresent | Should -BeTrue
        $rows[0].CoverPath | Should -Be $cover
        $rows[0].MatchedName | Should -Be 'cover.jpg'
        $rows[0].Method | Should -Be 'KnownName'
        $rows[0].Comment | Should -Be 'Expected name missing; found cover.jpg'
        Get-FileNames -Dir $album | Should -Not -Contain 'folder.jpg'
    }

    It 'prefers jpg over png for the same name' {
        New-TestImage -Dir $album -Name 'cover.png' | Out-Null
        $jpg = New-TestImage -Dir $album -Name 'cover.jpg'
        New-TestImage -Dir $album -Name 'folder.webp' | Out-Null
        $folderPng = New-TestImage -Dir $album -Name 'folder.png'

        $rows = @(Find-CoverArt -Path $root 6>$null)
        $rows[0].CoverPath | Should -Be $folderPng

        Remove-Item -LiteralPath $folderPng, (Join-Path $album 'folder.webp')
        $rows = @(Find-CoverArt -Path $root 6>$null)
        $rows[0].CoverPath | Should -Be $jpg
    }

    It 'uses a custom -ExpectedCoverName' {
        New-TestImage -Dir $album -Name 'folder.jpg' | Out-Null
        $cover = New-TestImage -Dir $album -Name 'Cover.PNG'

        $rows = @(Find-CoverArt -Path $root -ExpectedCoverName 'cover' 6>$null)

        $rows[0].CoverPath | Should -Be $cover
        $rows[0].Method | Should -Be 'Expected'
    }

    It 'falls back from cover to folder when cover is the expected name, and copies it' {
        $folderJpg = New-TestImage -Dir $album -Name 'folder.jpg'

        $rows = @(Find-CoverArt -Path $root -ExpectedCoverName 'cover' -CopyToExpected 6>$null)

        $rows[0].Comment | Should -Be 'Copied from folder.jpg'
        $rows[0].CoverPath | Should -Be (Join-Path $album 'cover.jpg')
        Test-Path -LiteralPath $folderJpg | Should -BeTrue
    }

    It 'does not choose a back or cd image' {
        New-TestImage -Dir $album -Name 'Back Cover.jpg' | Out-Null
        New-TestImage -Dir $album -Name 'cd cover.jpg' | Out-Null
        $front = New-TestImage -Dir $album -Name 'Album Front Scan.png'

        $rows = @(Find-CoverArt -Path $root 6>$null)

        $rows[0].CoverPath | Should -Be $front
        $rows[0].Method | Should -Be 'NameContains'

        Remove-Item -LiteralPath $front
        $rows = @(Find-CoverArt -Path $root 6>$null)

        $rows[0].CoverPresent | Should -BeFalse
        $rows[0].CoverPath | Should -Be ''
    }

    It 'uses a single oddly named image as the last resort' {
        $odd = New-TestImage -Dir $album -Name 'scan0001.jpeg'

        $rows = @(Find-CoverArt -Path $root 6>$null)

        $rows[0].CoverPath | Should -Be $odd
        $rows[0].Method | Should -Be 'OnlyImage'
    }

    It 'does not use the last resort when there are several unrelated images' {
        New-TestImage -Dir $album -Name 'scan0001.jpg' | Out-Null
        New-TestImage -Dir $album -Name 'scan0002.jpg' | Out-Null

        $rows = @(Find-CoverArt -Path $root 6>$null)

        $rows[0].CoverPresent | Should -BeFalse
    }

    It 'does not report a folder without audio' {
        New-TestImage -Dir (Join-Path $root 'Scans') -Name 'cover.jpg' | Out-Null
        New-EmptyFile -Dir $root -Name 'notes.txt' | Out-Null

        $rows = @(Find-CoverArt -Path $root 6>$null)

        $rows.Count | Should -Be 1
        $rows[0].Directory | Should -Be $album
    }

    It 'reports a folder with audio but no image as CoverPresent False' {
        New-EmptyFile -Dir $album -Name 'notes.txt' | Out-Null

        $rows = @(Find-CoverArt -Path $root -CopyToExpected 6>$null)

        $rows[0].CoverPresent | Should -BeFalse
        $rows[0].CoverPath | Should -Be ''
        $rows[0].Comment | Should -Be 'No cover found'
        $rows[0].Method | Should -Be 'None'
    }

    It 'copies cover.jpg to folder.jpg with -CopyToExpected and keeps the original' {
        $cover = New-TestImage -Dir $album -Name 'cover.jpg' -Width 700 -Height 500

        $rows = @(Find-CoverArt -Path $root -CopyToExpected 6>$null)

        $target = Join-Path $album 'folder.jpg'
        Test-Path -LiteralPath $cover | Should -BeTrue
        [System.IO.File]::ReadAllBytes($target) | Should -Be ([System.IO.File]::ReadAllBytes($cover))
        $rows[0].CoverPresent | Should -BeTrue
        $rows[0].CoverPath | Should -Be $target
        $rows[0].MatchedName | Should -Be 'cover.jpg'
        $rows[0].Comment | Should -Be 'Copied from cover.jpg'
    }

    It 'keeps the source extension when copying' {
        New-TestImage -Dir $album -Name 'front.png' | Out-Null

        Find-CoverArt -Path $root -CopyToExpected 6>$null | Out-Null

        Get-FileNames -Dir $album | Should -Contain 'folder.png'
    }

    It 'does not overwrite an existing expected-named file' {
        New-TestImage -Dir $album -Name 'cover.jpg' | Out-Null
        $existing = Join-Path $album 'FOLDER.ini'
        Set-Content -LiteralPath $existing -Value 'keep'

        $rows = @(Find-CoverArt -Path $root -CopyToExpected 6>$null)

        Get-FileNames -Dir $album | Should -Not -Contain 'folder.jpg'
        Get-Content -LiteralPath $existing | Should -Be 'keep'
        $rows[0].Comment | Should -BeLike 'Not copied: FOLDER.ini already exists*'
        $rows[0].CoverPath | Should -Be (Join-Path $album 'cover.jpg')
    }

    It 'does not overwrite a target that appears after the scan' {
        New-TestImage -Dir $album -Name 'cover.jpg' | Out-Null
        # Not named $target: the mock binds Confirm-ShouldProcess's -Target.
        $script:lateFile = Join-Path $album 'folder.jpg'
        Mock -ModuleName PwshMusicTools Confirm-ShouldProcess {
            Set-Content -LiteralPath $script:lateFile -Value 'keep'
            $true
        }

        $rows = @(Find-CoverArt -Path $root -CopyToExpected 6>$null 3>$null)

        Get-Content -LiteralPath $script:lateFile | Should -Be 'keep'
        $rows[0].Comment | Should -BeLike 'Copy failed:*'
    }

    It 'copies nothing under -WhatIf and says what would be copied' {
        $cover = New-TestImage -Dir $album -Name 'cover.jpg'

        $rows = @(Find-CoverArt -Path $root -CopyToExpected -WhatIf 6>$null)

        Get-FileNames -Dir $album | Should -Not -Contain 'folder.jpg'
        $rows[0].Comment | Should -Be 'WhatIf: would copy from cover.jpg to folder.jpg'
        $rows[0].CoverPath | Should -Be $cover
    }

    It 'lists every planned copy in the batch prompt under -WhatIf' {
        $cover = New-TestImage -Dir $album -Name 'cover.jpg'
        $script:prompt = $null
        Mock -ModuleName PwshMusicTools Confirm-ShouldProcess {
            $script:prompt = $Target
            $false
        }

        Find-CoverArt -Path $root -CopyToExpected -WhatIf 6>$null | Out-Null

        $script:prompt | Should -Be "1 cover file(s):`n  $cover -> folder.jpg"
    }

    It 'does not prompt by default' {
        (Get-Command Find-CoverArt).ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            ForEach-Object { $_.ConfirmImpact } | Should -Be 'Medium'
    }

    It 'asks once for the whole batch of copies' {
        Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $true }
        New-TestImage -Dir $album -Name 'cover.jpg' | Out-Null
        $album2 = Join-Path $root 'Artist\Album 2'
        New-EmptyFile -Dir $album2 -Name '01.mp3' | Out-Null
        New-TestImage -Dir $album2 -Name 'front.jpg' | Out-Null

        $rows = @(Find-CoverArt -Path $root -CopyToExpected 6>$null)

        Should -Invoke Confirm-ShouldProcess -ModuleName PwshMusicTools -Times 1 -Exactly
        @($rows | Where-Object Comment -like 'Copied from*').Count | Should -Be 2
    }

    It 'copies nothing when the batch is declined' {
        Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $false }
        New-TestImage -Dir $album -Name 'cover.jpg' | Out-Null

        $rows = @(Find-CoverArt -Path $root -CopyToExpected 6>$null)

        Get-FileNames -Dir $album | Should -Not -Contain 'folder.jpg'
        $rows[0].Comment | Should -Be 'Copy declined; found cover.jpg'
    }

    It 'writes the CSV columns and rows, also under -WhatIf' {
        $csv = Join-Path $root 'covers.csv'
        New-TestImage -Dir $album -Name 'cover.jpg' | Out-Null
        $empty = Join-Path $root 'Artist\No Art'
        New-EmptyFile -Dir $empty -Name '01.opus' | Out-Null

        Find-CoverArt -Path $root -CopyToExpected -ExportReportPath $csv -WhatIf 6>$null | Out-Null

        $header = (Get-Content -LiteralPath $csv -TotalCount 1) -replace '"', ''
        $header | Should -Be 'Directory,CoverPresent,CoverPath,Comment,MatchedName,Method,CoverWidth,CoverHeight,CoverSizeKB,DetectedFormat,LowResolution,NonSquare,FormatMismatch,Unreadable,OtherImages,EmbeddedArt'
        $data = @(Import-Csv -LiteralPath $csv)
        $data.Count | Should -Be 2
        $data[0].Directory | Should -Be $album
        $data[0].CoverPresent | Should -Be 'True'
        $data[0].CoverPath | Should -Be (Join-Path $album 'cover.jpg')
        $data[0].Comment | Should -Be 'WhatIf: would copy from cover.jpg to folder.jpg'
        $data[1].Directory | Should -Be $empty
        $data[1].CoverPresent | Should -Be 'False'
        $data[1].Comment | Should -Be 'No cover found'
    }

    It 'fails on a bad -ExportReportPath before any scan or copy' {
        Mock -ModuleName PwshMusicTools Get-ChildItem { }
        New-TestImage -Dir $album -Name 'cover.jpg' | Out-Null
        $bad = Join-Path $root 'missing\covers.csv'

        { Find-CoverArt -Path $root -CopyToExpected -ExportReportPath $bad 6>$null } |
            Should -Throw '*ExportReportPath folder*does not exist*'

        Should -Invoke Get-ChildItem -ModuleName PwshMusicTools -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $album 'folder.jpg') | Should -BeFalse
    }

    It 'recurses across nested album folders, including the root' {
        New-EmptyFile -Dir $root -Name 'loose.mp3' | Out-Null
        New-TestImage -Dir $album -Name 'folder.jpg' | Out-Null
        $cd2 = Join-Path $album 'CD2'
        New-EmptyFile -Dir $cd2 -Name '01.m4a' | Out-Null
        New-TestImage -Dir $cd2 -Name 'cover.png' | Out-Null
        $deep = Join-Path $root 'Genre\Other Artist\Other Album'
        New-EmptyFile -Dir $deep -Name '01.ogg' | Out-Null

        $rows = @(Find-CoverArt -Path $root 6>$null)

        @($rows.Directory) | Should -Be @($root, $album, $cd2, $deep)
        @($rows.CoverPresent) | Should -Be @($false, $true, $true, $false)
    }

    It 'does not follow a junction' {
        $outside = New-TestDir
        try {
            New-EmptyFile -Dir $outside -Name '01.mp3' | Out-Null
            New-Item -ItemType Junction -Path (Join-Path $root 'Link') -Target $outside | Out-Null

            $rows = @(Find-CoverArt -Path $root 6>$null)

            @($rows.Directory) | Should -Be @($album)
        }
        finally {
            Remove-Item -LiteralPath (Join-Path $root 'Link') -Force -ErrorAction SilentlyContinue
            Remove-TestDir -Path $outside
        }
    }

    It 'returns a flat array and accepts pipeline input' {
        $album2 = Join-Path $root 'Other'
        New-EmptyFile -Dir $album2 -Name '01.mp3' | Out-Null

        $rows = @(Get-Item -LiteralPath $album, $album2 | Find-CoverArt 6>$null)

        $rows.Count | Should -Be 2
        $rows[0] | Should -BeOfType [PSCustomObject]
    }

    Context 'image details' {

        It 'reports width, height and detected format' {
            New-TestImage -Dir $album -Name 'folder.png' -Width 800 -Height 600 | Out-Null

            $rows = @(Find-CoverArt -Path $root 6>$null)

            $rows[0].CoverWidth | Should -Be 800
            $rows[0].CoverHeight | Should -Be 600
            $rows[0].DetectedFormat | Should -Be 'PNG'
            $rows[0].Unreadable | Should -BeFalse
            $rows[0].FormatMismatch | Should -BeFalse
            $rows[0].EmbeddedArt | Should -Be ''
        }

        It 'reports the file size in KB with one decimal' {
            New-TestImage -Dir $album -Name 'folder.jpg' -PadTo 3000 | Out-Null

            $rows = @(Find-CoverArt -Path $root 6>$null)

            $rows[0].CoverSizeKB | Should -Be ([Math]::Round(3000 / 1024, 1))
            $rows[0].CoverSizeKB | Should -Be 2.9
        }

        It 'flags LowResolution by -MinimumSize' {
            New-TestImage -Dir $album -Name 'folder.jpg' -Width 400 -Height 400 | Out-Null

            @(Find-CoverArt -Path $root 6>$null)[0].LowResolution | Should -BeTrue
            @(Find-CoverArt -Path $root -MinimumSize 300 6>$null)[0].LowResolution | Should -BeFalse
        }

        It 'does not flag LowResolution with -MinimumSize 0' {
            New-TestImage -Dir $album -Name 'folder.jpg' -Width 100 -Height 100 | Out-Null

            @(Find-CoverArt -Path $root -MinimumSize 0 6>$null)[0].LowResolution | Should -BeFalse
        }

        It 'flags NonSquare only beyond 5%' {
            $f = New-TestImage -Dir $album -Name 'folder.jpg' -Width 1000 -Height 950
            @(Find-CoverArt -Path $root 6>$null)[0].NonSquare | Should -BeFalse

            Remove-Item -LiteralPath $f
            New-TestImage -Dir $album -Name 'folder.jpg' -Width 1000 -Height 949 | Out-Null
            @(Find-CoverArt -Path $root 6>$null)[0].NonSquare | Should -BeTrue
        }

        It 'flags FormatMismatch for a PNG named .jpg but not for .jpeg JPEG' {
            $f = New-TestImage -Dir $album -Name 'folder.jpg' -Format 'PNG'
            $row = @(Find-CoverArt -Path $root 6>$null)[0]
            $row.DetectedFormat | Should -Be 'PNG'
            $row.FormatMismatch | Should -BeTrue

            Remove-Item -LiteralPath $f
            New-TestImage -Dir $album -Name 'folder.jpeg' | Out-Null
            $row = @(Find-CoverArt -Path $root 6>$null)[0]
            $row.DetectedFormat | Should -Be 'JPEG'
            $row.FormatMismatch | Should -BeFalse
        }

        It 'reports an unreadable cover and keeps scanning' {
            New-GarbageFile -Dir $album -Name 'cover.jpg' | Out-Null
            $album2 = Join-Path $root 'Artist\Album 2'
            New-EmptyFile -Dir $album2 -Name '01.mp3' | Out-Null
            New-TestImage -Dir $album2 -Name 'cover.jpg' | Out-Null

            $rows = @(Find-CoverArt -Path $root 6>$null)

            $rows.Count | Should -Be 2
            $bad = $rows | Where-Object Directory -eq $album
            $bad.CoverPresent | Should -BeTrue
            $bad.Unreadable | Should -BeTrue
            $bad.CoverWidth | Should -BeNullOrEmpty
            $bad.Comment | Should -BeLike '*Unreadable image:*'
            $good = $rows | Where-Object Directory -eq $album2
            $good.Unreadable | Should -BeFalse
            $good.CoverWidth | Should -Be 600
            $good.Comment | Should -Be 'Expected name missing; found cover.jpg'
        }

        It 'picks the largest candidate with -PreferLargest' {
            New-TestImage -Dir $album -Name 'front.png' -Width 1400 -Height 1400 | Out-Null
            New-TestImage -Dir $album -Name 'cover.jpg' | Out-Null

            $row = @(Find-CoverArt -Path $root -PreferLargest 6>$null)[0]
            $row.MatchedName | Should -Be 'front.png'
            $row.Method | Should -Be 'KnownName'

            @(Find-CoverArt -Path $root 6>$null)[0].MatchedName | Should -Be 'cover.jpg'
        }

        It 'ranks an unreadable candidate last with -PreferLargest' {
            New-GarbageFile -Dir $album -Name 'cover.jpg' | Out-Null
            New-TestImage -Dir $album -Name 'front.jpg' | Out-Null

            @(Find-CoverArt -Path $root -PreferLargest 6>$null)[0].MatchedName | Should -Be 'front.jpg'
            @(Find-CoverArt -Path $root 6>$null)[0].MatchedName | Should -Be 'cover.jpg'
        }

        It 'keeps the expected file and notes a larger candidate with -PreferLargest' {
            $folderJpg = New-TestImage -Dir $album -Name 'folder.jpg'
            $before = [System.IO.File]::ReadAllBytes($folderJpg)
            New-TestImage -Dir $album -Name 'front.png' -Width 1400 -Height 1400 | Out-Null

            $row = @(Find-CoverArt -Path $root -PreferLargest 6>$null)[0]

            $row.CoverPath | Should -Be $folderJpg
            $row.Method | Should -Be 'Expected'
            $row.Comment | Should -Be 'Larger candidate: front.png 1400x1400'
            [System.IO.File]::ReadAllBytes($folderJpg) | Should -Be $before
            @(Find-CoverArt -Path $root 6>$null)[0].Comment | Should -Be ''
        }

        It 'does not note a candidate less than 10% larger' {
            New-TestImage -Dir $album -Name 'folder.jpg' | Out-Null
            New-TestImage -Dir $album -Name 'front.png' -Width 620 -Height 620 | Out-Null

            @(Find-CoverArt -Path $root -PreferLargest 6>$null)[0].Comment | Should -Be ''
        }

        It 'lists the other images with their sizes' {
            New-TestImage -Dir $album -Name 'folder.jpg' | Out-Null
            New-TestImage -Dir $album -Name 'front.png' -Width 1400 -Height 1400 | Out-Null
            New-TestImage -Dir $album -Name 'back.jpg' -Width 1000 -Height 1000 | Out-Null
            New-GarbageFile -Dir $album -Name 'scan.jpg' | Out-Null

            $row = @(Find-CoverArt -Path $root 6>$null)[0]

            $row.OtherImages | Should -Be 'back.jpg (1000x1000); front.png (1400x1400); scan.jpg (unreadable)'
        }
    }

    Context 'disc folders' {

        BeforeEach {
            $script:box = Join-Path $root 'Artist\Box'
            $script:cd1 = Join-Path $box 'CD1'
            New-EmptyFile -Dir $cd1 -Name '01.flac' | Out-Null
        }

        It 'recognises disc folder names' {
            InModuleScope PwshMusicTools {
                foreach ($n in @('CD1', 'CD 01', 'Disc 2', 'Disk_3', 'Disc 1 - Live', 'cd.2')) {
                    Test-DiscFolderName -Name $n | Should -BeTrue -Because $n
                }
                foreach ($n in @('CDs', 'Discography', 'CD', 'Disc Two', 'Bonus CD1')) {
                    Test-DiscFolderName -Name $n | Should -BeFalse -Because $n
                }
            }
        }

        It 'uses the parent folder cover for a disc folder' {
            $parentCover = New-TestImage -Dir $box -Name 'folder.jpg'

            $rows = @(Find-CoverArt -Path $root 6>$null)

            $row = $rows | Where-Object Directory -eq $cd1
            $row.CoverPresent | Should -BeTrue
            $row.CoverPath | Should -Be $parentCover
            $row.MatchedName | Should -Be 'folder.jpg'
            $row.Method | Should -Be 'Parent'
            $row.Comment | Should -Be 'Using parent folder cover'
            $row.CoverWidth | Should -Be 600
            @($rows.Directory) | Should -Not -Contain $box
        }

        It 'does not use the parent cover for a non-disc sub-folder' {
            New-TestImage -Dir $box -Name 'folder.jpg' | Out-Null
            $extras = Join-Path $box 'Extras'
            New-EmptyFile -Dir $extras -Name '01.flac' | Out-Null

            $row = @(Find-CoverArt -Path $root 6>$null) | Where-Object Directory -eq $extras

            $row.CoverPresent | Should -BeFalse
        }

        It 'prefers the disc folder''s own cover' {
            New-TestImage -Dir $box -Name 'folder.jpg' | Out-Null
            $own = New-TestImage -Dir $cd1 -Name 'cover.jpg'

            $row = @(Find-CoverArt -Path $root 6>$null) | Where-Object Directory -eq $cd1

            $row.CoverPath | Should -Be $own
            $row.Method | Should -Be 'KnownName'
        }

        It 'copies the parent cover with -CopyParentToDisc and never overwrites' {
            $parentCover = New-TestImage -Dir $box -Name 'folder.jpg' -Width 700 -Height 700
            $cd2 = Join-Path $box 'CD2'
            New-EmptyFile -Dir $cd2 -Name '01.flac' | Out-Null
            $ini = Join-Path $cd2 'folder.ini'
            Set-Content -LiteralPath $ini -Value 'keep'

            $rows = @(Find-CoverArt -Path $root -CopyParentToDisc 6>$null)

            $copy = Join-Path $cd1 'folder.jpg'
            [System.IO.File]::ReadAllBytes($copy) | Should -Be ([System.IO.File]::ReadAllBytes($parentCover))
            $row1 = $rows | Where-Object Directory -eq $cd1
            $row1.CoverPath | Should -Be $copy
            $row1.Method | Should -Be 'Parent'
            $row1.Comment | Should -Be 'Copied from parent folder (folder.jpg)'

            $row2 = $rows | Where-Object Directory -eq $cd2
            Get-FileNames -Dir $cd2 | Should -Not -Contain 'folder.jpg'
            Get-Content -LiteralPath $ini | Should -Be 'keep'
            $row2.Comment | Should -Be 'Not copied: folder.ini already exists; using parent folder cover'
        }

        It 'copies nothing with -CopyParentToDisc -WhatIf' {
            $parentCover = New-TestImage -Dir $box -Name 'folder.jpg'

            $row = @(Find-CoverArt -Path $root -CopyParentToDisc -WhatIf 6>$null) | Where-Object Directory -eq $cd1

            Get-FileNames -Dir $cd1 | Should -Not -Contain 'folder.jpg'
            $row.CoverPath | Should -Be $parentCover
            $row.Comment | Should -Be 'WhatIf: would copy parent folder cover folder.jpg to folder.jpg'
        }

        It 'confirms a mixed batch of copies once' {
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $true }
            New-TestImage -Dir $album -Name 'cover.jpg' | Out-Null
            New-TestImage -Dir $box -Name 'front.jpg' | Out-Null

            $rows = @(Find-CoverArt -Path $root -CopyToExpected -CopyParentToDisc 6>$null)

            Should -Invoke Confirm-ShouldProcess -ModuleName PwshMusicTools -Times 1 -Exactly
            Test-Path -LiteralPath (Join-Path $album 'folder.jpg') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $cd1 'folder.jpg') | Should -BeTrue
            ($rows | Where-Object Directory -eq $album).Comment | Should -Be 'Copied from cover.jpg'
            ($rows | Where-Object Directory -eq $cd1).Comment | Should -Be 'Copied from parent folder (front.jpg)'
        }
    }

    Context 'embedded art' {

        BeforeEach {
            # TagLib# is never loaded or downloaded: both seams are mocked.
            Mock -ModuleName PwshMusicTools Import-TagLibSharp { }
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { @() }

            $script:emb = Join-Path $root 'Artist\Embedded'
            foreach ($n in '01.mp3', '02.mp3', '03.mp3') { New-EmptyFile -Dir $emb -Name $n | Out-Null }

            $script:png800 = [byte[]](New-TestImageBytes -Format PNG -Width 800 -Height 800)
            $script:jpg600 = [byte[]](New-TestImageBytes -Format JPEG)
            $script:frontPng = [PSCustomObject]@{ Type = 'FrontCover'; MimeType = 'image/png'; Data = $script:png800 }
            $script:otherJpg = [PSCustomObject]@{ Type = 'Other'; MimeType = 'image/jpeg'; Data = $script:jpg600 }

            # Recursive file list, to prove that nothing was written.
            $script:listFiles = { @(Get-ChildItem -LiteralPath $script:root -Recurse -Force -File | ForEach-Object FullName | Sort-Object) }
        }

        It 'leaves EmbeddedArt blank and never touches TagLib without -CheckEmbedded' {
            $rows = @(Find-CoverArt -Path $root 6>$null)

            @($rows.EmbeddedArt) | Should -Be @('', '')
            Should -Invoke Get-EmbeddedPicture -ModuleName PwshMusicTools -Times 0 -Exactly
            Should -Invoke Import-TagLibSharp -ModuleName PwshMusicTools -Times 0 -Exactly
        }

        It 'reports None, Some (n/m) and All' {
            (@(Find-CoverArt -Path $emb -CheckEmbedded 6>$null)[0]).EmbeddedArt | Should -Be 'None'
            Should -Invoke Import-TagLibSharp -ModuleName PwshMusicTools -Times 1 -Exactly

            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:frontPng } -ParameterFilter { $LiteralPath -like '*\01.mp3' -or $LiteralPath -like '*\03.mp3' }
            (@(Find-CoverArt -Path $emb -CheckEmbedded 6>$null)[0]).EmbeddedArt | Should -Be 'Some (2/3)'

            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:frontPng } -ParameterFilter { $LiteralPath -like '*\02.mp3' }
            (@(Find-CoverArt -Path $emb -CheckEmbedded 6>$null)[0]).EmbeddedArt | Should -Be 'All'
        }

        It 'counts an unreadable track as no art and names it in Comment' {
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:frontPng } -ParameterFilter { $LiteralPath -like '*\01.mp3' }
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { throw 'corrupt tag' } -ParameterFilter { $LiteralPath -like '*\02.mp3' }

            $row = @(Find-CoverArt -Path $emb -CheckEmbedded 6>$null)[0]

            $row.EmbeddedArt | Should -Be 'Some (1/3)'
            $row.Comment | Should -BeLike '*Embedded art unreadable: 02.mp3*'
        }

        It 'extracts the FrontCover picture with -ExtractEmbedded' {
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:otherJpg } -ParameterFilter { $LiteralPath -like '*\01.mp3' }
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:frontPng } -ParameterFilter { $LiteralPath -like '*\02.mp3' }

            $row = @(Find-CoverArt -Path $emb -ExtractEmbedded 6>$null)[0]

            $written = Join-Path $emb 'folder.png'
            [System.IO.File]::ReadAllBytes($written) | Should -Be $script:png800
            Get-FileNames -Dir $emb | Should -Not -Contain 'folder.jpg'
            $row.Comment | Should -Be 'Extracted from 02.mp3'
            # Picture bytes are read for the chosen track only: once for the
            # columns, once again at write time.
            Should -Invoke Get-EmbeddedPicture -ModuleName PwshMusicTools -ParameterFilter { $IncludeData -and $LiteralPath -like '*\02.mp3' } -Times 2 -Exactly
            Should -Invoke Get-EmbeddedPicture -ModuleName PwshMusicTools -ParameterFilter { $IncludeData -and $LiteralPath -notlike '*\02.mp3' } -Times 0 -Exactly
            $row.Method | Should -Be 'Embedded'
            $row.MatchedName | Should -Be '02.mp3'
            $row.CoverPresent | Should -BeTrue
            $row.CoverPath | Should -Be $written
            $row.CoverWidth | Should -Be 800
            $row.DetectedFormat | Should -Be 'PNG'
            $row.EmbeddedArt | Should -Be 'Some (2/3)'
        }

        It 'uses the first picture when no track has a FrontCover' {
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:otherJpg } -ParameterFilter { $LiteralPath -like '*\02.mp3' }

            $row = @(Find-CoverArt -Path $emb -ExtractEmbedded 6>$null)[0]

            [System.IO.File]::ReadAllBytes((Join-Path $emb 'folder.jpg')) | Should -Be $script:jpg600
            $row.Comment | Should -Be 'Extracted from 02.mp3'
        }

        It 'takes the extension from the image bytes over the MIME type' {
            $script:mislabelled = [PSCustomObject]@{ Type = 'FrontCover'; MimeType = 'image/jpeg'; Data = $script:png800 }
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:mislabelled } -ParameterFilter { $LiteralPath -like '*\01.mp3' }

            $row = @(Find-CoverArt -Path $emb -ExtractEmbedded 6>$null)[0]

            Get-FileNames -Dir $emb | Should -Contain 'folder.png'
            Get-FileNames -Dir $emb | Should -Not -Contain 'folder.jpg'
            $row.FormatMismatch | Should -BeFalse
        }

        It 'falls back to the MIME type when the bytes are not a known image' {
            $script:garbage = [PSCustomObject]@{ Type = 'FrontCover'; MimeType = 'image/jpeg'; Data = [byte[]][System.Text.Encoding]::ASCII.GetBytes('not an image') }
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:garbage } -ParameterFilter { $LiteralPath -like '*\01.mp3' }

            $row = @(Find-CoverArt -Path $emb -ExtractEmbedded 6>$null)[0]

            Get-FileNames -Dir $emb | Should -Contain 'folder.jpg'
            $row.Unreadable | Should -BeTrue
            $row.Comment | Should -BeLike 'Extracted from 01.mp3*'
        }

        It 'drops the unreadable-image note of a declined extraction' {
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $false }
            $script:garbage = [PSCustomObject]@{ Type = 'FrontCover'; MimeType = 'image/jpeg'; Data = [byte[]][System.Text.Encoding]::ASCII.GetBytes('not an image') }
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:garbage } -ParameterFilter { $LiteralPath -like '*\01.mp3' }

            $row = @(Find-CoverArt -Path $emb -ExtractEmbedded 6>$null)[0]

            Get-FileNames -Dir $emb | Should -Not -Contain 'folder.jpg'
            $row.Comment | Should -Be 'Extraction declined; embedded art in 01.mp3'
            $row.Unreadable | Should -BeNullOrEmpty
        }

        It 'reports a failed extraction when the picture is gone at write time' {
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $true }
            $script:embReads = 0
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture {
                if ($IncludeData) { $script:embReads++ }
                if ($IncludeData -and $script:embReads -gt 1) { @() } else { $script:frontPng }
            } -ParameterFilter { $LiteralPath -like '*\01.mp3' }

            $row = @(Find-CoverArt -Path $emb -ExtractEmbedded 6>$null 3>$null)[0]

            Get-FileNames -Dir $emb | Should -Not -Contain 'folder.png'
            $row.Comment | Should -BeLike 'Extraction failed: *; embedded art in 01.mp3'
            $row.CoverPresent | Should -BeFalse
            $row.CoverWidth | Should -BeNullOrEmpty
        }

        It 'extracts nothing when the folder has an image file' {
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:frontPng }
            New-TestImage -Dir $emb -Name 'scan1.jpg' | Out-Null
            New-TestImage -Dir $emb -Name 'scan2.jpg' | Out-Null

            $row = @(Find-CoverArt -Path $emb -ExtractEmbedded 6>$null)[0]

            Get-FileNames -Dir $emb | Should -Not -Contain 'folder.png'
            $row.Comment | Should -Be 'No cover found'
            $row.EmbeddedArt | Should -Be 'All'
            Should -Invoke Get-EmbeddedPicture -ModuleName PwshMusicTools -ParameterFilter { $IncludeData } -Times 0 -Exactly
        }

        It 'extracts nothing when the folder has a cover' {
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:frontPng }
            New-TestImage -Dir $emb -Name 'cover.jpg' | Out-Null

            $row = @(Find-CoverArt -Path $emb -ExtractEmbedded 6>$null)[0]

            Get-FileNames -Dir $emb | Should -Not -Contain 'folder.png'
            $row.MatchedName | Should -Be 'cover.jpg'
        }

        It 'extracts nothing for a disc folder using the parent cover' {
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:frontPng }
            $box = Join-Path $root 'Artist\Box'
            $cd1 = Join-Path $box 'CD1'
            New-EmptyFile -Dir $cd1 -Name '01.flac' | Out-Null
            New-TestImage -Dir $box -Name 'folder.jpg' | Out-Null

            $row = @(Find-CoverArt -Path $box -ExtractEmbedded 6>$null)[0]

            Get-FileNames -Dir $cd1 | Should -Be @('01.flac')
            $row.Method | Should -Be 'Parent'
        }

        It 'does not overwrite an existing expected-named file' {
            Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:frontPng }
            Set-Content -LiteralPath (Join-Path $emb 'folder.txt') -Value 'keep'

            $row = @(Find-CoverArt -Path $emb -ExtractEmbedded 6>$null)[0]

            Get-FileNames -Dir $emb | Should -Not -Contain 'folder.png'
            Get-Content -LiteralPath (Join-Path $emb 'folder.txt') | Should -Be 'keep'
            $row.Comment | Should -Be 'Not extracted: folder.txt already exists'
            $row.CoverPresent | Should -BeFalse
        }

        Context 'mixed batch' {

            BeforeEach {
                # A: cover.jpg to copy; B\CD1: parent folder.jpg to copy down;
                # Embedded: no image, embedded art to extract.
                New-TestImage -Dir $album -Name 'cover.jpg' | Out-Null
                $script:cdB = Join-Path $root 'Artist\Album B\CD1'
                New-EmptyFile -Dir $cdB -Name '01.flac' | Out-Null
                New-TestImage -Dir (Split-Path $cdB -Parent) -Name 'folder.jpg' | Out-Null
                Mock -ModuleName PwshMusicTools Get-EmbeddedPicture { $script:frontPng } -ParameterFilter { $LiteralPath -like '*\Embedded\01.mp3' }
            }

            It 'writes nothing under -WhatIf but fills the image columns' {
                $before = & $script:listFiles

                $rows = @(Find-CoverArt -Path $root -CopyToExpected -CopyParentToDisc -ExtractEmbedded -WhatIf 6>$null)

                & $script:listFiles | Should -Be $before
                foreach ($d in $album, $cdB, $emb) {
                    $row = $rows | Where-Object Directory -eq $d
                    $row.Comment | Should -BeLike 'WhatIf:*' -Because $d
                    $row.CoverWidth | Should -Not -BeNullOrEmpty -Because $d
                }
                $e = $rows | Where-Object Directory -eq $emb
                $e.Comment | Should -Be 'WhatIf: would extract from 01.mp3 to folder.png'
                $e.CoverPresent | Should -BeFalse
                $e.CoverPath | Should -Be ''
                $e.CoverWidth | Should -Be 800
            }

            It 'confirms all three kinds of writes once' {
                Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $true }

                $rows = @(Find-CoverArt -Path $root -CopyToExpected -CopyParentToDisc -ExtractEmbedded 6>$null)

                Should -Invoke Confirm-ShouldProcess -ModuleName PwshMusicTools -Times 1 -Exactly
                Test-Path -LiteralPath (Join-Path $album 'folder.jpg') | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $cdB 'folder.jpg') | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $emb 'folder.png') | Should -BeTrue
                ($rows | Where-Object Directory -eq $emb).Comment | Should -Be 'Extracted from 01.mp3'
            }

            It 'clears the image columns of a declined extraction' {
                Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $false }

                $rows = @(Find-CoverArt -Path $root -CopyToExpected -CopyParentToDisc -ExtractEmbedded 6>$null)

                Get-FileNames -Dir $emb | Should -Not -Contain 'folder.png'
                $e = $rows | Where-Object Directory -eq $emb
                $e.Comment | Should -Be 'Extraction declined; embedded art in 01.mp3'
                $e.CoverPresent | Should -BeFalse
                $e.CoverWidth | Should -BeNullOrEmpty
                $e.CoverSizeKB | Should -BeNullOrEmpty
                $e.DetectedFormat | Should -Be ''
            }
        }
    }
}

Describe 'Import-TagLibSharp under -WhatIf' -Skip:$tagLibLoaded {

    It 'runs its download steps regardless of the caller''s -WhatIf/-Confirm' {
        # Every step is mocked: nothing is downloaded or written.
        Mock -ModuleName PwshMusicTools Test-Path { $false }
        Mock -ModuleName PwshMusicTools New-Item { }
        Mock -ModuleName PwshMusicTools Invoke-WebRequest { }
        Mock -ModuleName PwshMusicTools Expand-Archive { }
        Mock -ModuleName PwshMusicTools Get-ChildItem {
            [PSCustomObject]@{ FullName = 'X:\extracted\TagLibSharp.dll'; Directory = [PSCustomObject]@{ Name = 'netstandard2.0' } }
        }
        Mock -ModuleName PwshMusicTools Copy-Item { }
        Mock -ModuleName PwshMusicTools Remove-Item { }
        Mock -ModuleName PwshMusicTools Add-Type { }

        InModuleScope PwshMusicTools {
            $WhatIfPreference = $true
            $ConfirmPreference = 'Low'
            Import-TagLibSharp
        }

        # Every call must pass -WhatIf:$false and -Confirm:$false explicitly.
        $optedOut = { $PesterBoundParameters.ContainsKey('WhatIf') -and -not $WhatIf -and $PesterBoundParameters.ContainsKey('Confirm') -and -not $Confirm }
        $notOptedOut = { -not ($PesterBoundParameters.ContainsKey('WhatIf') -and -not $WhatIf -and $PesterBoundParameters.ContainsKey('Confirm') -and -not $Confirm) }
        foreach ($cmd in 'New-Item', 'Expand-Archive', 'Copy-Item', 'Remove-Item') {
            Should -Invoke $cmd -ModuleName PwshMusicTools -ParameterFilter $optedOut -Times 1 -Because $cmd
            Should -Invoke $cmd -ModuleName PwshMusicTools -ParameterFilter $notOptedOut -Times 0 -Exactly -Because $cmd
        }
        Should -Invoke Add-Type -ModuleName PwshMusicTools -Times 1 -Exactly
    }
}

Describe 'Get-EmbeddedPicture with real files' -Skip:(-not ($tagLibCached -and $ffmpegAvailable)) {

    BeforeEach {
        $script:realDir = New-TestDir
        $plain = Join-Path $realDir 'plain.mp3'
        $script:pngFile = New-TestImage -Dir $realDir -Name 'cover.png' -Width 300 -Height 300
        $script:tagged = Join-Path $realDir 'tagged.mp3'
        & ffmpeg -v error -nostdin -f lavfi -i 'sine=frequency=440:duration=1' -c:a libmp3lame $plain 2>&1 | Out-Null
        & ffmpeg -v error -nostdin -i $plain -i $pngFile -map 0 -map 1 -c copy -id3v2_version 3 `
            -metadata:s:v comment='Cover (front)' $tagged 2>&1 | Out-Null
    }

    AfterEach {
        Remove-TestDir -Path $script:realDir
    }

    It 'returns the embedded front cover with its bytes' {
        $pics = InModuleScope PwshMusicTools -Parameters @{ Path = $script:tagged } {
            param($Path)
            Import-TagLibSharp
            @(Get-EmbeddedPicture -LiteralPath $Path -IncludeData)
        }

        @($pics).Count | Should -Be 1
        $pics[0].Type | Should -Be 'FrontCover'
        [byte[]]$pics[0].Data | Should -Be ([System.IO.File]::ReadAllBytes($script:pngFile))
    }
}
