# ProjectJump - Ctrl+K type-ahead picker for project folders.
#   Enter        -> cd into the folder in the current tab
#   Shift+Enter  -> open the folder in a new Windows Terminal tab
#   Ctrl+S       -> open the folder in a new split pane
#   Ctrl+O       -> open the folder in your editor (VS Code by default)
#   Ctrl+E       -> open the folder in File Explorer
#   Ctrl+R       -> rescan project roots
#   Esc          -> cancel
# Folders come from the saved list (pja / pjr) and from scanning project roots (Add-ProjectRoot).
# Folders you open most and most recently are listed first.

$script:StoreDir = if ($env:PROJECTJUMP_HOME) { $env:PROJECTJUMP_HOME } else {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.projectjump'
}
$script:StoreFile = Join-Path $script:StoreDir 'folders.txt'
$script:RootsFile = Join-Path $script:StoreDir 'roots.txt'
$script:IndexFile = Join-Path $script:StoreDir 'index.txt'
$script:UsageFile = Join-Path $script:StoreDir 'usage.json'
$script:SkipDirs = @('node_modules', 'bin', 'obj', 'packages', 'dist', 'out', 'target', 'venv', '__pycache__')

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

# Usage is keyed by lower-case path: @{ Path; Hits; Last (UTC ticks) }
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
        try { $subs = [IO.Directory]::GetDirectories($entry.Dir) } catch { continue }
        foreach ($s in $subs) {
            $name = [IO.Path]::GetFileName($s)
            if ($name.StartsWith('.') -or $script:SkipDirs -contains $name) { continue }
            try { if ([IO.File]::GetAttributes($s) -band [IO.FileAttributes]::ReparsePoint) { continue } } catch { continue }
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
        With -All, folders found by scanning project roots are included too.
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
    Get-ProjectItemList -Saved (Get-ProjectFolderList) -Scanned $index |
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

#endregion

#region Picker

function Get-ProjectItemList([string[]]$Saved, [string[]]$Scanned) {
    $usage = Get-ProjectUsage
    $seen = @{}
    $order = 0
    foreach ($source in 'saved', 'scanned') {
        $paths = if ($source -eq 'saved') { $Saved } else { $Scanned }
        foreach ($p in @($paths)) {
            if (-not $p) { continue }
            $key = $p.TrimEnd('\').ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [pscustomobject]@{
                Path     = $p
                Name     = Split-Path $p -Leaf
                Exists   = Test-Path -LiteralPath $p -PathType Container
                Source   = $source
                Frecency = Get-Frecency $usage[$p.ToLowerInvariant()]
                Order    = $order++
            }
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

# Returns @{ Path; Action } where Action is cd | tab | split | editor | explorer | refresh, or $null on Esc.
function Show-ProjectPicker {
    param($Items, [string]$Title = 'Projects', [switch]$AllowMissing, [switch]$SelectOnly)
    $e = [char]27
    $items = @($Items)
    $query = ''; $sel = 0; $offset = 0; $msg = ''
    $help = if ($SelectOnly) { 'Enter: select | Esc: cancel' } else {
        'Enter: cd | Shift+Enter: tab | Ctrl+S: split | Ctrl+O: editor | Ctrl+E: explorer | Ctrl+R: rescan | Esc'
    }

    # Draw on the alternate screen so the main buffer (and PSReadLine's view of it) stays untouched.
    [Console]::Write("$e[?1049h")
    try {
        while ($true) {
            $hits = @(Find-ProjectMatch $items $query)

            $width = [Math]::Max(10, [Console]::WindowWidth - 1)
            $rows = [Math]::Max(1, [Console]::WindowHeight - 3)
            if ($sel -ge $hits.Count) { $sel = [Math]::Max(0, $hits.Count - 1) }
            if ($sel -lt 0) { $sel = 0 }
            if ($sel -lt $offset) { $offset = $sel }
            if ($sel -ge $offset + $rows) { $offset = $sel - $rows + 1 }

            $header = "$Title  $($hits.Count)/$($items.Count)   $help"
            if ($header.Length -gt $width) { $header = $header.Substring(0, $width) }
            $sb = [Text.StringBuilder]::new()
            [void]$sb.Append("$e[H$e[2m$header$e[22m$e[K`r`n")
            [void]$sb.Append("$e[36m>$e[39m $query$e[K`r`n")
            if ($items.Count -eq 0) {
                [void]$sb.Append("$e[33m  No folders yet. Run 'pja' in a project folder, or 'Add-ProjectRoot <folder>' to scan for repos.$e[39m$e[K`r`n")
            }
            elseif ($msg) {
                [void]$sb.Append("$e[31m  $msg$e[39m$e[K`r`n"); $rows = [Math]::Max(1, $rows - 1)
            }
            $end = [Math]::Min($hits.Count, $offset + $rows)
            for ($i = $offset; $i -lt $end; $i++) {
                [void]$sb.Append((Format-PickerRow $hits[$i] ($i -eq $sel) $width)).Append("$e[K`r`n")
            }
            [void]$sb.Append("$e[J$e[2;$($query.Length + 3)H")
            [Console]::Write($sb.ToString())

            $k = [Console]::ReadKey($true)
            $ctrl = [bool]($k.Modifiers -band [ConsoleModifiers]::Control)
            $shift = [bool]($k.Modifiers -band [ConsoleModifiers]::Shift)
            $msg = ''
            $action = $null
            if ($ctrl -and $k.Key -in 'K', 'P') { $sel--; continue }
            if ($ctrl -and $k.Key -in 'J', 'N') { $sel++; continue }
            if ($ctrl -and $k.Key -eq 'U') { $query = ''; $sel = 0; continue }
            if ($ctrl -and $k.Key -eq 'R' -and -not $SelectOnly) { return [pscustomobject]@{ Path = $null; Action = 'refresh' } }
            if ($ctrl -and -not $SelectOnly) {
                switch ($k.Key) { 'S' { $action = 'split' } 'O' { $action = 'editor' } 'E' { $action = 'explorer' } }
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
                    'Enter'     { $action = if ($shift -and -not $SelectOnly) { 'tab' } else { 'cd' } }
                    default {
                        if (-not $ctrl -and $k.KeyChar -and -not [char]::IsControl($k.KeyChar)) { $query += $k.KeyChar; $sel = 0 }
                    }
                }
            }
            if (-not $action -or $hits.Count -eq 0) { continue }
            $pick = $hits[$sel]
            if (-not $pick.Exists -and -not $AllowMissing) { $msg = "Folder not found: $($pick.Path)  (remove it with 'pjr')"; continue }
            return [pscustomobject]@{ Path = $pick.Path; Action = $action }
        }
    }
    finally {
        [Console]::Write("$e[?1049l")
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

# Shows the picker over saved + scanned folders, handling Ctrl+R rescans. Returns the final result or $null.
function Select-Project {
    $force = $false
    while ($true) {
        $items = Get-ProjectItemList -Saved (Get-ProjectFolderList) -Scanned (Get-ProjectIndex -Force:$force)
        $r = Show-ProjectPicker -Items $items
        if (-not $r -or $r.Action -ne 'refresh') { return $r }
        $force = $true
    }
}

function Invoke-ProjectJump {
    <#
    .SYNOPSIS
        Opens the ProjectJump picker.
    .DESCRIPTION
        Type to filter your saved and scanned project folders; the ones you use most are listed first.
        Enter changes to the selected folder, Shift+Enter opens it in a new Windows Terminal tab,
        Ctrl+S in a split pane, Ctrl+O in your editor, Ctrl+E in File Explorer. Ctrl+R rescans
        project roots and Esc cancels. This is what the Ctrl+K key binding runs.
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

function Set-ProjectJumpKeyHandler {
    <#
    .SYNOPSIS
        Binds the ProjectJump picker to a PSReadLine key chord.
    .DESCRIPTION
        The module binds Ctrl+K on import. Call this to use a different chord. Set the environment
        variable PROJECTJUMP_NO_KEYBINDING=1 before importing the module to skip the default binding.
    .EXAMPLE
        Set-ProjectJumpKeyHandler -Chord 'Ctrl+g'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Chord = 'Ctrl+k')
    if (-not $PSCmdlet.ShouldProcess($Chord, 'Bind ProjectJump picker')) { return }
    Set-PSReadLineKeyHandler -Chord $Chord -BriefDescription 'ProjectJump' `
        -Description 'Pick a project folder (Enter: cd, Shift+Enter: new tab)' -ScriptBlock {
        $r = Select-Project
        if (-not $r) { return }
        if (Invoke-ProjectAction $r) { return }
        Set-Location -LiteralPath $r.Path
        Add-ProjectUsage $r.Path
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
    }
}

#endregion

if (-not $env:PROJECTJUMP_NO_KEYBINDING -and (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue)) {
    try { Set-ProjectJumpKeyHandler } catch { Write-Verbose "ProjectJump: key binding skipped: $_" }
}

Set-Alias pja Add-ProjectFolder
Set-Alias pjr Remove-ProjectFolder
Set-Alias pj  Invoke-ProjectJump

Export-ModuleMember -Function Add-ProjectFolder, Remove-ProjectFolder, Get-ProjectFolder, Invoke-ProjectJump, Set-ProjectJumpKeyHandler,
    Add-ProjectRoot, Remove-ProjectRoot, Get-ProjectRoot, Update-ProjectIndex -Alias pja, pjr, pj
