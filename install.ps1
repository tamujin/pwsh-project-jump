#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the ProjectJump module for the current user.
.DESCRIPTION
    Copies src/ProjectJump into the current user's module path for the running PowerShell edition,
    and adds 'Import-Module ProjectJump' to the current user's profile unless -NoProfile is given.
.EXAMPLE
    ./install.ps1
.EXAMPLE
    ./install.ps1 -NoProfile
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$NoProfile)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'src/ProjectJump'
$version = (Import-PowerShellDataFile (Join-Path $source 'ProjectJump.psd1')).ModuleVersion

$docs = [Environment]::GetFolderPath('MyDocuments')
$modulesRoot = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $docs 'PowerShell/Modules' } else { Join-Path $docs 'WindowsPowerShell/Modules' }
$target = Join-Path $modulesRoot "ProjectJump/$version"

if ($PSCmdlet.ShouldProcess($target, 'Install ProjectJump module')) {
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
    Write-Host "Installed ProjectJump $version to $target" -ForegroundColor Green
}

if (-not $NoProfile) {
    $line = 'Import-Module ProjectJump'
    $profilePath = $PROFILE.CurrentUserCurrentHost
    $existing = if (Test-Path -LiteralPath $profilePath) { Get-Content -LiteralPath $profilePath -Raw } else { '' }
    if ($existing -match '(?m)^\s*Import-Module\s+.*ProjectJump') {
        Write-Host "Profile already imports ProjectJump: $profilePath" -ForegroundColor DarkGray
    }
    elseif ($PSCmdlet.ShouldProcess($profilePath, "Add '$line'")) {
        New-Item -ItemType Directory -Path (Split-Path $profilePath) -Force | Out-Null
        Add-Content -LiteralPath $profilePath -Value "`r`n# Ctrl+K project folder picker`r`n$line"
        Write-Host "Added '$line' to $profilePath" -ForegroundColor Green
    }
}

Write-Host 'Open a new terminal tab, run pja in a project folder, then press Ctrl+K.'
