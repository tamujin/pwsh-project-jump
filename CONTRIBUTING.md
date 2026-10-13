# Contributing

Thanks for helping improve pwsh-project-jump!

## Reporting bugs and requesting features

Open an [issue](https://github.com/tamujin/pwsh-project-jump/issues/new/choose). For bugs, include:
- your PowerShell version (`$PSVersionTable`)
- your terminal (Windows Terminal, conhost, VS Code, …)
- the steps to reproduce

## Development setup

```powershell
git clone https://github.com/tamujin/pwsh-project-jump.git
cd pwsh-project-jump
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force

# load your working copy
Import-Module ./src/ProjectJump/ProjectJump.psd1 -Force
```

## Before opening a pull request

```powershell
Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
./tests/Invoke-Tests.ps1                                    # PowerShell 7
powershell -NoProfile -File ./tests/Invoke-Tests.ps1        # Windows PowerShell 5.1
```

CI runs both checks on Windows PowerShell 5.1 and PowerShell 7.

Guidelines:
- Keep the module dependency-free and compatible with **PowerShell 5.1**. That rules out `??`, ternaries, `-Parallel` and .NET Core-only APIs.
- Keep source files ASCII, or UTF-8 with BOM. Windows PowerShell 5.1 misreads UTF-8 without a BOM.
- Add or update Pester tests for behavior changes.
- Add an entry under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md).
- Use clear commit messages. One logical change per PR is preferred.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
