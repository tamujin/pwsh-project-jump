# ProjectJump - Ctrl+K type-ahead picker for saved project folders.
#   Enter        -> cd into the folder in the current tab
#   Shift+Enter  -> open the folder in a new Windows Terminal tab
#   Esc          -> cancel
# Manage the list with: pja (Add-ProjectFolder), pjr (Remove-ProjectFolder), Get-ProjectFolder

$script:StoreDir = if ($env:PROJECTJUMP_HOME) { $env:PROJECTJUMP_HOME } else {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.projectjump'
}
$script:StoreFile = Join-Path $script:StoreDir 'folders.txt'

function Get-ProjectFolderList {
    if (-not (Test-Path -LiteralPath $script:StoreFile)) { return @() }
    @(Get-Content -LiteralPath $script:StoreFile -Encoding utf8 | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
}

function Save-ProjectFolderList([string[]]$Folders) {
    if (-not (Test-Path -LiteralPath $script:StoreDir)) { New-Item -ItemType Directory -Path $script:StoreDir | Out-Null }
    Set-Content -LiteralPath $script:StoreFile -Value @($Folders) -Encoding utf8
}

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
        Removes the given path from the list. Without -Path, opens the picker to choose the entry to remove.
        Only the list entry is removed; the folder on disk is never touched.
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
        $r = Show-ProjectPicker -Folders $list -Title 'Remove project' -AllowMissing
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
        Lists the saved ProjectJump folders.
    .DESCRIPTION
        Returns one object per saved folder with Name, Exists and Path.
    .EXAMPLE
        Get-ProjectFolder | Where-Object { -not $_.Exists } | ForEach-Object { Remove-ProjectFolder $_.Path }
        Removes entries whose folders no longer exist.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    Get-ProjectFolderList | ForEach-Object {
        [pscustomobject]@{ Name = Split-Path $_ -Leaf; Exists = (Test-Path -LiteralPath $_ -PathType Container); Path = $_ }
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

# Returns the items matching $Query, best match first. An empty query keeps the saved order.
function Find-ProjectMatch($Items, [string]$Query) {
    $terms = @($Query.ToLowerInvariant().Split([char[]]' ', [StringSplitOptions]::RemoveEmptyEntries))
    if ($terms.Count -eq 0) { return @($Items) }
    @($Items | ForEach-Object { $s = Get-MatchScore $_ $terms; if ($null -ne $s) { [pscustomobject]@{ S = $s; I = $_ } } } |
        Sort-Object S, { $_.I.Name } | ForEach-Object { $_.I })
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

function Show-ProjectPicker {
    param([string[]]$Folders, [string]$Title = 'Projects', [switch]$AllowMissing)
    $e = [char]27
    $items = @($Folders | ForEach-Object {
        [pscustomobject]@{ Path = $_; Name = (Split-Path $_ -Leaf); Exists = (Test-Path -LiteralPath $_ -PathType Container) }
    })
    $query = ''; $sel = 0; $offset = 0; $msg = ''

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

            $sb = [Text.StringBuilder]::new()
            [void]$sb.Append("$e[H$e[2m$Title  $($hits.Count)/$($items.Count)   Enter: open | Shift+Enter: new tab | Esc: cancel$e[22m$e[K`r`n")
            [void]$sb.Append("$e[36m>$e[39m $query$e[K`r`n")
            if ($items.Count -eq 0) {
                [void]$sb.Append("$e[33m  No saved folders yet. cd into a project and run 'pja' (Add-ProjectFolder).$e[39m$e[K`r`n")
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
            $msg = ''
            if ($ctrl -and $k.Key -in 'K', 'P') { $sel--; continue }
            if ($ctrl -and $k.Key -in 'J', 'N') { $sel++; continue }
            if ($ctrl -and $k.Key -eq 'U') { $query = ''; $sel = 0; continue }
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
                'Enter' {
                    if ($hits.Count -eq 0) { continue }
                    $pick = $hits[$sel]
                    if (-not $pick.Exists -and -not $AllowMissing) { $msg = "Folder not found: $($pick.Path)  (remove it with 'pjr')"; continue }
                    return [pscustomobject]@{ Path = $pick.Path; NewTab = [bool]($k.Modifiers -band [ConsoleModifiers]::Shift) }
                }
                default {
                    if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar)) { $query += $k.KeyChar; $sel = 0 }
                }
            }
        }
    }
    finally {
        [Console]::Write("$e[?1049l")
    }
}

function Open-ProjectTab([string]$Path) {
    if ($env:WT_SESSION -and (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        # ';' separates commands in wt arguments, so escape it
        & wt.exe -w 0 new-tab -d ($Path -replace ';', '\;')
    }
    else {
        Start-Process (Get-Process -Id $PID).Path -WorkingDirectory $Path
    }
}

function Invoke-ProjectJump {
    <#
    .SYNOPSIS
        Opens the ProjectJump picker.
    .DESCRIPTION
        Type to filter the saved folders. Enter changes to the selected folder; Shift+Enter opens it
        in a new Windows Terminal tab (or a new console window outside Windows Terminal); Esc cancels.
        This is what the Ctrl+K key binding runs.
    .EXAMPLE
        pj
    #>
    [CmdletBinding()]
    param()
    $r = Show-ProjectPicker -Folders (Get-ProjectFolderList)
    if (-not $r) { return }
    if ($r.NewTab) { Open-ProjectTab $r.Path } else { Set-Location -LiteralPath $r.Path }
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
        -Description 'Pick a saved project folder (Enter: cd, Shift+Enter: new tab)' -ScriptBlock {
        $r = Show-ProjectPicker -Folders (Get-ProjectFolderList)
        if (-not $r) { return }
        if ($r.NewTab) { Open-ProjectTab $r.Path; return }
        Set-Location -LiteralPath $r.Path
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
    }
}

if (-not $env:PROJECTJUMP_NO_KEYBINDING -and (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue)) {
    try { Set-ProjectJumpKeyHandler } catch { Write-Verbose "ProjectJump: key binding skipped: $_" }
}

Set-Alias pja Add-ProjectFolder
Set-Alias pjr Remove-ProjectFolder
Set-Alias pj  Invoke-ProjectJump

Export-ModuleMember -Function Add-ProjectFolder, Remove-ProjectFolder, Get-ProjectFolder, Invoke-ProjectJump, Set-ProjectJumpKeyHandler -Alias pja, pjr, pj
