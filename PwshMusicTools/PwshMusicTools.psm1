# PwshMusicTools root module.
# Dot-sources every function definition under Public/ and exports it. Adding a
# new *.ps1 to Public/ (one function per file, named after the file) is all that
# is needed to ship a new command - the manifest's FunctionsToExport uses '*'.

$Public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in $Public) {
    try {
        . $file.FullName
    }
    catch {
        Write-Error "Failed to import function file '$($file.FullName)': $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function $Public.BaseName
