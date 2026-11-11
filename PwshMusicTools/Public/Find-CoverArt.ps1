function Find-CoverArt {
    <#
    .SYNOPSIS
        Finds the cover art image in every music folder of a directory tree,
        optionally copies it to the expected name (folder.jpg by default), and
        can export a CSV report.

    .DESCRIPTION
        Walks the tree under -Path, including -Path itself. Every folder that
        directly holds at least one audio file (the same extensions
        Sync-LyricFiles uses: .mp3, .flac, .opus, .ogg, .m4a, ...) is expected
        to have a cover and gets one result row. Folders without audio files are
        not reported. Junctions and symbolic links below -Path are not followed.
        Hidden and system files are included.

        Image extensions, most preferred first: .jpg, .jpeg, .png, then .webp,
        .gif, .bmp, .tif, .tiff. Names and extensions are compared
        case-insensitively. The cover is the first hit of:
          1. the expected name (-ExpectedCoverName, e.g. folder.jpg / folder.png);
          2. a known cover name, in this order: cover, front, folder (when it is
             not the expected name), albumart, album, art, thumb, albumartsmall;
          3. any image whose base name contains 'cover' or 'front', unless it
             also contains 'back', 'cd', 'disc', 'inlay' or 'tray';
          4. the only image in the folder, whatever its name, when the folder
             holds exactly one image that is neither hidden nor system.
        Within each step .jpg/.jpeg wins over .png, which wins over the others.

        -PreferLargest: instead of the first hit of steps 2-4, the candidate
        with the largest pixel area (width x height) among all hits of steps
        2-4 is used. Ties keep the order above; unreadable images rank last.
        A file with the expected name is still always used, but when another
        candidate has at least 10% more pixels, Comment gets the note
        'Larger candidate: <name> <width>x<height>'. The expected file is never
        changed.

        Disc folders: a music folder with no cover of its own whose name looks
        like a disc of a multi-disc album (CD1, CD 01, Disc 2, Disk_3, cd.2,
        'Disc 1 - Live'; not CDs, Discography, CD, 'Disc Two' or 'Bonus CD1')
        uses the cover of its parent folder, found with the same rules. Only
        the direct parent is checked. Such rows have Method 'Parent' and
        Comment 'Using parent folder cover'. -CopyParentToDisc copies that
        cover into the disc folder as <ExpectedCoverName><its extension>.

        -CopyToExpected: when no file with the expected base name exists but
        another cover was found in steps 2-4, that file is copied (never moved or
        renamed; the original stays) to <ExpectedCoverName><its extension> in
        the same folder, e.g. cover.jpg is copied to folder.jpg and front.png to
        folder.png. Existing files are never overwritten: if any file with the
        expected base name already exists (any extension, any case), nothing is
        copied. All copies (including -CopyParentToDisc copies) are confirmed
        once for the whole run. Copies destroy nothing, so there is no prompt by
        default; use -Confirm to be asked. Under -WhatIf nothing is copied and
        Comment says what would be copied.

        Image details are read from the file header only (no pixels are
        decoded; for TIFF only the first image directory is read), so scanning
        a large collection stays fast. .jpg and .jpeg are the same format, as
        are .tif and .tiff.

        Each result row has, in this order:
          Directory       the music folder.
          CoverPresent    True if the folder has a cover after the run (the
                          expected name exists, another cover was found, or
                          the parent folder cover is used).
          CoverPath       full path of the cover in use: the expected-name file
                          if present or just copied, otherwise the cover found,
                          otherwise the parent folder cover, otherwise empty.
          Comment         e.g. 'Copied from cover.jpg', 'WhatIf: would copy from
                          cover.jpg to folder.jpg', 'Expected name missing; found
                          cover.jpg', 'Using parent folder cover', 'No cover
                          found', or why a copy failed. Notes such as
                          'Unreadable image: <reason>' and 'Larger candidate:
                          ...' are appended with '; '.
          MatchedName     file name of the image that was found, or empty.
          Method          how it was found: Expected, KnownName, NameContains,
                          OnlyImage, Parent, Embedded or None.
          CoverWidth      cover width in pixels; empty if unreadable or no cover.
          CoverHeight     cover height in pixels; empty if unreadable or no cover.
          CoverSizeKB     cover file size in KB (1 KB = 1024 bytes), 1 decimal.
          DetectedFormat  format found in the file header: JPEG, PNG, GIF, BMP,
                          WebP, TIFF, or empty if unknown.
          LowResolution   True when the shorter side is below -MinimumSize.
          NonSquare       True when width and height differ by more than 5% of
                          the longer side (fixed tolerance).
          FormatMismatch  True when the detected format does not match the file
                          extension (e.g. a PNG named folder.jpg).
          Unreadable      True when the cover header could not be read; the
                          reason is added to Comment.
          OtherImages     every other image in the folder at scan time with its
                          size, e.g. 'back.jpg (1000x1000); scan.jpg
                          (unreadable)'. For a Parent row all images of the disc
                          folder are listed. Filled even when there is no cover.
          EmbeddedArt     with -CheckEmbedded or -ExtractEmbedded: how many of the
                          folder's audio files have embedded artwork: None,
                          Some (n/m) or All. Empty otherwise.

        Embedded artwork (-CheckEmbedded, -ExtractEmbedded) is read with
        TagLib#, which is downloaded once on first use. -ExtractEmbedded
        writes the embedded front cover of a folder that has no image file
        as <ExpectedCoverName><ext>; such rows have Method 'Embedded' and
        MatchedName is the audio file the art came from. Extractions are part
        of the same single confirmation as copies.

        -ExportReportPath writes the rows as a UTF-8 CSV. The path is checked
        before anything is scanned or copied (its folder must exist and the file
        must be writable). The CSV is written even under -WhatIf, and also if the
        run is interrupted, with the rows gathered so far.

        The rows are also returned to the pipeline.

        Progress: while scanning, a progress bar (no percentage) shows the
        folder currently being checked, for every folder walked, with a running
        count such as 'Checked 1,234 folders, 87 without cover'. While copying
        or extracting it shows the file being written. It is cleared when the
        run ends, also if it fails or is interrupted. To hide it, set
        $ProgressPreference = 'SilentlyContinue' or pass
        -ProgressAction SilentlyContinue (PowerShell 7.4+).

    .PARAMETER Path
        Root of the tree to scan. Accepts pipeline input, including directory
        objects from Get-Item/Get-ChildItem; all piped folders form one run with
        one confirmation and one report.

    .PARAMETER ExpectedCoverName
        Base name (no extension) of the cover file each music folder should
        have. Default 'folder', which matches folder.jpg, folder.png, etc.
        Case-insensitive.

    .PARAMETER CopyToExpected
        Copy a found cover to the expected name when no expected-named file
        exists. The source file is kept and nothing is overwritten.

    .PARAMETER ExportReportPath
        Path of a CSV report to write. Overwritten if it exists.

    .PARAMETER MinimumSize
        Minimum length in pixels of the cover's shorter side. Covers below it
        get LowResolution True. Default 500; 0 disables the check.

    .PARAMETER PreferLargest
        Use the candidate with the largest pixel area instead of the first by
        name, and note a noticeably larger candidate next to an expected-named
        file. See the description.

    .PARAMETER CopyParentToDisc
        For disc folders (CD1, Disc 2, ...) that use their parent folder's
        cover, copy that cover into the disc folder as
        <ExpectedCoverName><its extension>. Nothing is overwritten.

    .PARAMETER CheckEmbedded
        Opt-in. Reads every audio file of each music folder with TagLib# (may
        trigger the one-time TagLib# download) and fills EmbeddedArt with None,
        Some (n/m) or All. Tracks whose tags cannot be read count as having no
        art and are named in Comment ('Embedded art unreadable: ...').

    .PARAMETER ExtractEmbedded
        Implies -CheckEmbedded. For folders with no image file of any supported
        extension and no parent folder cover in use, writes the embedded
        artwork as <ExpectedCoverName><ext>: the FrontCover picture of the
        first track (by name) that has one, else the first picture of the
        first track with any picture. The extension comes from the image bytes,
        else from the MIME type; art of unknown format is not extracted.
        Existing files are never overwritten (any file with the expected base
        name blocks it). Confirmed together with the copies in one prompt;
        under -WhatIf nothing is written.

    .EXAMPLE
        Find-CoverArt -Path 'D:\Music' -ExportReportPath 'C:\Temp\covers.csv'

        Reports the cover of every music folder under D:\Music without changing
        anything, and writes the report to C:\Temp\covers.csv.

    .EXAMPLE
        Find-CoverArt -Path 'D:\Music' -CopyToExpected -WhatIf |
            Where-Object Comment -like 'WhatIf:*'

        Lists the folders where a cover such as cover.jpg would be copied to
        folder.jpg. Nothing is copied.

    .EXAMPLE
        Find-CoverArt -Path 'D:\Music' -ExpectedCoverName 'cover' -CopyToExpected |
            Where-Object { -not $_.CoverPresent }

        Makes sure each music folder has a cover.* file, copying folder.jpg,
        front.jpg, etc. where it is missing, then lists the folders that still
        have no cover at all.

    .EXAMPLE
        Find-CoverArt -Path 'D:\Music' -PreferLargest -MinimumSize 600 |
            Where-Object { $_.LowResolution -or $_.Comment -like '*Larger candidate*' }

        Picks the largest candidate image per folder and lists the folders whose
        cover is smaller than 600 pixels or that have a larger image than the
        folder.jpg in use.

    .EXAMPLE
        Find-CoverArt -Path 'D:\Music\Box Set' -CopyParentToDisc -WhatIf

        Shows which disc folders (CD1, CD2, ...) would get a copy of the box
        set's cover. Nothing is copied.

    .EXAMPLE
        Find-CoverArt -Path 'D:\Music' -CheckEmbedded -ExtractEmbedded -WhatIf |
            Where-Object EmbeddedArt -ne 'All'

        Reports how many tracks of each music folder carry embedded artwork,
        shows which folders without an image file would get folder.jpg (or
        .png) extracted from it, and lists the folders where not every track
        has embedded art. Nothing is written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ExpectedCoverName = 'folder',

        [Parameter(Mandatory = $false)]
        [switch]$CopyToExpected,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ExportReportPath,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$MinimumSize = 500,

        [Parameter(Mandatory = $false)]
        [switch]$PreferLargest,

        [Parameter(Mandatory = $false)]
        [switch]$CopyParentToDisc,

        [Parameter(Mandatory = $false)]
        [switch]$CheckEmbedded,

        [Parameter(Mandatory = $false)]
        [switch]$ExtractEmbedded
    )

    begin {
        Set-StrictMode -Version Latest

        $ExpectedCoverName = $ExpectedCoverName.Trim()
        if (-not $ExpectedCoverName -or $ExpectedCoverName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "-ExpectedCoverName '$ExpectedCoverName' is not a valid file base name."
        }

        # Checked before anything is scanned or copied (Private\ReportPath.ps1).
        $csvFull = $null
        if ($PSBoundParameters.ContainsKey('ExportReportPath')) {
            $csvFull = Get-WritableReportPath -Value $ExportReportPath -Name 'ExportReportPath'
        }

        # Embedded artwork is read with TagLib# (Private\TagLib.ps1), loaded once.
        $readEmbedded = $CheckEmbedded -or $ExtractEmbedded
        if ($readEmbedded) { Import-TagLibSharp }

        # Shared with Sync-LyricFiles (Private\AudioExtensions.ps1).
        $audioExts = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@(Get-AudioExtension), [StringComparer]::OrdinalIgnoreCase)

        # Image extensions, most preferred first; the index is the rank.
        $imageExts = @('.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.tif', '.tiff')
        $knownNames = @('cover', 'front', 'folder', 'albumart', 'album', 'art', 'thumb', 'albumartsmall') |
            Where-Object { $_ -ne $ExpectedCoverName }
        $excludeWords = @('back', 'cd', 'disc', 'inlay', 'tray')

        $roots = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($p in $Path) { $roots.Add($p) }
    }

    end {
        $extRank = { param($f) [array]::IndexOf($imageExts, $f.Extension.ToLowerInvariant()) }
        # Images in preference order: preferred extension, then shortest/alphabetical name.
        $sortImages = {
            param([object[]]$Images)
            @($Images | Sort-Object @{ Expression = { & $extRank $_ } }, @{ Expression = { $_.Name.Length } }, Name)
        }
        # Best of a set of images.
        $pickBest = {
            param([object[]]$Images)
            @(& $sortImages $Images)[0]
        }

        $rows     = [System.Collections.Generic.List[object]]::new()
        $rowNotes = [System.Collections.Generic.List[object]]::new()
        $writes   = [System.Collections.Generic.List[object]]::new()
        $seen     = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $infoCache    = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        $parentCovers = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        $copiedCount = 0
        $extractedCount = 0
        # Progress counters: folders walked so far, music folders without a cover.
        # A hashtable, so the nested $walk scopes update the same counters.
        $progress = @{ Checked = 0; Missing = 0 }

        # Header info of an image file (Private\ImageInfo.ps1), read once per file.
        $getInfo = {
            param($File)
            $key = $File.FullName
            if (-not $infoCache.ContainsKey($key)) { $infoCache[$key] = Get-ImageInfo -LiteralPath $key }
            $infoCache[$key]
        }
        # Pixel area; unreadable images count as 0.
        $area = { param($Info) if ($Info.Error) { 0 } else { [long]$Info.Width * $Info.Height } }

        # Fills the image columns of a row from a cover's header info.
        $setImage = {
            param($Row, $Entry, $Info, [long]$Length, [string]$Extension, [string]$Name)
            $Row.CoverSizeKB    = [Math]::Round($Length / 1024, 1)
            $Row.DetectedFormat = $Info.DetectedFormat
            $Row.Unreadable     = [bool]$Info.Error
            $Row.FormatMismatch = [bool]($Info.DetectedFormat -and $Info.DetectedFormat -ne (Get-ImageFormatFromExtension -Extension $Extension))
            if ($Info.Error) {
                $Row.CoverWidth    = $null
                $Row.CoverHeight   = $null
                $Row.LowResolution = $null
                $Row.NonSquare     = $null
                $Entry.Notes.Add("Unreadable image: $($Info.Error)")
            }
            else {
                $w = [int]$Info.Width
                $h = [int]$Info.Height
                $Row.CoverWidth    = $w
                $Row.CoverHeight   = $h
                $Row.LowResolution = ($MinimumSize -gt 0 -and [Math]::Min($w, $h) -lt $MinimumSize)
                $Row.NonSquare     = (([Math]::Abs($w - $h) / [double][Math]::Max($w, $h)) -gt 0.05)
            }
        }
        # Resets the image columns to blank.
        $clearImage = {
            param($Row)
            $Row.CoverWidth     = $null
            $Row.CoverHeight    = $null
            $Row.CoverSizeKB    = $null
            $Row.DetectedFormat = ''
            $Row.LowResolution  = $null
            $Row.NonSquare      = $null
            $Row.FormatMismatch = $null
            $Row.Unreadable     = $null
        }
        # An extraction that was declined or failed: no file, so blank the
        # image columns and drop the notes that described it.
        $dropExtract = {
            param($Write)
            & $clearImage $Write.Row
            foreach ($note in $Write.ImageNotes) { [void]$Write.Notes.Remove($note) }
        }

        # Cover candidates of one folder's files:
        #   Images     all files with an image extension;
        #   Expected   best file with the expected base name, or $null;
        #   Candidates hits of steps 2-4 in order, de-duplicated, each
        #              { File; Method; Info; Index };
        #   Chosen     the candidate to use without an expected file, or $null.
        $findCover = {
            param([object[]]$Files)

            $images = @($Files | Where-Object { (& $extRank $_) -ge 0 })

            $expected = $null
            $hits = @($images | Where-Object { $_.BaseName -eq $ExpectedCoverName })
            if ($hits.Count) { $expected = & $pickBest $hits }

            $cands = [System.Collections.Generic.List[object]]::new()
            $added = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $addCandidate = {
                param($File, [string]$Method)
                if ($added.Add($File.FullName)) {
                    $cands.Add([PSCustomObject]@{
                        File   = $File
                        Method = $Method
                        Info   = (& $getInfo $File)
                        Index  = $cands.Count
                    })
                }
            }

            # 2. Known names, in order.
            foreach ($name in $knownNames) {
                $hits = @($images | Where-Object { $_.BaseName -eq $name })
                if ($hits.Count) {
                    foreach ($f in @(& $sortImages $hits)) { & $addCandidate $f 'KnownName' }
                }
            }

            # 3. Name contains 'cover' or 'front', but not back/cd/disc/inlay/tray.
            $hits = @($images | Where-Object {
                $b = $_.BaseName.ToLowerInvariant()
                ($b.Contains('cover') -or $b.Contains('front')) -and
                    -not @($excludeWords | Where-Object { $b.Contains($_) }).Count
            })
            if ($hits.Count) {
                foreach ($f in @(& $sortImages $hits)) { & $addCandidate $f 'NameContains' }
            }

            # 4. The only (visible, non-system) image in the folder.
            $hiddenOrSystem = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
            $visible = @($images | Where-Object { -not ($_.Attributes -band $hiddenOrSystem) })
            if ($visible.Count -eq 1) { & $addCandidate $visible[0] 'OnlyImage' }

            $chosen = $null
            if ($cands.Count) {
                if ($PreferLargest) {
                    # Readable first, then largest area, then the order above.
                    $chosen = @($cands | Sort-Object @{ Expression = { [bool]$_.Info.Error } },
                        @{ Expression = { & $area $_.Info }; Descending = $true }, Index)[0]
                }
                else {
                    $chosen = $cands[0]
                }
            }

            [PSCustomObject]@{
                Images     = $images
                Expected   = $expected
                Candidates = [object[]]$cands.ToArray()
                Chosen     = $chosen
            }
        }

        # Cover file of a disc folder's parent (Expected, else Chosen), or $null.
        # Cached per parent; a parent that cannot be read has no cover.
        $getParentCover = {
            param([string]$Parent)
            if (-not $parentCovers.ContainsKey($Parent)) {
                $cover = $null
                try {
                    $parentFiles = @(Get-ChildItem -LiteralPath $Parent -File -Force -ErrorAction Stop | Sort-Object Name)
                    $pr = & $findCover $parentFiles
                    if ($pr.Expected) { $cover = $pr.Expected }
                    elseif ($pr.Chosen) { $cover = $pr.Chosen.File }
                }
                catch {
                    Write-Warning "Find-CoverArt: cannot read '$Parent': $($_.Exception.Message)"
                }
                $parentCovers[$Parent] = $cover
            }
            $parentCovers[$Parent]
        }

        # Decides the cover of one folder and adds its row (and planned writes).
        $examine = {
            param([string]$Dir, [object[]]$Files)

            $r = & $findCover $Files
            $row = [PSCustomObject][ordered]@{
                Directory      = $Dir
                CoverPresent   = $false
                CoverPath      = ''
                Comment        = 'No cover found'
                MatchedName    = ''
                Method         = 'None'
                CoverWidth     = $null
                CoverHeight    = $null
                CoverSizeKB    = $null
                DetectedFormat = ''
                LowResolution  = $null
                NonSquare      = $null
                FormatMismatch = $null
                Unreadable     = $null
                OtherImages    = ''
                EmbeddedArt    = ''
            }
            $rows.Add($row)
            $entry = [PSCustomObject]@{ Row = $row; Notes = [System.Collections.Generic.List[string]]::new() }
            $rowNotes.Add($entry)

            # The cover file in this folder that is in use ('' if none).
            $coverSource = ''

            if ($r.Expected) {
                # 1. Expected name.
                $found = $r.Expected
                $info = & $getInfo $found
                $row.CoverPresent = $true
                $row.CoverPath    = $found.FullName
                $row.Comment      = ''
                $row.MatchedName  = $found.Name
                $row.Method       = 'Expected'
                & $setImage $row $entry $info $found.Length $found.Extension $found.Name
                $coverSource = $found.FullName

                if ($PreferLargest) {
                    $big = @($r.Candidates |
                        Where-Object { -not $_.Info.Error -and $_.File.FullName -ne $found.FullName } |
                        Sort-Object @{ Expression = { & $area $_.Info }; Descending = $true }, Index)
                    if ($big.Count -and (& $area $big[0].Info) -ge 1.1 * (& $area $info)) {
                        $entry.Notes.Add("Larger candidate: $($big[0].File.Name) $($big[0].Info.Width)x$($big[0].Info.Height)")
                    }
                }
            }
            elseif ($r.Chosen) {
                # 2-4. Another cover.
                $found = $r.Chosen.File
                $row.CoverPresent = $true
                $row.CoverPath    = $found.FullName
                $row.MatchedName  = $found.Name
                $row.Method       = $r.Chosen.Method
                $row.Comment      = "Expected name missing; found $($found.Name)"
                & $setImage $row $entry $r.Chosen.Info $found.Length $found.Extension $found.Name
                $coverSource = $found.FullName

                if ($CopyToExpected) {
                    $targetName = $ExpectedCoverName + $found.Extension
                    # Any file with the expected base name (any extension or case)
                    # blocks the copy, so nothing is ever overwritten.
                    $blocker = @($Files | Where-Object { $_.BaseName -eq $ExpectedCoverName -or $_.Name -eq $targetName })
                    if ($blocker.Count) {
                        $row.Comment = "Not copied: $($blocker[0].Name) already exists; found $($found.Name)"
                    }
                    else {
                        $writes.Add([PSCustomObject]@{
                            Row             = $row
                            Kind            = 'Copy'
                            Source          = $found.FullName
                            Destination     = Join-Path $Dir $targetName
                            TargetName      = $targetName
                            PromptLine      = "$($found.FullName) -> $targetName"
                            DoneComment     = "Copied from $($found.Name)"
                            WhatIfComment   = "WhatIf: would copy from $($found.Name) to $targetName"
                            DeclinedComment = "Copy declined; found $($found.Name)"
                            PendingComment  = "Not processed (interrupted); found $($found.Name)"
                            FailPrefix      = 'Copy failed: '
                            FailSuffix      = "; found $($found.Name)"
                        })
                    }
                }
            }
            elseif (Test-DiscFolderName -Name (Split-Path -Path $Dir -Leaf)) {
                # Disc folder: use the parent folder's cover (one level up only).
                $parent = Split-Path -Path $Dir -Parent
                $pc = $null
                if ($parent) { $pc = & $getParentCover $parent }
                if ($pc) {
                    $row.CoverPresent = $true
                    $row.CoverPath    = $pc.FullName
                    $row.MatchedName  = $pc.Name
                    $row.Method       = 'Parent'
                    $row.Comment      = 'Using parent folder cover'
                    & $setImage $row $entry (& $getInfo $pc) $pc.Length $pc.Extension $pc.Name

                    if ($CopyParentToDisc) {
                        $targetName = $ExpectedCoverName + $pc.Extension
                        $blocker = @($Files | Where-Object { $_.BaseName -eq $ExpectedCoverName -or $_.Name -eq $targetName })
                        if ($blocker.Count) {
                            $row.Comment = "Not copied: $($blocker[0].Name) already exists; using parent folder cover"
                        }
                        else {
                            $destination = Join-Path $Dir $targetName
                            $writes.Add([PSCustomObject]@{
                                Row             = $row
                                Kind            = 'ParentCopy'
                                Source          = $pc.FullName
                                Destination     = $destination
                                TargetName      = $targetName
                                PromptLine      = "$($pc.FullName) -> $destination"
                                DoneComment     = "Copied from parent folder ($($pc.Name))"
                                WhatIfComment   = "WhatIf: would copy parent folder cover $($pc.Name) to $targetName"
                                DeclinedComment = 'Copy declined; using parent folder cover'
                                PendingComment  = 'Not processed (interrupted); using parent folder cover'
                                FailPrefix      = 'Copy failed: '
                                FailSuffix      = '; using parent folder cover'
                            })
                        }
                    }
                }
            }

            if ($readEmbedded) {
                # Embedded artwork in the folder's audio files (name order).
                $audio = @($Files | Where-Object { $audioExts.Contains($_.Extension) })
                # Extraction only where the folder has no image file at all and
                # no parent cover is in use. Tracks are listed without picture
                # bytes; only the chosen picture's bytes are read (see below).
                $eligible = [bool]($ExtractEmbedded -and @($r.Images).Count -eq 0 -and -not $row.CoverPresent)
                $failed = [System.Collections.Generic.List[string]]::new()
                $trackPics = [System.Collections.Generic.List[object]]::new()
                $n = 0
                foreach ($t in $audio) {
                    try { $pics = @(Get-EmbeddedPicture -LiteralPath $t.FullName) }
                    catch { $failed.Add($t.Name); $pics = @() }
                    if ($pics.Count -gt 0) {
                        $n++
                        if ($eligible) { $trackPics.Add([PSCustomObject]@{ Track = $t; Pictures = $pics }) }
                    }
                }
                $row.EmbeddedArt = if ($n -eq 0) { 'None' } elseif ($n -eq $audio.Count) { 'All' } else { "Some ($n/$($audio.Count))" }
                if ($failed.Count) { $entry.Notes.Add("Embedded art unreadable: $($failed -join ', ')") }

                if ($eligible -and $trackPics.Count) {
                    # FrontCover from the first track that has one, else the first
                    # picture of the first track with any picture.
                    $track = $null
                    $picIndex = -1
                    foreach ($tp in $trackPics) {
                        for ($i = 0; $i -lt $tp.Pictures.Count; $i++) {
                            if ($tp.Pictures[$i].Type -eq 'FrontCover') { $picIndex = $i; break }
                        }
                        if ($picIndex -ge 0) { $track = $tp.Track; break }
                    }
                    if ($picIndex -lt 0) { $track = $trackPics[0].Track; $picIndex = 0 }
                    $pic = @($trackPics | Where-Object { $_.Track -eq $track })[0].Pictures[$picIndex]

                    # Bytes of the chosen picture only. They are used here for the
                    # image columns and extension, then dropped; the write re-reads
                    # them, so no picture data is held until the confirmation.
                    $bytes = [byte[]]::new(0)
                    try {
                        $full = @(Get-EmbeddedPicture -LiteralPath $track.FullName -IncludeData)
                        if ($picIndex -lt $full.Count -and $null -ne $full[$picIndex].Data) { $bytes = [byte[]]$full[$picIndex].Data }
                    }
                    catch { }
                    $full = $null
                    $info = Get-ImageInfo -Bytes $bytes
                    # Extension from the image bytes, else from the MIME type.
                    $ext = Get-ImageExtensionFromFormat -Format $info.DetectedFormat
                    if (-not $ext) { $ext = Get-ImageExtensionFromMimeType -MimeType ([string]$pic.MimeType) }
                    if (-not $ext) {
                        $entry.Notes.Add("Not extracted: unknown image format in $($track.Name)")
                    }
                    else {
                        $targetName = $ExpectedCoverName + $ext
                        $blocker = @($Files | Where-Object { $_.BaseName -eq $ExpectedCoverName -or $_.Name -eq $targetName })
                        if ($blocker.Count) {
                            $row.Comment = "Not extracted: $($blocker[0].Name) already exists"
                        }
                        else {
                            $destination = Join-Path $Dir $targetName
                            # CoverPresent/CoverPath are set only once the file is written.
                            $row.Method      = 'Embedded'
                            $row.MatchedName = $track.Name
                            # Notes queued by $setImage describe the extracted file;
                            # they are dropped again if it is never written.
                            $noteStart = $entry.Notes.Count
                            & $setImage $row $entry $info $bytes.Length $ext $targetName
                            $imageNotes = @($entry.Notes | Select-Object -Skip $noteStart)
                            $bytes = $null
                            $writes.Add([PSCustomObject]@{
                                Row             = $row
                                Kind            = 'Extract'
                                Source          = $track.FullName
                                PictureIndex    = $picIndex
                                Notes           = $entry.Notes
                                ImageNotes      = $imageNotes
                                Destination     = $destination
                                TargetName      = $targetName
                                PromptLine      = "embedded art in $($track.FullName) -> $destination"
                                DoneComment     = "Extracted from $($track.Name)"
                                WhatIfComment   = "WhatIf: would extract from $($track.Name) to $targetName"
                                DeclinedComment = "Extraction declined; embedded art in $($track.Name)"
                                PendingComment  = "Not processed (interrupted); embedded art in $($track.Name)"
                                FailPrefix      = 'Extraction failed: '
                                FailSuffix      = "; embedded art in $($track.Name)"
                            })
                        }
                    }
                }
            }

            # Every other image in this folder, in name order, with its size.
            $row.OtherImages = (@($r.Images | Where-Object { $_.FullName -ne $coverSource } | ForEach-Object {
                $i = & $getInfo $_
                if ($i.Error) { "$($_.Name) (unreadable)" } else { "$($_.Name) ($($i.Width)x$($i.Height))" }
            }) -join '; ')
        }

        # Pre-order walk: a folder is reported before its sub-folders.
        $walk = {
            param([string]$Dir)
            if (-not $seen.Add($Dir)) { return }
            # Every folder walked, with or without audio (no percentage: the
            # total is not known in advance).
            Write-Progress -Activity 'Find-CoverArt' -Status $Dir `
                -CurrentOperation ('Checked {0:N0} folders, {1:N0} without cover' -f $progress.Checked, $progress.Missing)
            $progress.Checked++
            try {
                $children = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Stop | Sort-Object Name)
            }
            catch {
                Write-Warning "Find-CoverArt: cannot read '$Dir': $($_.Exception.Message)"
                return
            }
            $files = @($children | Where-Object { -not $_.PSIsContainer })
            if (@($files | Where-Object { $audioExts.Contains($_.Extension) }).Count) {
                & $examine $Dir $files
                if (-not $rows[$rows.Count - 1].CoverPresent) { $progress.Missing++ }
            }
            foreach ($sub in @($children | Where-Object { $_.PSIsContainer })) {
                # Junctions/symlinks are never followed.
                if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                & $walk $sub.FullName
            }
        }

        try {
            # --- Scan --------------------------------------------------------------
            foreach ($root in $roots) {
                if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                    Write-Error "Path '$root' is not a valid directory."
                    continue
                }
                & $walk (Get-Item -LiteralPath $root -Force).FullName
            }

            # --- Write (confirmed once for the whole run) --------------------------
            # Until a write is handled its row says so, so an interrupted run never
            # reports an unwritten cover as written.
            foreach ($w in $writes) { $w.Row.Comment = $w.PendingComment }

            if ($writes.Count -gt 0) {
                $target = "$($writes.Count) cover file(s):`n  " +
                    # Scriptblock, not 'ForEach-Object PromptLine': the -MemberName
                    # form honors -WhatIf/-Confirm itself and would drop the lines.
                    (($writes | ForEach-Object { $_.PromptLine }) -join "`n  ")
                $action = if (@($writes | Where-Object Kind -ne 'Copy').Count) { 'Write cover art' } else { 'Copy cover art to expected name' }
                if (Confirm-ShouldProcess -Cmdlet $PSCmdlet -Target $target -Action $action) {
                    $written = 0
                    foreach ($w in $writes) {
                        Write-Progress -Activity 'Find-CoverArt' -Status $w.Destination `
                            -CurrentOperation ('Writing cover file {0:N0} of {1:N0}' -f (++$written), $writes.Count)
                        try {
                            switch ($w.Kind) {
                                'Extract' {
                                    # The picture bytes are read again here rather
                                    # than kept in memory since the scan.
                                    $pics = @(Get-EmbeddedPicture -LiteralPath $w.Source -IncludeData)
                                    if ($w.PictureIndex -ge $pics.Count -or $null -eq $pics[$w.PictureIndex].Data) {
                                        throw "embedded picture no longer found in $(Split-Path -Path $w.Source -Leaf)"
                                    }
                                    $data = [byte[]]$pics[$w.PictureIndex].Data
                                    $pics = $null
                                    # CreateNew: fails rather than replacing a file
                                    # that appeared since the scan.
                                    $fs = [System.IO.FileStream]::new($w.Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
                                    try { $fs.Write($data, 0, $data.Length) }
                                    finally { $fs.Dispose(); $data = $null }
                                    $w.Row.CoverPresent = $true
                                    $extractedCount++
                                }
                                default {
                                    # overwrite = $false: fails rather than replacing a
                                    # file that appeared since the scan.
                                    [System.IO.File]::Copy($w.Source, $w.Destination, $false)
                                    $copiedCount++
                                }
                            }
                            # The image columns already describe the source, which
                            # has identical bytes.
                            $w.Row.CoverPath = $w.Destination
                            $w.Row.Comment   = $w.DoneComment
                        }
                        catch {
                            Write-Warning "Find-CoverArt: failed to write '$($w.Destination)': $($_.Exception.Message)"
                            # A failed extraction leaves no cover to describe.
                            if ($w.Kind -eq 'Extract') { & $dropExtract $w }
                            $w.Row.Comment = $w.FailPrefix + $_.Exception.Message + $w.FailSuffix
                        }
                    }
                }
                elseif ($WhatIfPreference) {
                    foreach ($w in $writes) { $w.Row.Comment = $w.WhatIfComment }
                }
                else {
                    foreach ($w in $writes) {
                        if ($w.Kind -eq 'Extract') { & $dropExtract $w }
                        $w.Row.Comment = $w.DeclinedComment
                    }
                }
            }
        }
        finally {
            # Cleared here so a failed or interrupted run leaves no stuck bar.
            Write-Progress -Activity 'Find-CoverArt' -Completed

            # Append notes (unreadable image, larger candidate) to the Comment.
            foreach ($e in $rowNotes) {
                if ($e.Notes.Count) {
                    $e.Row.Comment = (@(@($e.Row.Comment) + @($e.Notes) | Where-Object { $_ }) -join '; ')
                }
            }

            # --- Report ------------------------------------------------------------
            # Written in 'finally' so an interrupted run still leaves a report.
            # Also written under -WhatIf.
            if ($csvFull) {
                $rows | Export-Csv -LiteralPath $csvFull -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false
            }
        }

        $withCover = @($rows | Where-Object CoverPresent).Count
        $extracted = if ($ExtractEmbedded) { "; extracted $extractedCount" } else { '' }
        Write-Host ("Find-CoverArt: {0} of {1} music folder(s) have a cover; copied {2}{3}." -f $withCover, $rows.Count, $copiedCount, $extracted) -ForegroundColor $(if ($withCover -eq $rows.Count) { 'Green' } else { 'Yellow' })

        # Typed array rather than a unary comma, so @() callers don't get a nested array.
        return [object[]]$rows.ToArray()
    }
}
