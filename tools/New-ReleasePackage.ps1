#Requires -Version 5.1
<#
.SYNOPSIS
    Builds ProjectJump.zip, the release asset used by install.ps1 and the Scoop manifest.
.DESCRIPTION
    The zip holds the module files at its root (ProjectJump.psd1, ProjectJump.psm1) plus LICENSE,
    so it can be extracted straight into a 'ProjectJump' module folder. Writes ProjectJump.zip and
    ProjectJump.zip.sha256 to -OutputPath and returns the zip file.
.EXAMPLE
    ./tools/New-ReleasePackage.ps1 -OutputPath out
#>
[CmdletBinding()]
param([string]$OutputPath = (Join-Path $PSScriptRoot '../out'))

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$source = Join-Path $root 'src/ProjectJump'
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$staging = Join-Path ([IO.Path]::GetTempPath()) "ProjectJump-package-$([guid]::NewGuid().ToString('n'))"
try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $staging -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $staging

    $zip = Join-Path (Resolve-Path $OutputPath) 'ProjectJump.zip'
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -Force

    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$zip.sha256" -Value "$hash  ProjectJump.zip" -Encoding Ascii
    Write-Host "Built $zip (sha256 $hash)"
    Get-Item -LiteralPath $zip
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
