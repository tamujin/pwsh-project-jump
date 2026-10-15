#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the ProjectJump module for the current user.
.DESCRIPTION
    Copies the ProjectJump module into the current user's module path for the running PowerShell edition,
    and adds 'Import-Module ProjectJump' to the current user's profile unless -NoProfile is given.

    Run from a clone, it installs the working copy in src/ProjectJump. Run on its own (for example
    piped from the web), it downloads ProjectJump.zip from the latest GitHub release, or from the
    release given by -Version.
.EXAMPLE
    ./install.ps1
.EXAMPLE
    ./install.ps1 -NoProfile
.EXAMPLE
    irm https://raw.githubusercontent.com/tamujin/pwsh-project-jump/main/install.ps1 | iex
.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/tamujin/pwsh-project-jump/main/install.ps1))) -Version 0.3.0
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$NoProfile,
    # Release to download, such as 0.3.0. Defaults to the latest release. Ignored when run from a clone.
    [string]$Version
)

# The work happens in a function so that, when this script is piped into Invoke-Expression,
# its variables and preferences stay out of the caller's session and ShouldProcess still works.
function Install-ProjectJumpModule {
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$NoProfile, [string]$Version)

    $ErrorActionPreference = 'Stop'
    $repo = 'tamujin/pwsh-project-jump'
    $source = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'src/ProjectJump' }
    $download = $null

    if (-not $source -or -not (Test-Path -LiteralPath (Join-Path $source 'ProjectJump.psd1'))) {
        $url = if ($Version) { "https://github.com/$repo/releases/download/v$($Version.TrimStart('v'))/ProjectJump.zip" }
        else { "https://github.com/$repo/releases/latest/download/ProjectJump.zip" }
        $download = Join-Path ([IO.Path]::GetTempPath()) "ProjectJump-$([guid]::NewGuid().ToString('n'))"
        # Scratch files are written even under -WhatIf, which needs the version they contain.
        New-Item -ItemType Directory -Path $download -Force -WhatIf:$false | Out-Null
        $zip = Join-Path $download 'ProjectJump.zip'
        Write-Host "Downloading $url"
        # Windows PowerShell 5.1 can default to TLS 1.0, which GitHub rejects.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest very slow in 5.1
        try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing }
        finally { $ProgressPreference = $oldProgress }
        $source = Join-Path $download 'ProjectJump'
        Expand-Archive -LiteralPath $zip -DestinationPath $source -Force -WhatIf:$false
    }

    try {
        $moduleVersion = (Import-PowerShellDataFile (Join-Path $source 'ProjectJump.psd1')).ModuleVersion

        $docs = [Environment]::GetFolderPath('MyDocuments')
        $modulesRoot = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $docs 'PowerShell/Modules' } else { Join-Path $docs 'WindowsPowerShell/Modules' }
        $target = Join-Path $modulesRoot "ProjectJump/$moduleVersion"

        if ($PSCmdlet.ShouldProcess($target, 'Install ProjectJump module')) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
            Write-Host "Installed ProjectJump $moduleVersion to $target" -ForegroundColor Green
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
    }
    finally {
        if ($download) { Remove-Item -LiteralPath $download -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    }

    Write-Host 'Open a new terminal tab, run pja in a project folder, then press Ctrl+K.'
}

try { Install-ProjectJumpModule -NoProfile:$NoProfile -Version $Version }
finally { Remove-Item -Path Function:\Install-ProjectJumpModule -ErrorAction SilentlyContinue -WhatIf:$false }
