BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Get-ImageInfo' {
    Context 'Dimensions from -Bytes' {
        It 'reads <Format> <Width>x<Height> as <Expected>' -TestCases @(
            @{ Format = 'JPEG';            Width = 1200; Height = 800;  Expected = 'JPEG' }
            @{ Format = 'JPEGProgressive'; Width = 1024; Height = 768;  Expected = 'JPEG' }
            @{ Format = 'PNG';             Width = 640;  Height = 480;  Expected = 'PNG' }
            @{ Format = 'GIF';             Width = 320;  Height = 200;  Expected = 'GIF' }
            @{ Format = 'BMP';             Width = 300;  Height = 150;  Expected = 'BMP' }
            @{ Format = 'BMPTopDown';      Width = 300;  Height = 150;  Expected = 'BMP' }
            @{ Format = 'WebPVP8';         Width = 400;  Height = 300;  Expected = 'WebP' }
            @{ Format = 'WebPVP8L';        Width = 1000; Height = 999;  Expected = 'WebP' }
            @{ Format = 'WebPVP8X';        Width = 5000; Height = 4000; Expected = 'WebP' }
            @{ Format = 'TIFFLE';          Width = 700;  Height = 500;  Expected = 'TIFF' }
            @{ Format = 'TIFFBE';          Width = 700;  Height = 500;  Expected = 'TIFF' }
        ) {
            $bytes = [byte[]](New-TestImageBytes -Format $Format -Width $Width -Height $Height)
            $info = InModuleScope PwshMusicTools -Parameters @{ Bytes = $bytes } {
                param($Bytes)
                Get-ImageInfo -Bytes $Bytes
            }
            $info.Error | Should -Be ''
            $info.DetectedFormat | Should -Be $Expected
            $info.Width | Should -Be $Width
            $info.Height | Should -Be $Height
        }

        It 'skips an EXIF APP1 segment instead of reading its embedded thumbnail' {
            $bytes = [byte[]](New-TestImageBytes -Format JPEGExif -Width 1400 -Height 1400)
            $info = InModuleScope PwshMusicTools -Parameters @{ Bytes = $bytes } {
                param($Bytes)
                Get-ImageInfo -Bytes $Bytes
            }
            $info.Error | Should -Be ''
            $info.Width | Should -Be 1400
            $info.Height | Should -Be 1400
        }
    }

    Context 'Files and bad input' {
        BeforeEach { $dir = New-TestDir }
        AfterEach { Remove-TestDir $dir }

        It 'returns the same result from -LiteralPath as from -Bytes' {
            $bytes = [byte[]](New-TestImageBytes -Format PNG -Width 640 -Height 480 -PadTo 5000)
            $path = New-TestImage -Dir $dir -Name 'folder.png' -Width 640 -Height 480 -PadTo 5000
            (Get-Item -LiteralPath $path).Length | Should -Be 5000
            $result = InModuleScope PwshMusicTools -Parameters @{ Bytes = $bytes; Path = $path } {
                param($Bytes, $Path)
                [PSCustomObject]@{
                    FromBytes = Get-ImageInfo -Bytes $Bytes
                    FromPath  = Get-ImageInfo -LiteralPath $Path
                }
            }
            $result.FromPath.Error | Should -Be ''
            $result.FromPath.DetectedFormat | Should -Be 'PNG'
            $result.FromPath.Width | Should -Be $result.FromBytes.Width
            $result.FromPath.Height | Should -Be $result.FromBytes.Height
            $result.FromPath.Width | Should -Be 640
            $result.FromPath.Height | Should -Be 480
        }

        It 'reports an empty file' {
            $path = New-EmptyFile -Dir $dir -Name 'empty.jpg'
            $info = InModuleScope PwshMusicTools -Parameters @{ Path = $path } {
                param($Path)
                Get-ImageInfo -LiteralPath $Path
            }
            $info.Error | Should -Be 'Empty file'
            $info.DetectedFormat | Should -Be ''
        }

        It 'reports an empty byte array' {
            $info = InModuleScope PwshMusicTools {
                Get-ImageInfo -Bytes ([byte[]]@())
            }
            $info.Error | Should -Be 'Empty file'
        }

        It 'reports an unrecognised format' {
            $path = New-GarbageFile -Dir $dir -Name 'cover.jpg'
            $info = InModuleScope PwshMusicTools -Parameters @{ Path = $path } {
                param($Path)
                Get-ImageInfo -LiteralPath $Path
            }
            $info.Error | Should -Be 'Unrecognised image format'
            $info.DetectedFormat | Should -Be ''
            $info.Width | Should -Be 0
        }

        It 'reports a missing file without throwing' {
            $path = Join-Path $dir 'missing.jpg'
            $info = InModuleScope PwshMusicTools -Parameters @{ Path = $path } {
                param($Path)
                Get-ImageInfo -LiteralPath $Path
            }
            $info.Error | Should -Not -BeNullOrEmpty
            $info.DetectedFormat | Should -Be ''
        }
    }

    Context 'Truncated and malformed headers' {
        It 'keeps the format of a PNG cut to 20 bytes and reports a truncated header' {
            $full = [byte[]](New-TestImageBytes -Format PNG -Width 640 -Height 480)
            $bytes = [byte[]]$full[0..19]
            $info = InModuleScope PwshMusicTools -Parameters @{ Bytes = $bytes } {
                param($Bytes)
                Get-ImageInfo -Bytes $Bytes
            }
            $info.DetectedFormat | Should -Be 'PNG'
            $info.Error | Should -Be 'Truncated header'
        }

        It 'reports a JPEG whose scan starts before any frame header' {
            $bytes = [byte[]](0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFF, 0xD9)
            $info = InModuleScope PwshMusicTools -Parameters @{ Bytes = $bytes } {
                param($Bytes)
                Get-ImageInfo -Bytes $Bytes
            }
            $info.DetectedFormat | Should -Be 'JPEG'
            $info.Error | Should -Be 'No JPEG frame header'
        }

        It 'reports an error for a JPEG truncated mid-APP0' {
            $full = [byte[]](New-TestImageBytes -Format JPEG)
            $bytes = [byte[]]$full[0..9]
            $info = InModuleScope PwshMusicTools -Parameters @{ Bytes = $bytes } {
                param($Bytes)
                Get-ImageInfo -Bytes $Bytes
            }
            $info.DetectedFormat | Should -Be 'JPEG'
            $info.Error | Should -Not -BeNullOrEmpty
            $info.Width | Should -Be 0
        }
    }
}

Describe 'Image format mapping helpers' {
    It 'maps extensions to formats' {
        InModuleScope PwshMusicTools {
            Get-ImageFormatFromExtension -Extension '.JPEG' | Should -Be 'JPEG'
            Get-ImageFormatFromExtension -Extension '.jpg' | Should -Be 'JPEG'
            Get-ImageFormatFromExtension -Extension '.tiff' | Should -Be 'TIFF'
            Get-ImageFormatFromExtension -Extension '.webp' | Should -Be 'WebP'
            Get-ImageFormatFromExtension -Extension '.txt' | Should -Be ''
        }
    }

    It 'maps formats to extensions' {
        InModuleScope PwshMusicTools {
            Get-ImageExtensionFromFormat -Format 'WebP' | Should -Be '.webp'
            Get-ImageExtensionFromFormat -Format 'JPEG' | Should -Be '.jpg'
            Get-ImageExtensionFromFormat -Format 'TIFF' | Should -Be '.tif'
            Get-ImageExtensionFromFormat -Format '' | Should -Be ''
        }
    }

    It 'maps MIME types to extensions' {
        InModuleScope PwshMusicTools {
            Get-ImageExtensionFromMimeType -MimeType 'image/JPEG' | Should -Be '.jpg'
            Get-ImageExtensionFromMimeType -MimeType ' image/png ' | Should -Be '.png'
            Get-ImageExtensionFromMimeType -MimeType 'image/x-ms-bmp' | Should -Be '.bmp'
            Get-ImageExtensionFromMimeType -MimeType 'application/octet-stream' | Should -Be ''
        }
    }
}
