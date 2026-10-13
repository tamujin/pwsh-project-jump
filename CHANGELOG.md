# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/tamujin/pwsh-project-jump/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/tamujin/pwsh-project-jump/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/tamujin/pwsh-project-jump/releases/tag/v0.1.0
