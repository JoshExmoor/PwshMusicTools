# Shared helpers for the PwshMusicTools test suite.
#
# Dot-source this from a Pester BeforeAll block:
#     . $PSScriptRoot/TestHelpers.ps1
#     Import-PwshMusicTools
#
# It imports the module under test and exposes helpers for building disposable
# fixture directories of empty files.

function Import-PwshMusicTools {
    # Resolve the module manifest relative to the Tests folder (its parent) and
    # import it fresh so tests always exercise the current source.
    $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'PwshMusicTools/PwshMusicTools.psd1'
    Import-Module $manifest -Force -ErrorAction Stop
}

function New-TestDir {
    <#
        Creates a unique empty directory under the system temp folder and returns
        its full path. Pair with Remove-TestDir in an AfterEach/AfterAll.
    #>
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pmt-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-EmptyFile {
    <#
        Creates an empty file at Dir\Name (creating Dir if needed) and returns the
        file's full path. Content is irrelevant for the pure-logic functions, so
        the files are left 0 bytes.
    #>
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $full = Join-Path $Dir $Name
    New-Item -ItemType File -Path $full -Force | Out-Null
    return $full
}

function Remove-TestDir {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-FileNames {
    <#
        Returns the sorted leaf names of the files directly in a directory, for
        easy comparison against an expected set.
    #>
    param([Parameter(Mandatory)][string]$Dir)
    @(Get-ChildItem -LiteralPath $Dir -File | Select-Object -ExpandProperty Name | Sort-Object)
}
