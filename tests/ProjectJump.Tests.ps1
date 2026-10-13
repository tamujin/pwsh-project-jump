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
        foreach ($c in 'Add-ProjectFolder', 'Remove-ProjectFolder', 'Get-ProjectFolder', 'Invoke-ProjectJump', 'Set-ProjectJumpKeyHandler', 'pja', 'pjr', 'pj') {
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
            'C:\repos\api-gateway', 'C:\repos\web-app', 'C:\old\WebTools', 'C:\repos\playground\terminal-project' |
                ForEach-Object { [pscustomobject]@{ Path = $_; Name = (Split-Path $_ -Leaf); Exists = $true } }
        }
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

Describe 'Format-PickerRow' {
    It 'never exceeds the given width (ignoring ANSI codes)' {
        $row = InModuleScope ProjectJump {
            $item = [pscustomobject]@{ Path = 'C:\a\very\long\path\that\needs\trimming\project'; Name = 'project'; Exists = $true }
            Format-PickerRow $item $true 30
        }
        ($row -replace "$([char]27)\[[0-9;?]*[A-Za-z]", '').Length | Should -BeLessOrEqual 30
    }
}
