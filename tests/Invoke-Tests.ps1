#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the Pester test suite. Used by CI and for local runs.
.EXAMPLE
    ./tests/Invoke-Tests.ps1
.EXAMPLE
    powershell -NoProfile -File ./tests/Invoke-Tests.ps1 -OutputPath testResults.xml
#>
[CmdletBinding()]
param([string]$OutputPath)

$ErrorActionPreference = 'Stop'
if (-not (Get-Module Pester -ListAvailable | Where-Object { $_.Version -ge [version]'5.5.0' })) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 5.5.0

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
if ($OutputPath) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = $OutputPath
}
Write-Host "PowerShell $($PSVersionTable.PSVersion) / Pester $((Get-Module Pester).Version)"
Invoke-Pester -Configuration $config
