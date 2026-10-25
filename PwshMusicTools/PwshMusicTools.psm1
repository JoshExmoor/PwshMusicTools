# PwshMusicTools root module.
# Dot-sources every function definition under Private/ (internal helpers, not
# exported) and Public/ (exported commands). Adding a new *.ps1 to Public/ (one
# function per file, named after the file) and listing it in the manifest's
# FunctionsToExport is all that is needed to ship a new command.

$Private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$Public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($Private) + @($Public)) {
    try {
        . $file.FullName
    }
    catch {
        Write-Error "Failed to import function file '$($file.FullName)': $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function $Public.BaseName
