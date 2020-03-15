function Ask-YesNo {
$Confirm = $null

    While($Confirm -eq $null) {

        $Confirm = Read-Host -Prompt "Please Confirm, Y/N"

        Switch($Confirm[0])
        {
            Y { Return "y" }
            N { Return "n" }
            Default { $Confirm = $null }
        }
    }
}


# Get Parameters 
Param(
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)][String]$SourceDir,
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)][String]$DestDir
)

If(-not (Test-Path($SourceDir))) {   # If $SourceDir is not a valid path
    Write-Host -ForegroundColor Red "'$SourceDir' Is not a valid path... Exiting."
    Exit
      
    }

If(-not (Test-Path($DestDir))) {   # If $DestDir is not a valid path
    Write-Host -ForegroundColor Red "'$DestDir' Is not a valid path... Exiting."
    Exit
    }


# Get-ChildItems from both directories

$Source = Get-ChildItem -Path $SourceDir | Where-Object {$_.Name -match "^\d.+\.(m4a|flac|ogg|mp3)$"}
$Dest   = Get-ChildItem -Path $DestDir   | Where-Object {$_.Name -match "^\d.+\.(m4a|flac|ogg|mp3)$"}

if($Source.count -ne $DestDir) {
    Write-Output "Unequal number of songs in the specified directories..."
    
    }

# Rename-Item all files

$AddRename = $null

Foreach($File in $Source) {
    $SongNum = $File.Name.Substring(0,($File.Name.IndexOf(' ')))

    if(($Dest.name -match "^$SongNum")[1]) { # If there is more than one file that matches the first digits of the filename
        Write-Host -ForegroundColor Yellow "Multiple Matches Found for $File. There may be an issue with your file names."
        Break
        }

    $DestFilename = ($Dest.name -match "^$SongNum")[0]
    
    if($File.Name -ne $DestFilename) {
        Write-Host -ForegroundColor Red "Renaming $File = $DestFilename ..."
#       Test-Path ($SourceDir + "\" + $File)
        $AddRename += @(
            [PSCustomObject]@{SourceDir=$SourceDir; SourceFile=$File; DestFile=$DestFilename}
            )

#        Rename-Item -Path ($SourceDir + "\" + $File) -NewName $DestFilename
        }
    else {
        Write-Host -ForegroundColor Green "$File already matches..."
        }

}

$ToRename = $AddRename | Select-Object -Property "SourceFile","DestFile"

Write-Host "About to rename the following files:"
Write-Output $ToRename

