# ProjectJump - Ctrl+K type-ahead picker for project folders, Ctrl+T task runner.
#
# Project picker (Ctrl+K):
#   Enter        -> cd into the folder in the current tab
#   Right / Left -> browse into the highlighted folder's subfolders / go back up
#   Shift+Enter  -> open the folder in a new Windows Terminal tab
#   Ctrl+S       -> open the folder in a new split pane
#   Ctrl+O       -> open the folder in your editor (VS Code by default)
#   Ctrl+E       -> open the folder in File Explorer
#   Ctrl+R       -> rescan project roots
#   Esc          -> cancel
# Folders come from the saved list (pja / pjr), from scanning project roots (Add-ProjectRoot) and from
# folders you keep visiting. Folders you open most and most recently are listed first.
#
# Task runner (Ctrl+T):
#   Lists what you can run in the current project (make targets, aspire, dotnet, npm scripts, *.ps1,
#   docker compose, maven/gradle and your own tasks from Add-ProjectTask).
#   Enter -> run in this tab | Shift+Enter -> new tab | Ctrl+S -> split pane | Esc -> cancel

$script:StoreDir = if ($env:PROJECTJUMP_HOME) { $env:PROJECTJUMP_HOME } else {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.projectjump'
}
$script:StoreFile = Join-Path $script:StoreDir 'folders.txt'
$script:RootsFile = Join-Path $script:StoreDir 'roots.txt'
$script:IndexFile = Join-Path $script:StoreDir 'index.txt'
$script:UsageFile = Join-Path $script:StoreDir 'usage.json'
$script:TasksFile = Join-Path $script:StoreDir 'tasks.txt'
$script:SkipDirs = @('node_modules', 'bin', 'obj', 'packages', 'dist', 'out', 'target', 'venv', '__pycache__')
$script:VisitedMinHits = 3

#region Storage

function Initialize-Store {
    if (-not (Test-Path -LiteralPath $script:StoreDir)) { New-Item -ItemType Directory -Path $script:StoreDir | Out-Null }
}

function Read-ListFile([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return @() }
    @(Get-Content -LiteralPath $File -Encoding utf8 | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
}

function Get-ProjectFolderList { Read-ListFile $script:StoreFile }

function Save-ProjectFolderList([string[]]$Folders) {
    Initialize-Store
    Set-Content -LiteralPath $script:StoreFile -Value @($Folders) -Encoding utf8
}

# roots.txt: one "path<TAB>depth" per line
function Get-ProjectRootList {
    Read-ListFile $script:RootsFile | ForEach-Object {
        $parts = $_ -split "`t"
        $depth = 3
        if ($parts.Count -gt 1) { [void][int]::TryParse($parts[1], [ref]$depth) }
        [pscustomobject]@{ Path = $parts[0]; Depth = $depth }
    }
}

function Save-ProjectRootList($Roots) {
    Initialize-Store
    Set-Content -LiteralPath $script:RootsFile -Value @($Roots | ForEach-Object { "$($_.Path)`t$($_.Depth)" }) -Encoding utf8
}

# tasks.txt: one "projectPath<TAB>name<TAB>command" per line (your own tasks, see Add-ProjectTask)
function Get-CustomTaskList {
    Read-ListFile $script:TasksFile | ForEach-Object {
        $parts = $_ -split "`t", 3
        if ($parts.Count -eq 3) { [pscustomobject]@{ Base = $parts[0]; Name = $parts[1]; Command = $parts[2] } }
    }
}

function Save-CustomTaskList($Tasks) {
    Initialize-Store
    Set-Content -LiteralPath $script:TasksFile -Value @($Tasks | ForEach-Object { "$($_.Base)`t$($_.Name)`t$($_.Command)" }) -Encoding utf8
}

# Usage is keyed by lower-case path (or task key): @{ Path; Hits; Last (UTC ticks) }
function Get-ProjectUsage {
    $usage = @{}
    if (Test-Path -LiteralPath $script:UsageFile) {
        try {
            # ConvertFrom-Json via -InputObject: Windows PowerShell 5.1 emits a JSON array as a single object
            $data = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $script:UsageFile -Raw -Encoding utf8)
            foreach ($u in @($data)) {
                if ($u.Path) { $usage[$u.Path.ToLowerInvariant()] = $u }
            }
        }
        catch { Write-Verbose "ProjectJump: ignoring unreadable usage file: $_" }
    }
    $usage
}

function Add-ProjectUsage([string]$Path) {
    $usage = Get-ProjectUsage
    $key = $Path.ToLowerInvariant()
    $now = [DateTime]::UtcNow.Ticks
    if ($usage.ContainsKey($key)) {
        $usage[$key].Hits = [int]$usage[$key].Hits + 1
        $usage[$key].Last = $now
    }
    else {
        $usage[$key] = [pscustomobject]@{ Path = $Path; Hits = 1; Last = $now }
    }
    Initialize-Store
    # Build the array by hand: Windows PowerShell 5.1 can serialise arrays as { value, Count }
    '[' + ((@($usage.Values) | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress }) -join ',') + ']' | Set-Content -LiteralPath $script:UsageFile -Encoding utf8
}

# Frecency: hits weighted by how recently the folder was last opened.
function Get-Frecency($Usage) {
    if (-not $Usage) { return 0 }
    $hours = ([DateTime]::UtcNow - [DateTime]::new([long]$Usage.Last, [DateTimeKind]::Utc)).TotalHours
    $weight = if ($hours -lt 1) { 4 } elseif ($hours -lt 24) { 2 } elseif ($hours -lt 168) { 1 } else { 0.25 }
    [double]$Usage.Hits * $weight
}

#endregion

#region Scanning

# Subfolders worth descending into: not hidden (dot), not a build/dependency folder, not a junction.
function Get-ScanSubdirectory([string]$Dir) {
    try { $subs = [IO.Directory]::GetDirectories($Dir) } catch { return }
    foreach ($s in $subs) {
        $name = [IO.Path]::GetFileName($s)
        if ($name.StartsWith('.') -or $script:SkipDirs -contains $name) { continue }
        try { if ([IO.File]::GetAttributes($s) -band [IO.FileAttributes]::ReparsePoint) { continue } } catch { continue }
        $s
    }
}

# Breadth-first search for git repositories under $Root, not descending into repositories,
# hidden folders, junctions or common build/dependency folders.
function Find-GitRepository([string]$Root, [int]$Depth) {
    if (-not [IO.Directory]::Exists($Root)) { return }
    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Dir = $Root; Level = 0 })
    while ($queue.Count -gt 0) {
        $entry = $queue.Dequeue()
        $git = Join-Path $entry.Dir '.git'
        if ([IO.Directory]::Exists($git) -or [IO.File]::Exists($git)) { $entry.Dir; continue }
        if ($entry.Level -ge $Depth) { continue }
        foreach ($s in @(Get-ScanSubdirectory $entry.Dir)) {
            $queue.Enqueue([pscustomobject]@{ Dir = $s; Level = $entry.Level + 1 })
        }
    }
}

function Get-ProjectIndex([switch]$Force) {
    $roots = @(Get-ProjectRootList)
    if ($roots.Count -eq 0) { return @() }
    $ttl = 60
    if ($env:PROJECTJUMP_INDEX_TTL) { [void][int]::TryParse($env:PROJECTJUMP_INDEX_TTL, [ref]$ttl) }
    $fresh = (Test-Path -LiteralPath $script:IndexFile) -and
        (Get-Item -LiteralPath $script:IndexFile).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddMinutes(-$ttl) -and
        (Get-Item -LiteralPath $script:IndexFile).LastWriteTimeUtc -ge (Get-Item -LiteralPath $script:RootsFile).LastWriteTimeUtc
    if ($fresh -and -not $Force) { return Read-ListFile $script:IndexFile }

    $found = @($roots | ForEach-Object { Find-GitRepository $_.Path $_.Depth } | Sort-Object -Unique)
    Initialize-Store
    Set-Content -LiteralPath $script:IndexFile -Value $found -Encoding utf8
    $found
}

#endregion

#region Tasks

# Files the task detector cares about. *.ps1 is filtered by folder later.
$script:TaskFilePattern = '(?i)\.(sln|slnx|csproj|ps1)$|^(package\.json|pom\.xml|makefile|gnumakefile|docker-compose\.ya?ml|compose\.ya?ml|gradlew\.bat|apphost\.cs|aspire\.config\.json)$'

# Path without a trailing backslash (drive roots like D:\ keep theirs).
function ConvertTo-NormalPath([string]$Path) {
    if ($Path.Length -gt 3) { $Path.TrimEnd('\') } else { $Path }
}

function Get-RelativeDir([string]$Base, [string]$Dir) {
    $b = ConvertTo-NormalPath $Base
    $d = ConvertTo-NormalPath $Dir
    if ($d -ieq $b) { return '' }
    if ($d.StartsWith($b.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $d.Substring($b.TrimEnd('\').Length + 1) }
    $d
}

# The project a folder belongs to: the nearest parent with a .git folder, else the folder itself.
function Resolve-ProjectBase([string]$Dir) {
    $d = ConvertTo-NormalPath $Dir
    while ($d) {
        $git = Join-Path $d '.git'
        if ([IO.Directory]::Exists($git) -or [IO.File]::Exists($git)) { return $d }
        $parent = Split-Path $d -Parent
        if (-not $parent -or $parent -eq $d) { break }
        $d = $parent
    }
    ConvertTo-NormalPath $Dir
}

# Quotes a value so PowerShell passes it on literally. File names, make targets and package.json script
# names come from the repository, so they must never be able to inject commands.
function ConvertTo-PSArgument([string]$Value) {
    if ($Value -match '^(?!-)[A-Za-z0-9_.:/\\@+-]+$') { return $Value }
    # PowerShell also treats the typographic single quotes as quotes, so double all of them
    "'" + ($Value -replace "([\u0027\u2018\u2019\u201A\u201B])", '$1$1') + "'"
}

# Breadth-first search below $Root for files matching $script:TaskFilePattern.
function Find-ProjectFile([string]$Root, [int]$Depth) {
    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Dir = $Root; Level = 0 })
    while ($queue.Count -gt 0) {
        $entry = $queue.Dequeue()
        try { $files = [IO.Directory]::GetFiles($entry.Dir) } catch { $files = @() }
        foreach ($f in $files) {
            $n = [IO.Path]::GetFileName($f)
            if ($n -match $script:TaskFilePattern) { [pscustomobject]@{ Path = $f; Dir = $entry.Dir; Name = $n; Level = $entry.Level } }
        }
        if ($entry.Level -ge $Depth) { continue }
        foreach ($s in @(Get-ScanSubdirectory $entry.Dir)) {
            $queue.Enqueue([pscustomobject]@{ Dir = $s; Level = $entry.Level + 1 })
        }
    }
}

# Tasks that can be derived from the files in a project. Nothing is run here; every command is only text.
function Get-DetectedTask([string]$Base) {
    $files = @(Find-ProjectFile $Base 3)
    $task = {
        param($Kind, $Name, $Command, $Cwd, $Description)
        [pscustomobject]@{ Kind = $Kind; Name = $Name; Command = $Command; Cwd = $Cwd; Description = $Description; Source = 'detected' }
    }

    # make
    foreach ($f in @($files | Where-Object { $_.Name -match '(?i)^(gnumakefile|makefile)$' -and $_.Level -le 1 })) {
        $seen = @{}
        foreach ($line in @(Get-Content -LiteralPath $f.Path -ErrorAction SilentlyContinue)) {
            if ($line -match '^([A-Za-z0-9][A-Za-z0-9_./-]*) *:(?![=:])(.*)$') {
                $target = $Matches[1]; $rest = $Matches[2]
                if ($rest.StartsWith('//') -or $seen.ContainsKey($target)) { continue }
                $seen[$target] = $true
                $desc = ''
                if ($rest -match '##\s*(.+)$') { $desc = $Matches[1].Trim() }
                & $task 'make' "make $target" ('make ' + (ConvertTo-PSArgument $target)) $f.Dir $desc
            }
        }
    }

    # .NET projects (read once; used for Aspire, build/test and run)
    $projects = @($files | Where-Object { $_.Name -match '(?i)\.csproj$' } | ForEach-Object {
            [pscustomobject]@{ File = $_; Text = [string](Get-Content -LiteralPath $_.Path -Raw -ErrorAction SilentlyContinue) }
        })

    # Aspire
    $aspireDirs = @(@($projects | Where-Object { $_.Text -match 'Aspire\.AppHost\.Sdk|<IsAspireHost>\s*true' } | ForEach-Object { $_.File.Dir }) +
        @($files | Where-Object { $_.Name -match '(?i)^(apphost\.cs|aspire\.config\.json)$' -and $_.Level -le 1 } | ForEach-Object { $_.Dir }) |
            Select-Object -Unique)
    foreach ($dir in $aspireDirs) {
        & $task 'aspire' 'aspire run' 'aspire run' $dir 'Run the AppHost'
        & $task 'aspire' 'aspire start' 'aspire start' $dir 'Start the AppHost in the background'
        & $task 'aspire' 'aspire stop' 'aspire stop' $dir 'Stop the running AppHost'
        & $task 'aspire' 'aspire ps' 'aspire ps' $dir 'List running AppHosts'
    }

    # dotnet build / test: solutions near the top, else the project files near the top
    $slns = @($files | Where-Object { $_.Name -match '(?i)\.(sln|slnx)$' -and $_.Level -le 1 })
    $buildable = if ($slns.Count) { $slns } else { @($files | Where-Object { $_.Name -match '(?i)\.csproj$' -and $_.Level -le 1 }) }
    foreach ($f in $buildable) {
        $arg = ConvertTo-PSArgument $f.Name
        foreach ($v in @(@('build', ''), @('test', ''), @('clean', ''), @('build', ' -c Release'), @('test', ' -c Release'))) {
            & $task 'dotnet' "dotnet $($v[0]) $($f.Name)$($v[1])" "dotnet $($v[0]) $arg$($v[1])" $f.Dir ''
        }
    }

    # dotnet run: web and executable projects, but not test projects
    $runnable = 0
    foreach ($p in $projects) {
        if ($runnable -ge 12) { break }
        if ($p.Text -match '<IsTestProject>\s*true|Microsoft\.NET\.Test\.Sdk|xunit|MSTest|NUnit') { continue }
        if ($p.Text -notmatch 'Microsoft\.NET\.Sdk\.Web|Aspire\.AppHost\.Sdk|<OutputType>\s*(Win)?Exe') { continue }
        $runnable++
        $name = [IO.Path]::GetFileNameWithoutExtension($p.File.Name)
        & $task 'dotnet' "dotnet run $name" "dotnet run --project $(ConvertTo-PSArgument $p.File.Name)" $p.File.Dir ''
    }

    # npm / yarn / pnpm
    foreach ($f in @($files | Where-Object { $_.Name -eq 'package.json' -and $_.Level -le 2 })) {
        try { $pkg = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $f.Path -Raw) } catch { continue }
        $pm = if (Test-Path -LiteralPath (Join-Path $f.Dir 'pnpm-lock.yaml')) { 'pnpm' }
        elseif (Test-Path -LiteralPath (Join-Path $f.Dir 'yarn.lock')) { 'yarn' }
        else { 'npm' }
        $install = if ($pm -eq 'npm' -and (Test-Path -LiteralPath (Join-Path $f.Dir 'package-lock.json'))) { 'npm ci' } else { "$pm install" }
        & $task $pm $install $install $f.Dir 'Install dependencies'
        if ($pkg.scripts) {
            foreach ($prop in @($pkg.scripts.PSObject.Properties)) {
                $body = [string]$prop.Value
                if ($body.Length -gt 60) { $body = $body.Substring(0, 57) + '...' }
                & $task $pm "$pm run $($prop.Name)" "$pm run $(ConvertTo-PSArgument $prop.Name)" $f.Dir $body
            }
        }
    }

    # PowerShell scripts in the project root and in the usual script folders
    $scriptDirs = @('scripts', 'script', 'tools', 'build')
    $count = 0
    foreach ($f in @($files | Where-Object { $_.Name -like '*.ps1' } | Sort-Object Dir, Name)) {
        $rel = Get-RelativeDir $Base $f.Dir
        if ($rel -and $scriptDirs -notcontains $rel.ToLowerInvariant()) { continue }
        if ($f.Name -match '^[_.]|\.Tests\.ps1$') { continue }
        if ($count -ge 30) { break }
        $count++
        $relFile = if ($rel) { "$rel\$($f.Name)" } else { $f.Name }
        $cmd = if ($relFile -match '^[A-Za-z0-9_.\\-]+$') { ".\$relFile" } else { '& ' + (ConvertTo-PSArgument ".\$relFile") }
        & $task 'script' $relFile $cmd $Base ''
    }

    # docker compose
    foreach ($dir in @($files | Where-Object { $_.Name -match '(?i)^(docker-compose|compose)\.ya?ml$' -and $_.Level -le 1 } | ForEach-Object { $_.Dir } | Select-Object -Unique)) {
        foreach ($v in @(@('up', ''), @('up', ' -d'), @('down', ''), @('logs', ' -f'))) {
            & $task 'docker' "docker compose $($v[0])$($v[1])" "docker compose $($v[0])$($v[1])" $dir ''
        }
    }

    # maven / gradle
    foreach ($f in @($files | Where-Object { $_.Name -ieq 'pom.xml' -and $_.Level -le 1 })) {
        foreach ($v in 'clean install', 'clean package', 'test') { & $task 'maven' "mvn $v" "mvn $v" $f.Dir '' }
    }
    foreach ($f in @($files | Where-Object { $_.Name -ieq 'gradlew.bat' -and $_.Level -le 1 })) {
        foreach ($v in 'build', 'test') { & $task 'gradle' "gradlew $v" ".\gradlew.bat $v" $f.Dir '' }
    }
}

# Your own tasks first, then the detected ones.
function Get-ProjectTaskList([string]$Base) {
    $Base = ConvertTo-NormalPath $Base
    foreach ($c in @(Get-CustomTaskList | Where-Object { (ConvertTo-NormalPath $_.Base) -eq $Base })) {
        [pscustomobject]@{ Kind = 'custom'; Name = $c.Name; Command = $c.Command; Cwd = $Base; Description = ''; Source = 'custom' }
    }
    Get-DetectedTask $Base
}

function Get-TaskUsageKey($Task) { "task:$($Task.Cwd)|$($Task.Command)" }

# Picker items for the tasks of a project: Name is the label, Path holds the searchable detail text.
function Get-ProjectTaskItem([string]$Base) {
    $usage = Get-ProjectUsage
    $order = 0
    foreach ($t in @(Get-ProjectTaskList $Base)) {
        $rel = Get-RelativeDir $Base $t.Cwd
        $parts = @()
        if ($t.Command -ne $t.Name) { $parts += $t.Command }
        if ($rel) { $parts += "in $rel" }
        if ($t.Description) { $parts += "- $($t.Description)" }
        [pscustomobject]@{
            Name        = $t.Name
            Path        = ($parts -join '  ')
            Exists      = $true
            Kind        = $t.Kind
            Source      = $t.Source
            Command     = $t.Command
            Cwd         = $t.Cwd
            Description = $t.Description
            Frecency    = Get-Frecency $usage[(Get-TaskUsageKey $t).ToLowerInvariant()]
            Order       = $order++
        }
    }
}

#endregion

#region Public commands

function Add-ProjectFolder {
    <#
    .SYNOPSIS
        Adds a folder to the ProjectJump list.
    .DESCRIPTION
        Saves the folder (the current directory by default) so it shows up in the Ctrl+K picker.
        Duplicates are ignored. Accepts pipeline input, e.g. Get-ChildItem -Directory | Add-ProjectFolder.
    .EXAMPLE
        pja
        Adds the current directory.
    .EXAMPLE
        Get-ChildItem D:\source\repos -Directory | Add-ProjectFolder
        Adds every folder under D:\source\repos.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path = (Get-Location).ProviderPath
    )
    process {
        $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { Write-Error "Not a folder: $full"; return }
        $list = @(Get-ProjectFolderList)
        if ($list -contains $full) { Write-Host "Already saved: $full" -ForegroundColor DarkGray; return }
        Save-ProjectFolderList (@($list) + $full)
        Write-Host "Added: $full" -ForegroundColor Green
    }
}

function Remove-ProjectFolder {
    <#
    .SYNOPSIS
        Removes a folder from the ProjectJump list.
    .DESCRIPTION
        Removes the given path from the saved list. Without -Path, opens the picker to choose the entry to remove.
        Only the list entry is removed; the folder on disk is never touched. Folders found by scanning a
        project root can't be removed individually; use Remove-ProjectRoot instead.
    .EXAMPLE
        pjr
        Pick an entry interactively and remove it.
    .EXAMPLE
        Remove-ProjectFolder D:\source\repos\old-project
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Position = 0)][string]$Path)
    $list = @(Get-ProjectFolderList)
    if (-not $Path) {
        $r = Show-ProjectPicker -Items (Get-ProjectItemList -Saved $list) -Title 'Remove saved folder' -AllowMissing -SelectOnly
        if (-not $r) { return }
        $Path = $r.Path
    }
    $remaining = @($list | Where-Object { $_ -ne $Path.TrimEnd('\') -and $_ -ne $Path })
    if ($remaining.Count -eq $list.Count) { Write-Warning "Not in list: $Path"; return }
    if ($PSCmdlet.ShouldProcess($Path, 'Remove from ProjectJump list')) {
        Save-ProjectFolderList $remaining
        Write-Host "Removed: $Path" -ForegroundColor Yellow
    }
}

function Get-ProjectFolder {
    <#
    .SYNOPSIS
        Lists the ProjectJump folders.
    .DESCRIPTION
        Returns one object per saved folder with Name, Exists, Source, Frecency and Path.
        With -All, folders found by scanning project roots and folders you keep visiting
        (Source 'scanned' and 'visited') are included too.
    .EXAMPLE
        Get-ProjectFolder | Where-Object { -not $_.Exists } | ForEach-Object { Remove-ProjectFolder $_.Path }
        Removes saved entries whose folders no longer exist.
    .EXAMPLE
        Get-ProjectFolder -All | Sort-Object Frecency -Descending | Select-Object -First 10
        Your ten most used projects.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch]$All)
    $index = if ($All) { Get-ProjectIndex } else { @() }
    Get-ProjectItemList -Saved (Get-ProjectFolderList) -Scanned $index -IncludeVisited:$All |
        Select-Object Name, Exists, Source, @{ n = 'Frecency'; e = { [Math]::Round($_.Frecency, 2) } }, Path
}

function Add-ProjectRoot {
    <#
    .SYNOPSIS
        Adds a folder that is scanned for git repositories.
    .DESCRIPTION
        Every git repository found under the root (up to -Depth levels deep) shows up in the picker
        without having to add it with pja. The scan result is cached and refreshed every 60 minutes
        (PROJECTJUMP_INDEX_TTL), when roots change, or when you press Ctrl+R in the picker.
    .EXAMPLE
        Add-ProjectRoot D:\source\repos
    .EXAMPLE
        Add-ProjectRoot ~\work -Depth 2
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path = (Get-Location).ProviderPath,
        [ValidateRange(0, 10)][int]$Depth = 3
    )
    process {
        $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { Write-Error "Not a folder: $full"; return }
        $roots = @(Get-ProjectRootList | Where-Object { $_.Path -ne $full })
        Save-ProjectRootList (@($roots) + [pscustomobject]@{ Path = $full; Depth = $Depth })
        $count = @(Get-ProjectIndex -Force).Count
        Write-Host "Root added: $full (depth $Depth). $count repositories indexed." -ForegroundColor Green
    }
}

function Remove-ProjectRoot {
    <#
    .SYNOPSIS
        Stops scanning a project root.
    .EXAMPLE
        Remove-ProjectRoot D:\source\repos
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $roots = @(Get-ProjectRootList)
    $remaining = @($roots | Where-Object { $_.Path -ne $Path.TrimEnd('\') -and $_.Path -ne $Path })
    if ($remaining.Count -eq $roots.Count) { Write-Warning "Not a project root: $Path"; return }
    if ($PSCmdlet.ShouldProcess($Path, 'Remove ProjectJump root')) {
        Save-ProjectRootList $remaining
        [void](Get-ProjectIndex -Force)
        Write-Host "Root removed: $Path" -ForegroundColor Yellow
    }
}

function Get-ProjectRoot {
    <#
    .SYNOPSIS
        Lists the folders that are scanned for git repositories.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    Get-ProjectRootList
}

function Update-ProjectIndex {
    <#
    .SYNOPSIS
        Rescans the project roots now.
    .DESCRIPTION
        The scan normally refreshes automatically; use this after cloning new repositories
        (or press Ctrl+R in the picker).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess($script:IndexFile, 'Rescan project roots')) {
        $count = @(Get-ProjectIndex -Force).Count
        Write-Host "$count repositories indexed." -ForegroundColor Green
    }
}

function Get-ProjectTask {
    <#
    .SYNOPSIS
        Lists the tasks ProjectJump finds in a project.
    .DESCRIPTION
        Detects what you can run in the project that contains -Path (the current folder by default):
        make targets, Aspire AppHosts, dotnet build/test/run, npm/yarn/pnpm scripts, PowerShell scripts in the
        project root or scripts/tools folders, docker compose, maven and gradle, plus the tasks you added with
        Add-ProjectTask. Nothing is run. The project is the nearest parent folder that contains .git.
    .EXAMPLE
        Get-ProjectTask | Format-Table Name, Kind, Cwd
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Position = 0)][string]$Path = (Get-Location).ProviderPath)
    $base = Resolve-ProjectBase (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    Get-ProjectTaskItem $base |
        Select-Object Name, Kind, Command, Cwd, Source, Description, @{ n = 'Frecency'; e = { [Math]::Round($_.Frecency, 2) } }
}

function Add-ProjectTask {
    <#
    .SYNOPSIS
        Saves a command as a task for a project.
    .DESCRIPTION
        Your own tasks show up first in the Ctrl+T picker of the project that contains -Path (the current folder
        by default). They run in the project's root folder. The tasks are stored in your ProjectJump data folder,
        not in the repository. Adding a task with an existing name replaces it.
    .EXAMPLE
        Add-ProjectTask logs 'Get-ChildItem .\logs -Filter *.log | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Wait -Tail 20'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][string]$Command,
        [string]$Path = (Get-Location).ProviderPath
    )
    if ($Name -match "[\t\r\n]" -or $Command -match "[\t\r\n]") { Write-Error 'Name and Command cannot contain tabs or line breaks.'; return }
    $base = Resolve-ProjectBase (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $others = @(Get-CustomTaskList | Where-Object { -not ((ConvertTo-NormalPath $_.Base) -eq $base -and $_.Name -eq $Name) })
    Save-CustomTaskList (@($others) + [pscustomobject]@{ Base = $base; Name = $Name; Command = $Command })
    Write-Host "Task '$Name' saved for $base" -ForegroundColor Green
}

function Remove-ProjectTask {
    <#
    .SYNOPSIS
        Removes a task you added with Add-ProjectTask.
    .EXAMPLE
        Remove-ProjectTask logs
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [string]$Path = (Get-Location).ProviderPath
    )
    $base = Resolve-ProjectBase (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $all = @(Get-CustomTaskList)
    $remaining = @($all | Where-Object { -not ((ConvertTo-NormalPath $_.Base) -eq $base -and $_.Name -eq $Name) })
    if ($remaining.Count -eq $all.Count) { Write-Warning "No task named '$Name' for $base"; return }
    if ($PSCmdlet.ShouldProcess("$Name ($base)", 'Remove ProjectJump task')) {
        Save-CustomTaskList $remaining
        Write-Host "Task '$Name' removed." -ForegroundColor Yellow
    }
}

#endregion

#region Console encoding

# [Console]::Write and PSReadLine's InvokePrompt() encode through [Console]::OutputEncoding, which is often
# a legacy code page such as 437. Nerd Font glyphs (oh-my-posh, Terminal-Icons) then print as '?'.
# Switch to UTF-8 while drawing and restore the previous encoding afterwards.
function Enter-Utf8Output {
    $previous = [Console]::OutputEncoding
    if ($previous.CodePage -ne 65001) {
        try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { Write-Verbose "ProjectJump: cannot switch to UTF-8: $_" }
    }
    $previous
}

function Exit-Utf8Output($Previous) {
    if ($Previous -and [Console]::OutputEncoding.CodePage -ne $Previous.CodePage) {
        try { [Console]::OutputEncoding = $Previous } catch { Write-Verbose "ProjectJump: cannot restore output encoding: $_" }
    }
}

#endregion

#region Picker

# Thin wrappers around the console so tests can drive the picker with simulated keys.
function Read-PickerKey { [Console]::ReadKey($true) }
function Write-PickerOutput([string]$Text) { [Console]::Write($Text) }
function Get-PickerSize {
    try { @{ Width = [Console]::WindowWidth; Height = [Console]::WindowHeight } } catch { @{ Width = 120; Height = 30 } }
}

# Items for the folder list: saved first, then scanned repos, then folders you keep visiting (-IncludeVisited).
function Get-ProjectItemList([string[]]$Saved, [string[]]$Scanned, [switch]$IncludeVisited) {
    $usage = Get-ProjectUsage
    $visited = @()
    if ($IncludeVisited) {
        $visited = @($usage.Values | Where-Object { $_.Path -and -not $_.Path.StartsWith('task:') -and [int]$_.Hits -ge $script:VisitedMinHits } |
                Sort-Object { - [int]$_.Hits } | ForEach-Object { $_.Path })
    }
    $seen = @{}
    $order = 0
    foreach ($source in 'saved', 'scanned', 'visited') {
        $paths = switch ($source) { 'saved' { $Saved } 'scanned' { $Scanned } default { $visited } }
        foreach ($p in @($paths)) {
            if (-not $p) { continue }
            $key = $p.TrimEnd('\').ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $exists = Test-Path -LiteralPath $p -PathType Container
            if ($source -eq 'visited' -and -not $exists) { continue }
            $seen[$key] = $true
            [pscustomobject]@{
                Path     = $p
                Name     = Split-Path $p -Leaf
                Exists   = $exists
                Source   = $source
                Frecency = Get-Frecency $usage[$p.ToLowerInvariant()]
                Order    = $order++
            }
        }
    }
}

# Items for browsing inside a folder: the folder itself ('.', always first) and its subfolders.
function Get-SubfolderItem([string]$Dir) {
    $usage = Get-ProjectUsage
    [pscustomobject]@{
        Path = $Dir; Name = '. (this folder)'; Exists = $true; Source = 'browse'; IsSelf = $true
        Frecency = [double]::MaxValue; Order = -1
    }
    $order = 0
    foreach ($s in @(Get-ScanSubdirectory $Dir | Sort-Object)) {
        [pscustomobject]@{
            Path = $s; Name = [IO.Path]::GetFileName($s); Exists = $true; Source = 'browse'; IsSelf = $false
            Frecency = Get-Frecency $usage[$s.ToLowerInvariant()]; Order = $order++
        }
    }
}

# Lower score = better match; $null = no match. Every space-separated term must match.
function Get-MatchScore($Item, [string[]]$Terms) {
    $score = 0
    foreach ($t in $Terms) {
        $name = $Item.Name.ToLowerInvariant()
        $path = $Item.Path.ToLowerInvariant()
        if ($name.StartsWith($t)) { $score += 0; continue }
        $i = $name.IndexOf($t)
        if ($i -ge 0) { $score += 10 + $i; continue }
        $i = $path.IndexOf($t)
        if ($i -ge 0) { $score += 100 + ($path.Length - $i); continue }
        # fuzzy: characters in order, penalise gaps
        $pos = -1; $gaps = 0; $ok = $true
        foreach ($c in $t.ToCharArray()) {
            $n = $path.IndexOf($c, $pos + 1)
            if ($n -lt 0) { $ok = $false; break }
            if ($pos -ge 0) { $gaps += $n - $pos - 1 }
            $pos = $n
        }
        if (-not $ok) { return $null }
        $score += 1000 + $gaps
    }
    $score
}

# Returns the items matching $Query, best match first. Ties (and an empty query) go to the most
# frequently/recently used folder, then to the saved order.
function Find-ProjectMatch($Items, [string]$Query) {
    $byUse = @{ Expression = { if ($null -ne $_.Frecency) { $_.Frecency } else { 0 } }; Descending = $true }
    $byOrder = @{ Expression = { $_.Order }; Descending = $false }
    $terms = @($Query.ToLowerInvariant().Split([char[]]' ', [StringSplitOptions]::RemoveEmptyEntries))
    if ($terms.Count -eq 0) { return @($Items | Sort-Object $byUse, $byOrder) }
    @($Items | ForEach-Object { $s = Get-MatchScore $_ $terms; if ($null -ne $s) { $_ | Add-Member -NotePropertyName Score -NotePropertyValue $s -Force -PassThru } } |
        Sort-Object @{ Expression = { $_.Score } }, $byUse, $byOrder)
}

function Format-PickerRow($Item, [bool]$Selected, [int]$Width) {
    $e = [char]27
    $marker = if ($Selected) { '> ' } else { '  ' }
    $name = $Item.Name
    $avail = $Width - $marker.Length - $name.Length - 2
    $path = $Item.Path
    if ($avail -lt 4) { $path = '' }
    elseif ($path.Length -gt $avail) { $path = [string][char]0x2026 + $path.Substring($path.Length - $avail + 1) }
    if ($marker.Length + $name.Length -gt $Width) { $name = $name.Substring(0, [Math]::Max(0, $Width - $marker.Length)) }

    $nameColor = if ($Item.Exists) { "$e[1m" } else { "$e[1;31m" }
    $row = "$marker$nameColor$name$e[22;39m  $e[2m$path$e[22m"
    if ($Selected) { "$e[7m$row$e[27m" } else { $row }
}

# Shows the picker. Returns @{ Path; Action; Item } where Action is
# cd | tab | split | editor | explorer | run | refresh, or $null on Esc.
function Show-ProjectPicker {
    param(
        $Items,
        [string]$Title = 'Projects',
        [string]$EmptyMessage,
        [switch]$AllowMissing,
        [switch]$SelectOnly,
        [switch]$Tasks
    )
    $e = [char]27
    $items = @($Items)
    $canBrowse = -not $SelectOnly -and -not $Tasks
    $browse = $null   # while browsing: @{ Root; Dir; Saved = the project list state to return to }
    $query = ''; $sel = 0; $offset = 0; $msg = ''
    if (-not $EmptyMessage) { $EmptyMessage = "No folders yet. Run 'pja' in a project folder, or 'Add-ProjectRoot <folder>' to scan for repos." }
    $help = if ($SelectOnly) { 'Enter: select | Esc: cancel' }
    elseif ($Tasks) { 'Enter: run | Shift+Enter: new tab | Ctrl+S: split pane | Esc: cancel' }
    else { 'Enter: cd | Right: browse | Shift+Enter: tab | Ctrl+S: split | Ctrl+O: editor | Ctrl+E: explorer | Ctrl+R: rescan | Esc' }
    $browseHelp = 'Enter: cd | Right: open | Left: back | Shift+Enter: tab | Ctrl+S: split | Ctrl+O: editor | Esc'

    # Draw on the alternate screen so the main buffer (and PSReadLine's view of it) stays untouched.
    $encoding = Enter-Utf8Output
    Write-PickerOutput "$e[?1049h"
    try {
        while ($true) {
            # '.' (the folder being browsed) is only offered while the filter is empty
            $active = if ($browse -and $query) { @($items | Where-Object { -not $_.IsSelf }) } else { $items }
            $hits = @(Find-ProjectMatch $active $query)

            $size = Get-PickerSize
            $width = [Math]::Max(10, $size.Width - 1)
            $rows = [Math]::Max(1, $size.Height - 3)
            if ($sel -ge $hits.Count) { $sel = [Math]::Max(0, $hits.Count - 1) }
            if ($sel -lt 0) { $sel = 0 }
            if ($sel -lt $offset) { $offset = $sel }
            if ($sel -ge $offset + $rows) { $offset = $sel - $rows + 1 }

            if ($browse) {
                $where = $browse.Dir
                $max = [Math]::Max(10, [int]($width * 0.55))
                if ($where.Length -gt $max) { $where = [string][char]0x2026 + $where.Substring($where.Length - $max + 1) }
                $header = "$where  $($hits.Count)/$($active.Count)   $browseHelp"
            }
            else { $header = "$Title  $($hits.Count)/$($active.Count)   $help" }
            if ($header.Length -gt $width) { $header = $header.Substring(0, $width) }
            $sb = [Text.StringBuilder]::new()
            [void]$sb.Append("$e[H$e[2m$header$e[22m$e[K`r`n")
            [void]$sb.Append("$e[36m>$e[39m $query$e[K`r`n")
            if ($items.Count -eq 0) {
                [void]$sb.Append("$e[33m  $EmptyMessage$e[39m$e[K`r`n")
            }
            elseif ($msg) {
                [void]$sb.Append("$e[31m  $msg$e[39m$e[K`r`n"); $rows = [Math]::Max(1, $rows - 1)
            }
            $end = [Math]::Min($hits.Count, $offset + $rows)
            for ($i = $offset; $i -lt $end; $i++) {
                [void]$sb.Append((Format-PickerRow $hits[$i] ($i -eq $sel) $width)).Append("$e[K`r`n")
            }
            [void]$sb.Append("$e[J$e[2;$($query.Length + 3)H")
            Write-PickerOutput $sb.ToString()

            $k = Read-PickerKey
            $ctrl = [bool]($k.Modifiers -band [ConsoleModifiers]::Control)
            $shift = [bool]($k.Modifiers -band [ConsoleModifiers]::Shift)
            $msg = ''
            $action = $null
            if ($ctrl -and $k.Key -in 'K', 'P') { $sel--; continue }
            if ($ctrl -and $k.Key -in 'J', 'N') { $sel++; continue }
            if ($ctrl -and $k.Key -eq 'U') { $query = ''; $sel = 0; continue }
            if ($ctrl -and $k.Key -eq 'R' -and $canBrowse -and -not $browse) { return [pscustomobject]@{ Path = $null; Action = 'refresh'; Item = $null } }
            if ($ctrl -and -not $SelectOnly) {
                switch ($k.Key) {
                    'S' { $action = 'split' }
                    'O' { if (-not $Tasks) { $action = 'editor' } }
                    'E' { if (-not $Tasks) { $action = 'explorer' } }
                }
            }
            if (-not $action) {
                switch ($k.Key) {
                    'Escape'    { return $null }
                    'UpArrow'   { $sel--; continue }
                    'DownArrow' { $sel++; continue }
                    'Tab'       { $sel++; continue }
                    'PageUp'    { $sel -= $rows; continue }
                    'PageDown'  { $sel += $rows; continue }
                    'Home'      { $sel = 0; continue }
                    'End'       { $sel = $hits.Count - 1; continue }
                    'Backspace' { if ($query.Length) { $query = $query.Substring(0, $query.Length - 1); $sel = 0 }; continue }
                    'RightArrow' {
                        if ($canBrowse -and $hits.Count) {
                            $pick = $hits[$sel]
                            if ($pick.IsSelf) { continue }
                            if (-not $pick.Exists) { $msg = "Folder not found: $($pick.Path)  (remove it with 'pjr')"; continue }
                            if ($browse) { $browse.Dir = $pick.Path }
                            else { $browse = @{ Root = $pick.Path; Dir = $pick.Path; Saved = @{ Items = $items; Query = $query; Sel = $sel; Offset = $offset } } }
                            $items = @(Get-SubfolderItem $browse.Dir)
                            $query = ''; $sel = 0; $offset = 0
                        }
                        continue
                    }
                    'LeftArrow' {
                        if ($browse) {
                            if ((ConvertTo-NormalPath $browse.Dir) -ieq (ConvertTo-NormalPath $browse.Root)) {
                                $items = $browse.Saved.Items; $query = $browse.Saved.Query
                                $sel = $browse.Saved.Sel; $offset = $browse.Saved.Offset
                                $browse = $null
                            }
                            else {
                                $child = $browse.Dir
                                $browse.Dir = Split-Path $child -Parent
                                $items = @(Get-SubfolderItem $browse.Dir)
                                $query = ''; $sel = 0; $offset = 0
                                $ranked = @(Find-ProjectMatch $items '')
                                for ($i = 0; $i -lt $ranked.Count; $i++) { if ($ranked[$i].Path -ieq $child) { $sel = $i; break } }
                            }
                        }
                        continue
                    }
                    'Enter'     { $action = if ($shift -and -not $SelectOnly) { 'tab' } elseif ($Tasks) { 'run' } else { 'cd' } }
                    default {
                        if (-not $ctrl -and $k.KeyChar -and -not [char]::IsControl($k.KeyChar)) { $query += $k.KeyChar; $sel = 0 }
                    }
                }
            }
            if (-not $action -or $hits.Count -eq 0) { continue }
            $pick = $hits[$sel]
            if (-not $pick.Exists -and -not $AllowMissing) { $msg = "Folder not found: $($pick.Path)  (remove it with 'pjr')"; continue }
            return [pscustomobject]@{ Path = $pick.Path; Action = $action; Item = $pick }
        }
    }
    finally {
        Write-PickerOutput "$e[?1049l"
        Exit-Utf8Output $encoding
    }
}

#endregion

#region Actions

function Open-ProjectTab([string]$Path, [switch]$Split) {
    if ($env:WT_SESSION -and (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        $verb = if ($Split) { 'split-pane' } else { 'new-tab' }
        # ';' separates commands in wt arguments, so escape it
        $title = (Split-Path $Path -Leaf) -replace ';', '\;'
        & wt.exe -w 0 $verb --title $title --suppressApplicationTitle -d ($Path -replace ';', '\;')
    }
    else {
        Start-Process (Get-Process -Id $PID).Path -WorkingDirectory $Path
    }
}

function Open-ProjectEditor([string]$Path) {
    $editor = if ($env:PROJECTJUMP_EDITOR) { $env:PROJECTJUMP_EDITOR } else { 'code' }
    if (Get-Command $editor -ErrorAction SilentlyContinue) { & $editor $Path }
    else { Invoke-Item -LiteralPath $Path }
}

# Runs a picker action other than 'cd'. Returns $true when it handled the action.
function Invoke-ProjectAction($Result) {
    switch ($Result.Action) {
        'tab'      { Open-ProjectTab $Result.Path }
        'split'    { Open-ProjectTab $Result.Path -Split }
        'editor'   { Open-ProjectEditor $Result.Path }
        'explorer' { Invoke-Item -LiteralPath $Result.Path }
        default    { return $false }
    }
    Add-ProjectUsage $Result.Path
    $true
}

# Shows the picker over saved, scanned and visited folders, handling Ctrl+R rescans.
# Returns the final result or $null.
function Select-Project {
    $force = $false
    while ($true) {
        $items = Get-ProjectItemList -Saved (Get-ProjectFolderList) -Scanned (Get-ProjectIndex -Force:$force) -IncludeVisited
        $r = Show-ProjectPicker -Items $items
        if (-not $r -or $r.Action -ne 'refresh') { return $r }
        $force = $true
    }
}

# Opens a task in a new Windows Terminal tab or pane (or a new console window outside Windows Terminal).
# The command is passed encoded, so no quoting or ';' in it can break out.
function Open-TaskPane($Task, [switch]$Split) {
    $exe = (Get-Process -Id $PID).Path
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Task.Command))
    $cwd = ConvertTo-NormalPath $Task.Cwd
    if ($env:WT_SESSION -and (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        $verb = if ($Split) { 'split-pane' } else { 'new-tab' }
        $title = $Task.Name -replace ';', '\;'
        & wt.exe -w 0 $verb --title $title --suppressApplicationTitle -d ($cwd -replace ';', '\;') $exe -NoLogo -NoExit -EncodedCommand $encoded
    }
    else {
        Start-Process $exe -WorkingDirectory $cwd -ArgumentList @('-NoLogo', '-NoExit', '-EncodedCommand', $encoded)
    }
}

# Runs a task picker action other than 'run'. Returns $true when it handled the action.
function Invoke-TaskAction($Result) {
    switch ($Result.Action) {
        'tab'   { Open-TaskPane $Result.Item }
        'split' { Open-TaskPane $Result.Item -Split }
        default { return $false }
    }
    Add-ProjectUsage (Get-TaskUsageKey $Result.Item)
    $true
}

# The line to type at the prompt to run a task here: moves to the task's folder first when needed.
function Format-TaskCommandLine($Task) {
    $here = ConvertTo-NormalPath (Get-Location).ProviderPath
    if ((ConvertTo-NormalPath $Task.Cwd) -ieq $here) { return $Task.Command }
    "Set-Location -LiteralPath $(ConvertTo-PSArgument $Task.Cwd); $($Task.Command)"
}

# Shows the task picker for the project around the current folder. Returns the result or $null.
function Select-ProjectTask {
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return $null }
    $base = Resolve-ProjectBase $location.ProviderPath
    $items = @(Get-ProjectTaskItem $base)
    Show-ProjectPicker -Items $items -Title ('Tasks in ' + (Split-Path $base -Leaf)) -Tasks `
        -EmptyMessage "No tasks found here. Save your own with: Add-ProjectTask <name> '<command>'"
}

function Invoke-ProjectJump {
    <#
    .SYNOPSIS
        Opens the ProjectJump picker.
    .DESCRIPTION
        Type to filter your saved, scanned and often visited project folders; the ones you use most are listed
        first. Enter changes to the selected folder; Right opens it to browse its subfolders (Left goes back);
        Shift+Enter opens it in a new Windows Terminal tab, Ctrl+S in a split pane, Ctrl+O in your editor,
        Ctrl+E in File Explorer. Ctrl+R rescans project roots and Esc cancels. This is what the Ctrl+K key
        binding runs.
    .EXAMPLE
        pj
    #>
    [CmdletBinding()]
    param()
    $r = Select-Project
    if (-not $r) { return }
    if (Invoke-ProjectAction $r) { return }
    Set-Location -LiteralPath $r.Path
    Add-ProjectUsage $r.Path
}

function Invoke-ProjectTask {
    <#
    .SYNOPSIS
        Opens the task picker for the current project.
    .DESCRIPTION
        Lists what you can run in the project around the current folder (see Get-ProjectTask). Enter runs the
        task here, Shift+Enter in a new Windows Terminal tab, Ctrl+S in a split pane. With -Name, the best
        matching task runs right away without the picker. This is what the Ctrl+T key binding opens (the key
        binding types the command at the prompt instead, so it lands in your history).
    .EXAMPLE
        pjt
    .EXAMPLE
        pjt 'aspire stop'
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    if ($Name) {
        $base = Resolve-ProjectBase (Get-Location).ProviderPath
        $match = @(Find-ProjectMatch @(Get-ProjectTaskItem $base) $Name | Select-Object -First 1)
        if (-not $match.Count) { Write-Warning "No task matches '$Name'."; return }
        $r = [pscustomobject]@{ Action = 'run'; Item = $match[0] }
    }
    else {
        $r = Select-ProjectTask
        if (-not $r) { return }
        if (Invoke-TaskAction $r) { return }
    }
    $task = $r.Item
    Add-ProjectUsage (Get-TaskUsageKey $task)
    if ((ConvertTo-NormalPath $task.Cwd) -ine (ConvertTo-NormalPath (Get-Location).ProviderPath)) { Set-Location -LiteralPath $task.Cwd }
    & ([scriptblock]::Create($task.Command))
}

function Set-ProjectJumpKeyHandler {
    <#
    .SYNOPSIS
        Binds the ProjectJump picker to a PSReadLine key chord.
    .DESCRIPTION
        The module binds Ctrl+K on import. Call this to use a different chord. Set the environment
        variable PROJECTJUMP_NO_KEYBINDING=1 before importing the module to skip the default bindings.
    .EXAMPLE
        Set-ProjectJumpKeyHandler -Chord 'Ctrl+g'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Chord = 'Ctrl+k')
    if (-not $PSCmdlet.ShouldProcess($Chord, 'Bind ProjectJump picker')) { return }
    Set-PSReadLineKeyHandler -Chord $Chord -BriefDescription 'ProjectJump' `
        -Description 'Pick a project folder (Enter: cd, Right: browse, Shift+Enter: new tab)' -ScriptBlock {
        $r = Select-Project
        if (-not $r) { return }
        if (Invoke-ProjectAction $r) { return }
        Set-Location -LiteralPath $r.Path
        Add-ProjectUsage $r.Path
        # InvokePrompt renders through [Console]::OutputEncoding; without UTF-8, prompt glyphs turn into '?'
        $encoding = Enter-Utf8Output
        try { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt() }
        finally { Exit-Utf8Output $encoding }
    }
}

function Set-ProjectTaskKeyHandler {
    <#
    .SYNOPSIS
        Binds the ProjectJump task picker to a PSReadLine key chord.
    .DESCRIPTION
        The module binds Ctrl+T on import. Choosing a task with Enter types its command at the prompt and
        runs it, so it appears in your command history. Call this to use a different chord. Set the environment
        variable PROJECTJUMP_NO_KEYBINDING=1 before importing the module to skip the default bindings.
    .EXAMPLE
        Set-ProjectTaskKeyHandler -Chord 'Ctrl+g'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Chord = 'Ctrl+t')
    if (-not $PSCmdlet.ShouldProcess($Chord, 'Bind ProjectJump task picker')) { return }
    Set-PSReadLineKeyHandler -Chord $Chord -BriefDescription 'ProjectTask' `
        -Description 'Pick a task to run in this project (Enter: run, Shift+Enter: new tab)' -ScriptBlock {
        $r = Select-ProjectTask
        if (-not $r) { return }
        if (Invoke-TaskAction $r) { return }
        Add-ProjectUsage (Get-TaskUsageKey $r.Item)
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert((Format-TaskCommandLine $r.Item))
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }
}

#endregion

if (-not $env:PROJECTJUMP_NO_KEYBINDING -and (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue)) {
    try { Set-ProjectJumpKeyHandler; Set-ProjectTaskKeyHandler } catch { Write-Verbose "ProjectJump: key binding skipped: $_" }
}

Set-Alias pja Add-ProjectFolder
Set-Alias pjr Remove-ProjectFolder
Set-Alias pj  Invoke-ProjectJump
Set-Alias pjt Invoke-ProjectTask

Export-ModuleMember -Function Add-ProjectFolder, Remove-ProjectFolder, Get-ProjectFolder, Invoke-ProjectJump, Set-ProjectJumpKeyHandler,
    Add-ProjectRoot, Remove-ProjectRoot, Get-ProjectRoot, Update-ProjectIndex,
    Get-ProjectTask, Add-ProjectTask, Remove-ProjectTask, Invoke-ProjectTask, Set-ProjectTaskKeyHandler -Alias pja, pjr, pj, pjt

