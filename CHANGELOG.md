# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- More ways to install: the PowerShell Gallery (`Install-Module ProjectJump`), a one-line installer (`irm .../install.ps1 | iex`), a Scoop bucket in this repository, and `ProjectJump.zip` attached to each GitHub release with a SHA-256 checksum.
- `install.ps1` downloads the latest release (or `-Version`) when it isn't run from a clone, and leaves no variables behind when piped into `Invoke-Expression`.

## [0.3.0] - 2026-10-14

### Added
- Task runner on Ctrl+T. It lists what you can run in the current project: make targets, Aspire (`run`/`start`/`stop`/`ps`), dotnet build/test/run, npm/yarn/pnpm scripts, PowerShell scripts, docker compose, maven and gradle. Enter runs the task at the prompt (so it is in your history), Shift+Enter in a new tab, Ctrl+S in a split pane.
- `Get-ProjectTask`, `Add-ProjectTask`, `Remove-ProjectTask`, `Invoke-ProjectTask` (`pjt`) and `Set-ProjectTaskKeyHandler`. Save your own commands per project with `Add-ProjectTask`; `pjt <name>` runs the best match without the picker.
- Browse into a folder from the picker with Right, go back with Left. The folder itself is the first entry. Folders you use most while browsing are listed first.
- Folders you open at least three times from the browser show up in the list even if you never saved them (`Source` = `visited` in `Get-ProjectFolder -All`).

### Security
- File names, make targets and package.json script names are quoted before they become part of a command, so a repository cannot inject extra commands through them. Tasks opened in a new tab or pane are passed encoded.

## [0.2.1] - 2026-10-13

### Fixed
- Prompt icons (oh-my-posh, Nerd Fonts) showed as `?` after jumping to a folder when the console used a legacy code page such as 437. The picker and prompt redraw now write UTF-8 and restore the previous encoding afterwards.

## [0.2.0] - 2026-10-13

### Added
- Folders are ranked by frecency (how often and how recently you opened them). The most used projects show first.
- `Add-ProjectRoot`, `Remove-ProjectRoot`, `Get-ProjectRoot` and `Update-ProjectIndex` scan folders for git repositories and list them automatically. Scan results are cached; `PROJECTJUMP_INDEX_TTL` sets how long.
- New picker keys:
  - Ctrl+S opens a Windows Terminal split pane.
  - Ctrl+O opens your editor (`PROJECTJUMP_EDITOR`, default `code`).
  - Ctrl+E opens File Explorer.
  - Ctrl+R rescans project roots.
- `Get-ProjectFolder -All` includes scanned repositories and shows each folder's source and usage score.

### Changed
- New tabs and panes are titled with the project folder name.

## [0.1.0] - 2026-10-13

### Added
- Ctrl+K type-ahead picker over saved project folders.
- Enter changes to the selected folder; Shift+Enter opens it in a new Windows Terminal tab.
- `Add-ProjectFolder` (`pja`), `Remove-ProjectFolder` (`pjr`), `Get-ProjectFolder`, `Invoke-ProjectJump` (`pj`).
- `Set-ProjectJumpKeyHandler` to bind a different key, and the `PROJECTJUMP_NO_KEYBINDING` variable to skip the default binding.
- `PROJECTJUMP_HOME` to change where the folder list is stored.
- Support for Windows PowerShell 5.1 and PowerShell 7+.

[Unreleased]: https://github.com/tamujin/pwsh-project-jump/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/tamujin/pwsh-project-jump/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/tamujin/pwsh-project-jump/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/tamujin/pwsh-project-jump/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/tamujin/pwsh-project-jump/releases/tag/v0.1.0
