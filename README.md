# pwsh-project-jump

[![CI](https://github.com/tamujin/pwsh-project-jump/actions/workflows/ci.yml/badge.svg)](https://github.com/tamujin/pwsh-project-jump/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![PowerShell 5.1 | 7+](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE)

Jump between project folders from any PowerShell prompt. Press **Ctrl+K**, type a few letters, and press **Enter**.

```
Projects  3/12   Enter: open | Shift+Enter: new tab | Esc: cancel
> self
> self-service-portal  D:\source\repos\acme\self-service-portal
  self-hosted-runner   D:\source\repos\infra\self-hosted-runner
  shelf-api            D:\source\repos\shelf-api
```

- **Type-ahead search.** Space-separated words all have to match. Results rank folder-name prefix matches first, then name matches, then path matches, then loose matches where the letters only appear in order.
- **Enter** changes to the folder in the current tab.
- **Shift+Enter** opens the folder in a new Windows Terminal tab.
- **No dependencies.** It's a single PowerShell module with no fzf or external binaries. It works in Windows PowerShell 5.1 and PowerShell 7+.
- **Keeps your screen intact.** The picker uses the terminal's alternate screen, so your prompt and scrollback stay as they were.

## Install

### From source

```powershell
git clone https://github.com/tamujin/pwsh-project-jump.git
cd pwsh-project-jump
./install.ps1
```

`install.ps1` copies the module into your user module path and adds `Import-Module ProjectJump` to your PowerShell profile. Use `-NoProfile` to skip the profile change. It installs for whichever PowerShell runs it, so run it once from `pwsh` and once from `powershell` if you use both.

### Manually

```powershell
Import-Module <path-to-repo>\src\ProjectJump\ProjectJump.psd1
```

Add that line to your `$PROFILE` to load the module in every session.

## Usage

| Command | Alias | Description |
|---|---|---|
| `Add-ProjectFolder [path]` | `pja` | Save a folder. Defaults to the current directory and accepts pipeline input. |
| `Remove-ProjectFolder [path]` | `pjr` | Remove a saved folder. With no path, it opens the picker. |
| `Get-ProjectFolder` | | List saved folders, with an `Exists` flag for each. |
| `Invoke-ProjectJump` | `pj` | Open the picker. This is what Ctrl+K runs. |
| `Set-ProjectJumpKeyHandler -Chord <chord>` | | Bind the picker to a different key. |

Add every repo under a folder in one go:

```powershell
Get-ChildItem D:\source\repos -Directory | Add-ProjectFolder
```

### Picker keys

| Key | Action |
|---|---|
| *typing* | Filter |
| `↑` `↓` / `Ctrl+K` `Ctrl+J` / `Ctrl+P` `Ctrl+N` / `Tab` | Move selection |
| `PgUp` `PgDn` `Home` `End` | Jump through the list |
| `Enter` | Change to the folder in the current tab |
| `Shift+Enter` | Open the folder in a new Windows Terminal tab |
| `Ctrl+U` | Clear the filter |
| `Esc` | Cancel |

Folders that no longer exist are shown in red.

## Configuration

| Environment variable | Effect |
|---|---|
| `PROJECTJUMP_HOME` | Folder for the saved list. Default: `~/.projectjump`. The list is `folders.txt`, one path per line, which you can also edit by hand. |
| `PROJECTJUMP_NO_KEYBINDING` | If set before import, Ctrl+K is not bound. Call `Set-ProjectJumpKeyHandler` yourself to choose a key. |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+, with PSReadLine (included in both)
- [Windows Terminal](https://aka.ms/terminal) for Shift+Enter tabs. Outside Windows Terminal, Shift+Enter opens a new console window instead.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
