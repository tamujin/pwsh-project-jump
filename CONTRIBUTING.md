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
- Keep source files ASCII, or UTF-8 with BOM. Windows PowerShell 5.1 misreads UTF-8 without a BOM. The exception is `install.ps1`, which must stay ASCII with no BOM, because `irm | iex` can't parse a script that starts with one.
- Add or update Pester tests for behavior changes.
- Add an entry under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md).
- Use clear commit messages. One logical change per PR is preferred.

## Releasing (maintainers)

1. Bump `ModuleVersion` in `src/ProjectJump/ProjectJump.psd1` and move the `[Unreleased]` notes in `CHANGELOG.md` under the new version.
2. Merge to `main` once CI is green.
3. Tag and push: `git tag -a vX.Y.Z -m "vX.Y.Z"; git push origin vX.Y.Z`.
4. The *Release* workflow checks that the tag matches the manifest, runs the tests, and creates the GitHub release with `ProjectJump.zip` (built by `tools/New-ReleasePackage.ps1`) and its `.sha256`. If the `PSGALLERY_API_KEY` secret is set, it also publishes to the PowerShell Gallery; without it, that step is skipped with a warning. It can wait for approval in the `powershell-gallery` environment.
5. Once the release is up, update the Scoop manifest and commit it to `main`:
   ```powershell
   & "$(scoop prefix scoop)\bin\checkver.ps1" -App projectjump -Dir ./bucket -Update
   ```
   This sets the new version, URL and hash in `bucket/projectjump.json`. The one-line installer always takes the latest release, so it needs no change.

A version published to the Gallery can only be unlisted, never replaced, so double-check the version before tagging.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
