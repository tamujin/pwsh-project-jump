#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $env:PROJECTJUMP_NO_KEYBINDING = '1'
    $env:PROJECTJUMP_HOME = Join-Path ([IO.Path]::GetTempPath()) "projectjump-tests-$([guid]::NewGuid())"
    $manifest = Join-Path $PSScriptRoot '../src/ProjectJump/ProjectJump.psd1'
    Import-Module $manifest -Force
    $script:StoreFile = Join-Path $env:PROJECTJUMP_HOME 'folders.txt'
}

AfterAll {
    Remove-Module ProjectJump -Force -ErrorAction SilentlyContinue
    if ($env:PROJECTJUMP_HOME -and (Test-Path $env:PROJECTJUMP_HOME)) { Remove-Item $env:PROJECTJUMP_HOME -Recurse -Force }
    Remove-Item Env:PROJECTJUMP_HOME, Env:PROJECTJUMP_NO_KEYBINDING -ErrorAction SilentlyContinue
}

Describe 'Module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest (Join-Path $PSScriptRoot '../src/ProjectJump/ProjectJump.psd1') -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports the public commands and aliases' {
        $cmds = (Get-Module ProjectJump).ExportedCommands.Keys
        foreach ($c in 'Add-ProjectFolder', 'Remove-ProjectFolder', 'Get-ProjectFolder', 'Invoke-ProjectJump', 'Set-ProjectJumpKeyHandler',
            'Add-ProjectRoot', 'Remove-ProjectRoot', 'Get-ProjectRoot', 'Update-ProjectIndex', 'pja', 'pjr', 'pj') {
            $cmds | Should -Contain $c
        }
    }

    It 'does not export internal helpers' {
        (Get-Module ProjectJump).ExportedCommands.Keys | Should -Not -Contain 'Show-ProjectPicker'
    }
}

Describe 'Folder list' {
    BeforeEach {
        if (Test-Path $script:StoreFile) { Remove-Item $script:StoreFile -Force }
        $script:a = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'alpha') -Force).FullName
        $script:b = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'beta') -Force).FullName
        $script:c = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'gamma') -Force).FullName
    }

    It 'stores one path per line' {
        Add-ProjectFolder $a 6>$null
        Add-ProjectFolder $b 6>$null
        Add-ProjectFolder $c 6>$null
        @(Get-Content $script:StoreFile) | Should -Be @($a, $b, $c)
    }

    It 'ignores duplicates' {
        Add-ProjectFolder $a 6>$null
        Add-ProjectFolder $a 6>$null
        @(Get-ProjectFolder).Count | Should -Be 1
    }

    It 'accepts pipeline input from Get-ChildItem' {
        Get-ChildItem $TestDrive -Directory | Add-ProjectFolder 6>$null
        @(Get-ProjectFolder).Count | Should -Be 3
    }

    It 'rejects files' {
        $file = New-Item -ItemType File -Path (Join-Path $TestDrive 'file.txt') -Force
        { Add-ProjectFolder $file.FullName -ErrorAction Stop } | Should -Throw
    }

    It 'removes an entry by path' {
        $a, $b | Add-ProjectFolder 6>$null
        Remove-ProjectFolder $a 6>$null
        @(Get-ProjectFolder).Path | Should -Be @($b)
    }

    It 'honours -WhatIf on remove' {
        Add-ProjectFolder $a 6>$null
        Remove-ProjectFolder $a -WhatIf 6>$null
        @(Get-ProjectFolder).Count | Should -Be 1
    }

    It 'flags folders that no longer exist' {
        Add-ProjectFolder $a 6>$null
        Remove-Item $a -Recurse -Force
        (Get-ProjectFolder).Exists | Should -BeFalse
    }
}

Describe 'Matching' {
    BeforeAll {
        $script:items = InModuleScope ProjectJump {
            $order = 0
            'C:\repos\api-gateway', 'C:\repos\web-app', 'C:\old\WebTools', 'C:\repos\playground\terminal-project' |
                ForEach-Object { [pscustomobject]@{ Path = $_; Name = (Split-Path $_ -Leaf); Exists = $true; Frecency = 0; Order = $order++ } }
        }
    }

    It 'lists the most used folders first for an empty query' {
        $r = InModuleScope ProjectJump -Parameters @{ i = $items } {
            param($i)
            $copy = $i | ForEach-Object { $_.PSObject.Copy() }
            $copy[2].Frecency = 8; $copy[3].Frecency = 2
            Find-ProjectMatch $copy ''
        }
        $r.Name | Should -Be @('WebTools', 'terminal-project', 'api-gateway', 'web-app')
    }

    It 'breaks ties between equal matches by usage' {
        $r = InModuleScope ProjectJump -Parameters @{ i = $items } {
            param($i)
            $copy = $i | ForEach-Object { $_.PSObject.Copy() }
            $copy[2].Name = 'web-tools'; $copy[2].Frecency = 5
            Find-ProjectMatch $copy 'web'
        }
        $r[0].Name | Should -Be 'web-tools'
    }

    It 'returns everything in saved order for an empty query' {
        $r = InModuleScope ProjectJump -Parameters @{ i = $items } { param($i) Find-ProjectMatch $i '' }
        $r.Name | Should -Be @('api-gateway', 'web-app', 'WebTools', 'terminal-project')
    }

    It 'is case-insensitive' {
        $r = InModuleScope ProjectJump -Parameters @{ i = $items } { param($i) Find-ProjectMatch $i 'WEB' }
        $r.Name | Should -Be @('web-app', 'WebTools')
    }

    It 'ranks name matches above path-only matches' {
        $r = InModuleScope ProjectJump -Parameters @{ i = $items } { param($i) Find-ProjectMatch $i 'repos' }
        $r.Count | Should -Be 3
        $r = InModuleScope ProjectJump -Parameters @{ i = $items } { param($i) Find-ProjectMatch $i 'term' }
        $r[0].Name | Should -Be 'terminal-project'
    }

    It 'requires every space-separated term to match' {
        $r = InModuleScope ProjectJump -Parameters @{ i = $items } { param($i) Find-ProjectMatch $i 'api gw' }
        @($r).Name | Should -Be @('api-gateway')
    }

    It 'supports fuzzy subsequence matches' {
        $r = InModuleScope ProjectJump -Parameters @{ i = $items } { param($i) Find-ProjectMatch $i 'trmprj' }
        @($r).Name | Should -Be @('terminal-project')
    }

    It 'returns nothing when no item matches' {
        $r = InModuleScope ProjectJump -Parameters @{ i = $items } { param($i) Find-ProjectMatch $i 'zzz' }
        @($r).Count | Should -Be 0
    }
}

Describe 'Usage tracking' {
    BeforeEach {
        Get-ChildItem $env:PROJECTJUMP_HOME -File -ErrorAction SilentlyContinue | Remove-Item -Force
    }

    It 'counts every open and ranks by frecency' {
        $a = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'u-alpha') -Force).FullName
        $b = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'u-beta') -Force).FullName
        $a, $b | Add-ProjectFolder 6>$null
        InModuleScope ProjectJump -Parameters @{ b = $b } { param($b) Add-ProjectUsage $b; Add-ProjectUsage $b }
        $folders = Get-ProjectFolder
        ($folders | Where-Object Path -eq $b).Frecency | Should -Be 8   # 2 hits x weight 4 (last hour)
        ($folders | Where-Object Path -eq $a).Frecency | Should -Be 0
    }

    It 'weights old usage lower than recent usage' {
        InModuleScope ProjectJump {
            $old = [pscustomobject]@{ Path = 'x'; Hits = 10; Last = [DateTime]::UtcNow.AddDays(-30).Ticks }
            $new = [pscustomobject]@{ Path = 'y'; Hits = 2; Last = [DateTime]::UtcNow.Ticks }
            Get-Frecency $old | Should -Be 2.5
            Get-Frecency $new | Should -Be 8
        }
    }

    It 'survives a corrupt usage file' {
        Set-Content (Join-Path $env:PROJECTJUMP_HOME 'usage.json') '{ not json'
        { Get-ProjectFolder } | Should -Not -Throw
    }
}

Describe 'Project roots' {
    BeforeEach {
        Get-ChildItem $env:PROJECTJUMP_HOME -File -ErrorAction SilentlyContinue | Remove-Item -Force
        $script:root = Join-Path $TestDrive "root-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        foreach ($repo in 'one', 'group\two', 'group\deep\deeper\three', 'one\nested', 'node_modules\pkg', '.hidden\repo') {
            New-Item -ItemType Directory -Path (Join-Path $root "$repo\.git") -Force | Out-Null
        }
        New-Item -ItemType Directory -Path (Join-Path $root 'not-a-repo') -Force | Out-Null
    }

    It 'finds git repositories up to the given depth' {
        Add-ProjectRoot $root -Depth 2 6>$null
        $names = (Get-ProjectFolder -All | Where-Object Source -eq 'scanned').Name | Sort-Object
        $names | Should -Be @('one', 'two')
    }

    It 'goes deeper with a larger depth' {
        Add-ProjectRoot $root -Depth 4 6>$null
        (Get-ProjectFolder -All).Name | Should -Contain 'three'
    }

    It 'does not descend into repositories, hidden or dependency folders' {
        Add-ProjectRoot $root -Depth 5 6>$null
        $names = (Get-ProjectFolder -All).Name
        $names | Should -Not -Contain 'nested'
        $names | Should -Not -Contain 'pkg'
        $names | Should -Not -Contain 'repo'
    }

    It 'lists roots and removes them again' {
        Add-ProjectRoot $root 6>$null
        (Get-ProjectRoot).Path | Should -Be @((Resolve-Path $root).ProviderPath)
        Remove-ProjectRoot $root 6>$null
        @(Get-ProjectRoot).Count | Should -Be 0
        @(Get-ProjectFolder -All).Count | Should -Be 0
    }

    It 'uses the cached index until it is refreshed' {
        Add-ProjectRoot $root -Depth 2 6>$null
        New-Item -ItemType Directory -Path (Join-Path $root 'later\.git') -Force | Out-Null
        (Get-ProjectFolder -All).Name | Should -Not -Contain 'later'
        Update-ProjectIndex 6>$null
        (Get-ProjectFolder -All).Name | Should -Contain 'later'
    }

    It 'shows a folder that is both saved and scanned only once, as saved' {
        Add-ProjectRoot $root -Depth 2 6>$null
        Add-ProjectFolder (Join-Path $root 'one') 6>$null
        $one = @(Get-ProjectFolder -All | Where-Object Name -eq 'one')
        $one.Count | Should -Be 1
        $one[0].Source | Should -Be 'saved'
    }
}

Describe 'Format-PickerRow' {
    It 'never exceeds the given width (ignoring ANSI codes)' {
        $row = InModuleScope ProjectJump {
            $item = [pscustomobject]@{ Path = 'C:\a\very\long\path\that\needs\trimming\project'; Name = 'project'; Exists = $true }
            Format-PickerRow $item $true 30
        }
        ($row -replace "$([char]27)\[[0-9;?]*[A-Za-z]", '').Length | Should -BeLessOrEqual 30
    }
}
