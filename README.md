# pwsh-project-jump

[![CI](https://github.com/tamujin/pwsh-project-jump/actions/workflows/ci.yml/badge.svg)](https://github.com/tamujin/pwsh-project-jump/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![PowerShell 5.1 | 7+](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE)

Jump between project folders from any PowerShell prompt. Press **Ctrl+K**, type a few letters, and press **Enter**.

```
Projects  3/42   Enter: cd | Shift+Enter: tab | Ctrl+S: split | Ctrl+O: editor | ...
> self
> self-service-portal  D:\source\repos\acme\self-service-portal
  self-hosted-runner   D:\source\repos\infra\self-hosted-runner
  shelf-api            D:\source\repos\shelf-api
```

- **Type-ahead search.** Space-separated words all have to match. Results rank folder-name prefix matches first, then name matches, then path matches, then loose matches where the letters only appear in order.
- **Most used first.** The folders you open most often and most recently go to the top (frecency), so a project you use every day is usually one keypress away.
- **Finds your repos automatically.** Point it at a folder like `D:\source\repos` with `Add-ProjectRoot` and every git repository under it is listed, with no need to add each one.
- **Open it your way:**
  - **Enter** changes to the folder in the current tab
  - **Shift+Enter** opens a new Windows Terminal tab
  - **Ctrl+S** opens a split pane
  - **Ctrl+O** opens VS Code or your editor
  - **Ctrl+E** opens File Explorer
- **Tabs named after the project.** New tabs and panes get the project's folder name as their title.
- **Browse into a project.** Press **→** on a folder to list its subfolders, **←** to go back up. `Ctrl+K` `rmt` `→` `→` `deploy` `Enter` replaces a long `cd` path.
- **Run project tasks with Ctrl+T.** It lists what you can run in the current project (make targets, Aspire, dotnet, npm scripts, PowerShell scripts, docker compose, maven/gradle, and your own commands), most used first. See [Task runner](#task-runner-ctrlt).
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
| `Get-ProjectFolder [-All]` | | List saved folders with their `Exists` flag and usage score. `-All` includes scanned repos. |
| `Add-ProjectRoot [path] [-Depth 3]` | | Scan a folder for git repositories, up to `Depth` levels deep. |
| `Remove-ProjectRoot <path>` | | Stop scanning a folder. |
| `Get-ProjectRoot` | | List scanned folders. |
| `Update-ProjectIndex` | | Rescan now, for example after cloning a new repo. Ctrl+R in the picker does the same. |
| `Invoke-ProjectJump` | `pj` | Open the picker. This is what Ctrl+K runs. |
| `Get-ProjectTask [path]` | | List the tasks found in a project, without running anything. |
| `Add-ProjectTask <name> <command>` | | Save your own command as a task for the current project. |
| `Remove-ProjectTask <name>` | | Remove one of your own tasks. |
| `Invoke-ProjectTask [name]` | `pjt` | Open the task picker. With a name, runs the best match straight away: `pjt 'aspire stop'`. |
| `Set-ProjectJumpKeyHandler -Chord <chord>` | | Bind the folder picker to a different key. |
| `Set-ProjectTaskKeyHandler -Chord <chord>` | | Bind the task picker to a different key. |

Pick up every git repo under your source folder, then save a few extra non-repo folders:

```powershell
Add-ProjectRoot D:\source\repos
pja C:\notes
```

The scan skips hidden folders, junctions, `node_modules`, `bin`/`obj` and similar folders. It doesn't descend into a repository once it finds one. Results are cached for 60 minutes.

### Picker keys

| Key | Action |
|---|---|
| *typing* | Filter |
| `↑` `↓` / `Ctrl+K` `Ctrl+J` / `Ctrl+P` `Ctrl+N` / `Tab` | Move selection |
| `PgUp` `PgDn` `Home` `End` | Jump through the list |
| `Enter` | Change to the folder in the current tab |
| `→` | Browse the highlighted folder's subfolders (the folder itself is the first entry) |
| `←` | Go back up; from the top of a browsed folder, back to the project list |
| `Shift+Enter` | Open the folder in a new Windows Terminal tab |
| `Ctrl+S` | Open the folder in a new Windows Terminal split pane |
| `Ctrl+O` | Open the folder in your editor (`code` by default) |
| `Ctrl+E` | Open the folder in File Explorer |
| `Ctrl+R` | Rescan project roots |
| `Ctrl+U` | Clear the filter |
| `Esc` | Cancel |

Folders that no longer exist are shown in red. The list also includes folders you have opened at least three times from the browser, even if you never saved them.

### Task runner (Ctrl+T)

`Ctrl+T` shows what you can run in the project around the current folder (the nearest parent that contains `.git`). Type to filter, then:

| Key | Action |
|---|---|
| `Enter` | Run the task in this tab. The command is typed at the prompt, so it is in your history and `↑` repeats it. |
| `Shift+Enter` | Run it in a new Windows Terminal tab |
| `Ctrl+S` | Run it in a split pane |
| `Esc` | Cancel |

Tasks are found from these files, up to a few folders deep (never inside `node_modules`, `bin`, `obj` and similar folders):

| Source | Tasks |
|---|---|
| `Makefile` | every target, with the `## comment` as description |
| Aspire AppHost | `aspire run`, `start`, `stop`, `ps`, run from the AppHost folder |
| `*.sln` / `*.csproj` | `dotnet build`, `test`, `clean`, `-c Release` variants; `dotnet run` for web and executable projects (not test projects) |
| `package.json` | `install` / `ci` and every script, using npm, yarn or pnpm depending on the lock file |
| `*.ps1` | scripts in the project root and in `scripts`, `tools` or `build` |
| `docker-compose.yml` | `up`, `up -d`, `down`, `logs -f` |
| `pom.xml`, `gradlew.bat` | maven and gradle build and test |
| `Add-ProjectTask` | your own commands, listed first |

The tasks you run most are listed first. Save a command that is not detected:

```powershell
Add-ProjectTask logs 'Get-ChildItem .\logs -Filter *.log | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Wait -Tail 20'
```

**Security:** nothing runs until you choose it, and the command is shown in the picker. File names, make targets and script names from a repository are quoted so they can't add extra commands. Your own tasks are stored in your data folder, never in the repository.

## Configuration

| Environment variable | Effect |
|---|---|
| `PROJECTJUMP_HOME` | Data folder. Default: `~/.projectjump`. It holds `folders.txt` (saved folders, one per line, editable by hand), `roots.txt`, `index.txt` (the scan cache), `tasks.txt` (your own tasks) and `usage.json`. |
| `PROJECTJUMP_EDITOR` | Command used by Ctrl+O. Default: `code`. If the command isn't found, Ctrl+O falls back to File Explorer. |
| `PROJECTJUMP_INDEX_TTL` | Minutes before the scan cache is refreshed. Default: `60`. |
| `PROJECTJUMP_NO_KEYBINDING` | If set before import, Ctrl+K and Ctrl+T are not bound. Call `Set-ProjectJumpKeyHandler` and `Set-ProjectTaskKeyHandler` yourself to choose keys. |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+, with PSReadLine (included in both)
- [Windows Terminal](https://aka.ms/terminal) for Shift+Enter tabs and Ctrl+S panes. Outside Windows Terminal, both open a new console window instead.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
