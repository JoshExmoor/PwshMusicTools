# Get Parameters 
Param(
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)][String]$SourceDir,
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)][String]$DestDir
)

Function Get-Folder($initialDirectory) {
    [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms")|Out-Null

    $foldername = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{ SelectedPath = $initialDirectory }
    $foldername.Description = "Select a folder"
    $foldername.rootfolder = "MyComputer"

    if($foldername.ShowDialog() -eq "OK")
    {
        $folder += $foldername.SelectedPath
    }
    return $folder
}

function Ask-YesNo {
    $Confirm = $null

    While($Confirm -eq $null) {

        $Confirm = Read-Host -Prompt "Please Confirm, Y/N"

        Switch($Confirm[0])
        {
            Y { 
                Return "y" }
            N { 
                Return "n" }
            Default { $Confirm = $null }
        }
    }
}




If(-not (Test-Path -LiteralPath $SourceDir)) {   # If $SourceDir is not a valid path
    Write-Host -ForegroundColor Red "'$SourceDir' Is not a valid path... Exiting."
    Exit
      
    }

If(-not (Test-Path -LiteralPath $DestDir)) {   # If $DestDir is not a valid path
    Write-Host -ForegroundColor Red "'$DestDir' Is not a valid path... Exiting."
    Exit
    }


# Get-ChildItems from both directories

$Source = Get-ChildItem -LiteralPath $SourceDir | Where-Object {$_.Name -match "^\d.+\.(m4a|flac|ogg|opus|mp3)$"}
$Dest   = Get-ChildItem -LiteralPath $DestDir   | Where-Object {$_.Name -match "^\d.+\.(m4a|flac|ogg|opus|mp3)$"}

if($Source.Count -ne $Dest.Count) {
    Write-Host -ForegroundColor Red "WARNING: Unequal number of songs in the specified directories."
    
}

# Rename-Item all files

$AddRename = $null

Foreach($File in $Source) {
    $SongNum = $File.Name.Substring(0,($File.Name.IndexOf(' ')))   # Should match anything before the space. 

    if(($Dest.name -match "^$SongNum")[1]) { # If there is more than one file that matches the first digits of the filename
        Write-Host -ForegroundColor Yellow "Multiple Matches Found for $File. There may be an issue with your file names. Exiting"
        Break
    }

    $DestFilename = ($Dest.name -match "^$SongNum")[0]

    if($DestFilename) {
        if(($File.Name.Substring(($File.Name.Length-3),3)) -ne ($DestFilename.Substring(($DestFilename.Length-3),3))) {  #If the three characters of the file extension don't match. 
            Write-Host -ForegroundColor Yellow "File extensions do not match...Exiting"
            Break
        }
    }   
    if($Destfilename -and $File.Name -ne $DestFilename) {

        $AddRename += @(
            [PSCustomObject]@{SourceDir=$SourceDir; SourceFile=$File.Name; DestFile=$DestFilename}
            )


        }
}

if($AddRename) {
    Write-Host "About to rename the following files:"
    Format-Table -InputObject $AddRename  -Property "SourceFile","DestFile"  # Display a table of the SourceFile and DestFile for confirmation by user. 

    $YesNo = Ask-YesNo

    If($YesNo -eq "y")
    {
        ForEach($NewFile in $AddRename) {
            Rename-Item -LiteralPath ($Newfile.SourceDir + "\" + $NewFile.SourceFile) -NewName $NewFile.DestFile
         }
    }
    Else {
        Write-Host "No. Exiting.."
        
    }
}
Else {
    Write-Host "No Files To Rename..."

}

