$TestData = Get-ChildItem -Recurse -Path "E:\Music Tools\sync-song-files\test-data"

ForEach($File in $TestData) {
    $NewPath = $File.DirectoryName.Replace("test-data","test-data2")
    if(-Not (Test-Path($NewPath))) { New-Item -ItemType "directory" -Path $NewPath }

    $NewFile = ($NewPath + "\" + $File.Name)
    New-Item -Path $NewPath -Name $File.Name
}