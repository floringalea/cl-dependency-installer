#Requires -Version 5.1
<#
.SYNOPSIS
Installs or updates VS Code, Salesforce CLI, Claude Code, and Claude Desktop.

.DESCRIPTION
Requires Windows, WinGet, and internet access. Salesforce CLI's Windows
installer and WinGet packages may require elevation. Run from a trusted local
copy; see README.md for Google Drive distribution and optional JDK setup.

.PARAMETER IncludeApexJdk
Also install or update Eclipse Temurin JDK 21 for the Salesforce Apex
extension. This does not install or configure the extension.
#>
[CmdletBinding()]
param(
    [switch] $IncludeApexJdk
)

$ErrorActionPreference = 'Stop'
$noPackage = -1978335212
$noUpdate = -1978335189
$failures = [System.Collections.Generic.List[string]]::new()

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $entries = foreach ($entry in ((@($env:Path, $machinePath, $userPath) -join ';') -split ';')) {
        if ($entry -and $seen.Add($entry.TrimEnd('\'))) { $entry }
    }
    $env:Path = $entries -join ';'
}

function Add-UserPath {
    param([Parameter(Mandatory)][string] $Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Cannot add missing directory to PATH: $Directory"
    }
    $directory = [Environment]::ExpandEnvironmentVariables($Directory).TrimEnd('\')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (-not (Test-PathEntry "$userPath;$machinePath" $directory)) {
        $newPath = @($userPath, $directory) | Where-Object { $_ }
        [Environment]::SetEnvironmentVariable('Path', ($newPath -join ';'), 'User')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not (Test-PathEntry $userPath $directory)) {
            throw "Could not persist $directory in the user PATH."
        }
        Write-Host "Added to user PATH: $directory"
    }
    if (-not (Test-PathEntry $env:Path $directory)) {
        $env:Path = "$env:Path;$directory"
    }
}

function Test-PathEntry {
    param([string] $PathValue, [string] $Directory)
    foreach ($entry in ($PathValue -split ';')) {
        if ([Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\') -ieq $Directory.TrimEnd('\')) {
            return $true
        }
    }
    return $false
}

function Find-Executable {
    param([string[]] $Names, [string[]] $Candidates = @())

    foreach ($directory in ($env:Path -split ';')) {
        if (-not $directory.Trim()) { continue }
        $directory = [Environment]::ExpandEnvironmentVariables($directory.Trim().Trim('"'))
        foreach ($name in $Names) {
            $path = Join-Path $directory $name
            if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        }
    }
    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Test-WingetInstalled {
    param([string] $Id)
    & winget.exe list --id $Id --exact --source winget --accept-source-agreements --disable-interactivity | Out-Host
    if ($LASTEXITCODE -eq 0) { return $true }
    if ($LASTEXITCODE -eq $noPackage) { return $false }
    throw "WinGet could not check ${Id} (exit code $LASTEXITCODE)."
}

function Install-OrUpdateWingetPackage {
    param([string] $Id, [bool] $Installed)
    $common = @('--id', $Id, '--exact', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($Installed) {
        & winget.exe upgrade @common | Out-Host
        $result = $LASTEXITCODE
        if ($result -eq $noUpdate) {
            Write-Host "No applicable WinGet update for $Id. Check WinGet output for pins or unknown versions."
            return
        }
    } else {
        & winget.exe install @common | Out-Host
        $result = $LASTEXITCODE
    }
    if ($result -ne 0) { throw "WinGet operation for $Id failed (exit code $result)." }
}

function Invoke-CheckedCommand {
    param([string] $File, [string[]] $Arguments)
    & $File @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$File failed (exit code $LASTEXITCODE)." }
}

function Get-NpmPrefix {
    $npm = Find-Executable -Names @('npm.cmd', 'npm.exe')
    if (-not $npm) { return $null }
    $prefix = & $npm prefix --global
    if ($LASTEXITCODE -ne 0) { throw "Could not determine npm's global prefix (exit code $LASTEXITCODE)." }
    return ($prefix | Select-Object -Last 1).Trim()
}

function Test-InNpmPrefix {
    param([string] $Executable)
    $prefix = Get-NpmPrefix
    if (-not $prefix) { return $false }
    return (Split-Path -Parent $Executable).TrimEnd('\') -ieq $prefix.TrimEnd('\')
}

function Install-SalesforceCli {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'sf\bin\sf.cmd'),
        (Join-Path $env:ProgramFiles 'sf\bin\sf.cmd')
    )
    $sf = Find-Executable -Names @('sf.cmd', 'sf.exe') -Candidates $candidates
    if ($sf) {
        Add-UserPath (Split-Path -Parent $sf)
        if (Test-InNpmPrefix $sf) {
            $npm = Find-Executable -Names @('npm.cmd', 'npm.exe')
            Invoke-CheckedCommand $npm @('install', '--global', '@salesforce/cli')
        } else {
            $previousPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $updateOutput = & $sf update 2>&1
                $result = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            $updateOutput | Out-Host
            if ($result -ne 0 -or ($updateOutput -join "`n") -match '(?i)not updatable|installed by sfdx|use .?npm update') {
                throw 'Salesforce CLI update failed or this installation cannot update itself. Check its installation method.'
            }
        }
    } else {
        $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
        $packageArch = switch ($arch) {
            'AMD64' { 'x64' }
            'ARM64' { 'arm64' }
            default { throw "Unsupported Windows architecture: $arch" }
        }
        $installer = Join-Path ([IO.Path]::GetTempPath()) ("sf-install-{0}.exe" -f [guid]::NewGuid())
        try {
            $url = "https://developer.salesforce.com/media/salesforce-cli/sf/channels/stable/sf-$packageArch.exe"
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -UserAgent 'curl/8.0.0'
            $signature = Get-AuthenticodeSignature -FilePath $installer
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)Salesforce') {
                throw "Salesforce installer signature is not valid or not signed by Salesforce: $($signature.Status)."
            }
            $process = Start-Process -FilePath $installer -ArgumentList '/S' -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw "Salesforce installer failed (exit code $($process.ExitCode))." }
        } finally {
            if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
        }
        Refresh-ProcessPath
        $sf = Find-Executable -Names @('sf.cmd', 'sf.exe') -Candidates $candidates
        if (-not $sf) { throw 'Salesforce CLI could not be found after installation.' }
        Add-UserPath (Split-Path -Parent $sf)
    }
    Invoke-CheckedCommand $sf @('--version')
}

function Install-ClaudeCode {
    $id = 'Anthropic.ClaudeCode'
    $native = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    $wingetLinks = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
        (Join-Path $env:ProgramFiles 'WinGet\Links')
    )
    $candidates = @(
        $native,
        (Join-Path $env:APPDATA 'npm\claude.cmd'),
        (Join-Path $wingetLinks[0] 'claude.exe'),
        (Join-Path $wingetLinks[1] 'claude.exe')
    )
    $claude = Find-Executable -Names @('claude.exe', 'claude.cmd') -Candidates $candidates
    $managed = Test-WingetInstalled $id
    if (-not $claude -and -not $managed) {
        $prefix = Get-NpmPrefix
        if ($prefix) {
            $npmClaude = Join-Path $prefix 'claude.cmd'
            if (Test-Path -LiteralPath $npmClaude -PathType Leaf) { $claude = $npmClaude }
        }
    }
    if (Test-Path -LiteralPath $native -PathType Leaf) {
        Add-UserPath (Split-Path -Parent $native)
    }
    if ($claude) {
        Add-UserPath (Split-Path -Parent $claude)
    }
    $isWingetLink = $claude -and ($wingetLinks -contains (Split-Path -Parent $claude))
    if ($managed -and (-not $claude -or $isWingetLink)) {
        Install-OrUpdateWingetPackage $id $true
    } elseif ($claude) {
        if (Test-InNpmPrefix $claude) {
            $npm = Find-Executable -Names @('npm.cmd', 'npm.exe')
            Invoke-CheckedCommand $npm @('install', '--global', '@anthropic-ai/claude-code')
        } else {
            Invoke-CheckedCommand $claude @('update')
        }
    } else {
        Install-OrUpdateWingetPackage $id $false
    }
    Refresh-ProcessPath
    $claude = Find-Executable -Names @('claude.exe', 'claude.cmd') -Candidates $candidates
    if (-not $claude) { throw 'Claude Code could not be found after installation or update.' }
    Add-UserPath (Split-Path -Parent $claude)

    $locations = @(
        Get-Command claude -CommandType Application,ExternalScript -All -ErrorAction SilentlyContinue |
            ForEach-Object { Split-Path -Parent $_.Source }
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { Split-Path -Parent $candidate }
        }
    ) | Sort-Object -Unique
    if (@($locations).Count -gt 1) {
        Write-Warning "Multiple Claude Code locations found: $($locations -join ', '). Check 'where.exe claude' and remove unwanted copies manually."
    }
    Test-ClaudeCommand
}

function Test-ClaudeCommand {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $originalPath = $env:Path
    try {
        $env:Path = @($machinePath, $userPath) -join ';'
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $check = @'
$ErrorActionPreference = 'Stop'
$command = Get-Command claude -ErrorAction Stop
Write-Host "Claude command resolves to: $($command.Source)"
& claude --version
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
'@
        & $powershell -NoProfile -NonInteractive -Command $check | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Claude command failed using the persistent PATH (exit code $LASTEXITCODE)." }
    } finally {
        $env:Path = $originalPath
    }
}

function Invoke-SetupStep {
    param([string] $Name, [scriptblock] $Action)
    Write-Host "`n=== $Name ==="
    try { & $Action }
    catch {
        $message = "${Name}: $($_.Exception.Message)"
        $failures.Add($message)
        Write-Warning $message
    }
}

if ($env:OS -ne 'Windows_NT') { throw 'This script only supports Windows.' }
if (-not (Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'WinGet is required. Install or repair Microsoft App Installer, then retry.'
}
Refresh-ProcessPath

Invoke-SetupStep 'VS Code' {
    $id = 'Microsoft.VisualStudioCode'
    Install-OrUpdateWingetPackage $id (Test-WingetInstalled $id)
    Refresh-ProcessPath
    $code = Find-Executable -Names @('code.cmd', 'code.exe') -Candidates @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
    )
    if (-not $code) { throw 'VS Code command could not be found after installation or update.' }
    Add-UserPath (Split-Path -Parent $code)
    Invoke-CheckedCommand $code @('--version')
}
Invoke-SetupStep 'Salesforce CLI' { Install-SalesforceCli }
Invoke-SetupStep 'Claude Code' { Install-ClaudeCode }
Invoke-SetupStep 'Claude Desktop' {
    $id = 'Anthropic.Claude'
    Install-OrUpdateWingetPackage $id (Test-WingetInstalled $id)
    if (-not (Test-WingetInstalled $id)) { throw 'Claude Desktop was not detected after installation.' }
}
if ($IncludeApexJdk) {
    Invoke-SetupStep 'Temurin JDK 21' {
        $id = 'EclipseAdoptium.Temurin.21.JDK'
        Install-OrUpdateWingetPackage $id (Test-WingetInstalled $id)
        if (-not (Test-WingetInstalled $id)) { throw 'Temurin JDK 21 was not detected after installation.' }
        Write-Host 'If Apex cannot find the JDK, configure salesforcedx-vscode-apex.java.home in VS Code.'
    }
}
if ($failures.Count -gt 0) {
    Write-Host "`nSetup finished with $($failures.Count) failed step(s):"
    $failures | ForEach-Object { Write-Host " - $_" }
    exit 1
}
Write-Host "`nSetup finished. Restart terminals and VS Code to pick up environment changes."
