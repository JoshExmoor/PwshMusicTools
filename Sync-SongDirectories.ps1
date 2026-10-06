# Get Parameters 
Param(
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)][String]$SourceDir,
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)][String]$DestDir
)


$SourceFolders = (Get-ChildItem -Directory -Path $SourceDir)
$DestFolders = (Get-ChildItem -Directory -Path $DestDir)
$MatchingFolders = $SourceFolders | Where-Object {$_.Name -in $DestFolders.Name}

# $MatchingFolders.name

ForEach($Source in $MatchingFolders) {
    
    $Destination = ($DestFolders | Where-Object {$_.Name -in $Source.Name})[0]
    Write-Host $Source.FullName
    Write-Host $Destination.FullName
    & 'E:\Music Tools\sync-song-files\Sync-SongFiles.ps1' -SourceDir $Source.FullName -DestDir $Destination.FullName
}

