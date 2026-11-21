# Private: thin seams around the external FlacCheck tool and the browser launch,
# so Invoke-IncomingMusic -FlacCheck can be tested without flaccheck.exe.
function Invoke-FlacCheckScan {
    <#
        Runs: flaccheck.exe scan <Path> --mode <Mode> --format html -o <ReportPath>
              --quiet --color never
        Returns an object with ExitCode and StdErr (text). The exit code is
        informational only: callers judge success by whether the report exists.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )
    $toolArgs = @('scan', $Path, '--mode', $Mode, '--format', 'html', '-o', $ReportPath, '--quiet', '--color', 'never')
    $all = & flaccheck.exe @toolArgs 2>&1
    $exit = $LASTEXITCODE
    $stderr = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    [PSCustomObject]@{ ExitCode = $exit; StdErr = $stderr }
}

function Open-FlacCheckReport {
    <# Opens the HTML report with the default handler (the browser). #>
    param([Parameter(Mandatory = $true)][string]$Path)
    Invoke-Item -LiteralPath $Path -ErrorAction Stop
}
