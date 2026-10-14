#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $env:PROJECTJUMP_NO_KEYBINDING = '1'
    $env:PROJECTJUMP_HOME = Join-Path ([IO.Path]::GetTempPath()) "projectjump-tests-$([guid]::NewGuid())"
    $manifest = Join-Path $PSScriptRoot '../src/ProjectJump/ProjectJump.psd1'
    Import-Module $manifest -Force
    $script:StoreFile = Join-Path $env:PROJECTJUMP_HOME 'folders.txt'

    # A project with one of everything the task detector understands.
    function Initialize-TaskFixture([string]$Root) {
        foreach ($d in '.git', 'src\AppHost', 'src\Web', 'src\WebApp', 'tests\Web.Tests', 'scripts', 'other', 'node_modules\x') {
            New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null
        }
        Set-Content (Join-Path $Root 'Makefile') @(
            '.PHONY: build dev-backend', 'VERSION := 1.0', 'CC=gcc', '%.o: %.c',
            'build: ## Build everything', "`techo building", 'dev-backend: ## Run the API', 'kill-dotnet:')
        Set-Content (Join-Path $Root 'App.sln') 'Microsoft Visual Studio Solution File'
        Set-Content (Join-Path $Root 'src\AppHost\AppHost.csproj') '<Project Sdk="Aspire.AppHost.Sdk/9.0.0"><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>'
        Set-Content (Join-Path $Root 'src\Web\Web.csproj') '<Project Sdk="Microsoft.NET.Sdk.Web"></Project>'
        Set-Content (Join-Path $Root 'tests\Web.Tests\Web.Tests.csproj') '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup><ItemGroup><PackageReference Include="xunit" Version="2.9.0" /></ItemGroup></Project>'
        Set-Content (Join-Path $Root 'src\WebApp\package.json') '{ "scripts": { "dev": "vite", "build:prod": "vite build", "evil; calc": "echo x" } }'
        Set-Content (Join-Path $Root 'src\WebApp\package-lock.json') '{}'
        Set-Content (Join-Path $Root 'node_modules\x\package.json') '{ "scripts": { "ignored": "x" } }'
        foreach ($s in 'start-local-dev.ps1', 'scripts\deploy.ps1', '_hidden.ps1', 'other\skip.ps1', 'my script.ps1', 'x;y.ps1', "a'b.ps1") {
            Set-Content (Join-Path $Root $s) 'Write-Output hi'
        }
        Set-Content (Join-Path $Root 'docker-compose.yml') 'services: {}'
    }

    # Drives Show-ProjectPicker with simulated key presses, e.g. 'r','m','Right','Shift+Enter','Ctrl+S','Esc'.
    # Plain text is typed character by character. Returns the picker result and everything it drew.
    function Invoke-PickerScript {
        param([string[]]$Keys, $Items, [hashtable]$Options = @{})
        InModuleScope ProjectJump -Parameters @{ Keys = $Keys; Items = $Items; Options = $Options } {
            param($Keys, $Items, $Options)
            $named = @{ Enter = 'Enter'; Esc = 'Escape'; Right = 'RightArrow'; Left = 'LeftArrow'; Up = 'UpArrow'; Down = 'DownArrow'; Tab = 'Tab'; Backspace = 'Backspace' }
            $chars = @{ Enter = [char]13; Esc = [char]27; Tab = [char]9; Backspace = [char]8 }
            $script:TestKeys = [Collections.Generic.Queue[object]]::new()
            foreach ($spec in $Keys) {
                $parts = $spec -split '\+'
                $name = $parts[-1]
                if ($named.ContainsKey($name)) {
                    $c = if ($chars.ContainsKey($name)) { $chars[$name] } else { [char]0 }
                    $script:TestKeys.Enqueue([ConsoleKeyInfo]::new($c, [ConsoleKey]$named[$name], ($parts -contains 'Shift'), $false, ($parts -contains 'Ctrl')))
                }
                elseif ($parts.Count -gt 1) {
                    $script:TestKeys.Enqueue([ConsoleKeyInfo]::new([char]0, [ConsoleKey]($name.ToUpperInvariant()), ($parts -contains 'Shift'), $false, ($parts -contains 'Ctrl')))
                }
                else {
                    foreach ($ch in $spec.ToCharArray()) {
                        $key = if ($ch -eq ' ') { [ConsoleKey]::Spacebar } elseif ($ch -match '[a-z0-9]') { [ConsoleKey]($ch.ToString().ToUpperInvariant()) } else { [ConsoleKey]::OemMinus }
                        $script:TestKeys.Enqueue([ConsoleKeyInfo]::new($ch, $key, $false, $false, $false))
                    }
                }
            }
            $script:TestFrames = [Collections.Generic.List[string]]::new()
            # An exhausted script presses Esc, so a wrong expectation fails instead of hanging
            Mock Read-PickerKey { if ($script:TestKeys.Count) { $script:TestKeys.Dequeue() } else { [ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape, $false, $false, $false) } }
            Mock Write-PickerOutput { param($Text) $script:TestFrames.Add($Text) }
            $result = Show-ProjectPicker -Items $Items @Options
            [pscustomobject]@{ Result = $result; Frames = ($script:TestFrames -join '') }
        }
    }
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
            'Add-ProjectRoot', 'Remove-ProjectRoot', 'Get-ProjectRoot', 'Update-ProjectIndex',
            'Get-ProjectTask', 'Add-ProjectTask', 'Remove-ProjectTask', 'Invoke-ProjectTask', 'Set-ProjectTaskKeyHandler',
            'pja', 'pjr', 'pj', 'pjt') {
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

Describe 'Quoting' {
    It 'passes <_> through literally' -ForEach @(
        'plain', 'with space', 'semi;colon', 'dollar $(calc)', "it's", 'back`tick', 'a&b', '-dash', 'C:\Program Files\x', 'x|y', 'a,b', ''
    ) {
        $quoted = InModuleScope ProjectJump -Parameters @{ v = $_ } { param($v) ConvertTo-PSArgument $v }
        $out = & ([scriptblock]::Create("Write-Output $quoted"))
        $out | Should -BeExactly $_
    }

    It 'passes typographic single quotes through literally' {
        $v = "left$([char]0x2018)mid$([char]0x2019)right"
        $quoted = InModuleScope ProjectJump -Parameters @{ v = $v } { param($v) ConvertTo-PSArgument $v }
        (& ([scriptblock]::Create("Write-Output $quoted"))) | Should -BeExactly $v
    }

    It 'leaves safe names unquoted' {
        InModuleScope ProjectJump {
            ConvertTo-PSArgument 'build:prod' | Should -Be 'build:prod'
            ConvertTo-PSArgument '.\scripts\a-b.ps1' | Should -Be '.\scripts\a-b.ps1'
        }
    }
}

Describe 'Task detection' {
    BeforeAll {
        Get-ChildItem $env:PROJECTJUMP_HOME -File -ErrorAction SilentlyContinue | Remove-Item -Force
        $script:proj = Join-Path $TestDrive 'taskproj'
        Initialize-TaskFixture $script:proj
        $script:tasks = @(Get-ProjectTask $script:proj)
        function Find-Task([string]$Name) { $script:tasks | Where-Object Name -eq $Name }
    }

    It 'reads make targets with descriptions and skips non-targets' {
        (Find-Task 'make build').Command | Should -Be 'make build'
        (Find-Task 'make build').Description | Should -Be 'Build everything'
        (Find-Task 'make dev-backend').Description | Should -Be 'Run the API'
        Find-Task 'make kill-dotnet' | Should -Not -BeNullOrEmpty
        $script:tasks.Name | Should -Not -Contain 'make VERSION'
        $script:tasks.Name | Should -Not -Contain 'make CC'
        $script:tasks.Name | Should -Not -Contain 'make .PHONY'
        $script:tasks.Name | Should -Not -Contain 'make %.o'
    }

    It 'offers the Aspire commands next to the AppHost' {
        foreach ($c in 'run', 'start', 'stop', 'ps') {
            $t = Find-Task "aspire $c"
            $t.Command | Should -Be "aspire $c"
            $t.Cwd | Should -Be (Join-Path $script:proj 'src\AppHost')
        }
    }

    It 'offers dotnet build and test for the solution' {
        (Find-Task 'dotnet build App.sln').Command | Should -Be 'dotnet build App.sln'
        (Find-Task 'dotnet test App.sln -c Release').Command | Should -Be 'dotnet test App.sln -c Release'
        (Find-Task 'dotnet clean App.sln').Cwd | Should -Be $script:proj
    }

    It 'offers dotnet run for web and executable projects but not test projects' {
        (Find-Task 'dotnet run AppHost').Command | Should -Be 'dotnet run --project AppHost.csproj'
        (Find-Task 'dotnet run Web').Cwd | Should -Be (Join-Path $script:proj 'src\Web')
        Find-Task 'dotnet run Web.Tests' | Should -BeNullOrEmpty
    }

    It 'reads npm scripts from package.json files and ignores node_modules' {
        (Find-Task 'npm ci').Cwd | Should -Be (Join-Path $script:proj 'src\WebApp')
        (Find-Task 'npm run dev').Description | Should -Be 'vite'
        (Find-Task 'npm run build:prod').Command | Should -Be 'npm run build:prod'
        $script:tasks.Name | Should -Not -Contain 'npm run ignored'
    }

    It 'quotes script names that are not plain words' {
        (Find-Task 'npm run evil; calc').Command | Should -Be "npm run 'evil; calc'"
    }

    It 'lists PowerShell scripts from the root and scripts folder only' {
        (Find-Task 'start-local-dev.ps1').Command | Should -Be '.\start-local-dev.ps1'
        (Find-Task 'scripts\deploy.ps1').Command | Should -Be '.\scripts\deploy.ps1'
        $script:tasks.Name | Should -Not -Contain '_hidden.ps1'
        $script:tasks.Name | Should -Not -Contain 'other\skip.ps1'
    }

    It 'quotes script file names with spaces, semicolons and apostrophes' {
        (Find-Task 'my script.ps1').Command | Should -Be "& '.\my script.ps1'"
        (Find-Task 'x;y.ps1').Command | Should -Be "& '.\x;y.ps1'"
        (Find-Task "a'b.ps1").Command | Should -Be "& '.\a''b.ps1'"
    }

    It 'offers docker compose' {
        (Find-Task 'docker compose up -d').Command | Should -Be 'docker compose up -d'
    }

    It 'finds the project root from a subfolder' {
        InModuleScope ProjectJump -Parameters @{ p = $script:proj } {
            param($p)
            Resolve-ProjectBase (Join-Path $p 'src\Web') | Should -Be $p
            Resolve-ProjectBase $p | Should -Be $p
        }
    }

    It 'uses the folder itself when there is no git repository' {
        $plain = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'plain-folder') -Force).FullName
        InModuleScope ProjectJump -Parameters @{ p = $plain } { param($p) Resolve-ProjectBase $p | Should -Be $p }
    }

    It 'returns nothing for an empty project' {
        $empty = Join-Path $TestDrive 'empty-proj'
        New-Item -ItemType Directory -Path (Join-Path $empty '.git') -Force | Out-Null
        @(Get-ProjectTask $empty).Count | Should -Be 0
    }
}

Describe 'Custom tasks' {
    BeforeEach {
        Get-ChildItem $env:PROJECTJUMP_HOME -File -ErrorAction SilentlyContinue | Remove-Item -Force
        $script:cp = Join-Path $TestDrive "custom-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory -Path (Join-Path $cp '.git'), (Join-Path $cp 'sub') -Force | Out-Null
    }

    It 'lists your own tasks first, run from the project root' {
        Set-Content (Join-Path $cp 'build.ps1') 'x'
        Add-ProjectTask logs 'Get-Content app.log -Wait' -Path (Join-Path $cp 'sub') 6>$null
        $t = @(Get-ProjectTask $cp)
        $t[0].Name | Should -Be 'logs'
        $t[0].Source | Should -Be 'custom'
        $t[0].Command | Should -Be 'Get-Content app.log -Wait'
        $t[0].Cwd | Should -Be $cp
        $t.Name | Should -Contain 'build.ps1'
    }

    It 'keeps tasks per project' {
        $other = Join-Path $TestDrive 'other-proj'
        New-Item -ItemType Directory -Path (Join-Path $other '.git') -Force | Out-Null
        Add-ProjectTask only-here 'echo hi' -Path $cp 6>$null
        @(Get-ProjectTask $other).Count | Should -Be 0
    }

    It 'replaces a task with the same name' {
        Add-ProjectTask dev 'one' -Path $cp 6>$null
        Add-ProjectTask dev 'two' -Path $cp 6>$null
        $t = @(Get-ProjectTask $cp | Where-Object Name -eq 'dev')
        $t.Count | Should -Be 1
        $t[0].Command | Should -Be 'two'
    }

    It 'removes a task, and honours -WhatIf' {
        Add-ProjectTask dev 'one' -Path $cp 6>$null
        Remove-ProjectTask dev -Path $cp -WhatIf 6>$null
        @(Get-ProjectTask $cp).Count | Should -Be 1
        Remove-ProjectTask dev -Path $cp 6>$null
        @(Get-ProjectTask $cp).Count | Should -Be 0
    }

    It 'rejects tabs and line breaks' {
        { Add-ProjectTask 'a b' "one`ttwo" -Path $cp -ErrorAction Stop } | Should -Throw
    }

    It 'runs a task by name without the picker' {
        Add-ProjectTask hello 'Write-Output hello-from-task' -Path $cp 6>$null
        Push-Location $cp
        try { (Invoke-ProjectTask hello) | Should -Be 'hello-from-task' }
        finally { Pop-Location }
    }

    It 'moves to the task folder when the task runs elsewhere' {
        $line = InModuleScope ProjectJump -Parameters @{ p = $cp } {
            param($p)
            $task = [pscustomobject]@{ Cwd = $p; Command = 'make dev' }
            Push-Location (Join-Path $p 'sub')
            try { Format-TaskCommandLine $task } finally { Pop-Location }
        }
        $line | Should -Be "Set-Location -LiteralPath $(InModuleScope ProjectJump -Parameters @{ p = $cp } { param($p) ConvertTo-PSArgument $p }); make dev"
    }

    It 'types just the command when already in the task folder' {
        $line = InModuleScope ProjectJump -Parameters @{ p = $cp } {
            param($p)
            Push-Location $p
            try { Format-TaskCommandLine ([pscustomobject]@{ Cwd = $p; Command = 'make dev' }) } finally { Pop-Location }
        }
        $line | Should -Be 'make dev'
    }
}

Describe 'Task usage' {
    BeforeEach {
        Get-ChildItem $env:PROJECTJUMP_HOME -File -ErrorAction SilentlyContinue | Remove-Item -Force
        $script:up = Join-Path $TestDrive "usage-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        New-Item -ItemType Directory -Path (Join-Path $up '.git') -Force | Out-Null
        Set-Content (Join-Path $up 'Makefile') @('alpha:', 'beta:', 'gamma:')
    }

    It 'lists the most used task first' {
        InModuleScope ProjectJump -Parameters @{ p = $up } {
            param($p)
            $beta = @(Get-ProjectTaskItem $p | Where-Object Name -eq 'make beta')[0]
            Add-ProjectUsage (Get-TaskUsageKey $beta)
            Add-ProjectUsage (Get-TaskUsageKey $beta)
            (Find-ProjectMatch @(Get-ProjectTaskItem $p) '')[0].Name | Should -Be 'make beta'
        }
    }

    It 'matches on the command text as well as the name' {
        Add-ProjectTask logs 'tail-something' -Path $up 6>$null
        InModuleScope ProjectJump -Parameters @{ p = $up } {
            param($p)
            @(Find-ProjectMatch @(Get-ProjectTaskItem $p) 'tail').Name | Should -Be @('logs')
        }
    }

    It 'opens tasks in a console window with the command passed encoded' {
        $decoded = InModuleScope ProjectJump -Parameters @{ p = $up } {
            param($p)
            $saved = $env:WT_SESSION; $env:WT_SESSION = $null
            try {
                Mock Start-Process { }
                Open-TaskPane ([pscustomobject]@{ Name = 'x'; Cwd = $p; Command = "echo 'a;b' `$(calc)" })
                Should -Invoke Start-Process -Times 1 -ParameterFilter { $ArgumentList -contains '-EncodedCommand' }
                $encoded = $null
                Mock Start-Process { $script:lastArgs = $ArgumentList } -Verifiable
                Open-TaskPane ([pscustomobject]@{ Name = 'x'; Cwd = $p; Command = "echo 'a;b' `$(calc)" })
                $encoded = $script:lastArgs[-1]
                [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
            }
            finally { $env:WT_SESSION = $saved }
        }
        $decoded | Should -Be "echo 'a;b' `$(calc)"
    }
}

Describe 'Visited folders' {
    BeforeEach {
        Get-ChildItem $env:PROJECTJUMP_HOME -File -ErrorAction SilentlyContinue | Remove-Item -Force
        $script:v = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'visited-dir') -Force).FullName
    }

    It 'adds folders you keep opening to the full list' {
        InModuleScope ProjectJump -Parameters @{ p = $v } { param($p) 1..3 | ForEach-Object { Add-ProjectUsage $p } }
        $f = @(Get-ProjectFolder -All | Where-Object Path -eq $v)
        $f.Count | Should -Be 1
        $f[0].Source | Should -Be 'visited'
    }

    It 'ignores folders opened only once or twice' {
        InModuleScope ProjectJump -Parameters @{ p = $v } { param($p) 1..2 | ForEach-Object { Add-ProjectUsage $p } }
        @(Get-ProjectFolder -All | Where-Object Path -eq $v).Count | Should -Be 0
    }

    It 'keeps them out of the saved-only list' {
        InModuleScope ProjectJump -Parameters @{ p = $v } { param($p) 1..3 | ForEach-Object { Add-ProjectUsage $p } }
        @(Get-ProjectFolder).Count | Should -Be 0
    }

    It 'skips visited folders that no longer exist and task usage keys' {
        InModuleScope ProjectJump -Parameters @{ p = $v } {
            param($p)
            1..3 | ForEach-Object { Add-ProjectUsage $p; Add-ProjectUsage 'task:C:\x|make dev' }
        }
        Remove-Item $v -Recurse -Force
        @(Get-ProjectFolder -All).Count | Should -Be 0
    }

    It 'lists a saved folder once even when it is also visited' {
        Add-ProjectFolder $v 6>$null
        InModuleScope ProjectJump -Parameters @{ p = $v } { param($p) 1..3 | ForEach-Object { Add-ProjectUsage $p } }
        $f = @(Get-ProjectFolder -All | Where-Object Path -eq $v)
        $f.Count | Should -Be 1
        $f[0].Source | Should -Be 'saved'
    }
}

Describe 'Picker browsing' {
    BeforeAll {
        $script:root = Join-Path $TestDrive 'browse-root'
        foreach ($d in 'proj\docs', 'proj\src\app', 'proj\src\lib', 'proj\node_modules\x', 'proj\.git', 'other') {
            New-Item -ItemType Directory -Path (Join-Path $script:root $d) -Force | Out-Null
        }
        $script:proj = Join-Path $script:root 'proj'
        $script:other = Join-Path $script:root 'other'
        $script:items = @(InModuleScope ProjectJump -Parameters @{ a = $script:proj; b = $script:other } { param($a, $b) Get-ProjectItemList -Saved @($a, $b) })
        Get-ChildItem $env:PROJECTJUMP_HOME -File -ErrorAction SilentlyContinue | Remove-Item -Force
    }

    It 'goes into the highlighted folder with Right and picks a subfolder' {
        $r = Invoke-PickerScript -Keys 'Right', 'Down', 'Enter' -Items $items
        $r.Result.Path | Should -Be (Join-Path $proj 'docs')
        $r.Result.Action | Should -Be 'cd'
    }

    It 'lists the folder itself first, so you can still pick it' {
        (Invoke-PickerScript -Keys 'Right', 'Enter' -Items $items).Result.Path | Should -Be $proj
    }

    It 'hides hidden and dependency folders' {
        $r = Invoke-PickerScript -Keys 'Right', 'Esc' -Items $items
        $r.Frames | Should -Match 'docs'
        $r.Frames | Should -Not -Match 'node_modules'
        $r.Frames | Should -Not -Match '\.git'
    }

    It 'goes deeper and back up, keeping the folder you came from highlighted' {
        # Right (into proj), Down Down (src), Right (into src), Down (app), Left (back in proj, src highlighted), Enter
        $r = Invoke-PickerScript -Keys 'Right', 'Down', 'Down', 'Right', 'Down', 'Left', 'Enter' -Items $items
        $r.Result.Path | Should -Be (Join-Path $proj 'src')
    }

    It 'returns to the project list when going left from the top folder' {
        $r = Invoke-PickerScript -Keys 'Right', 'Left', 'Down', 'Enter' -Items $items
        # the list is back: Down moves from the first project to the second
        $r.Result.Path | Should -Be $other
    }

    It 'restores the filter you had typed when leaving the browser' {
        $r = Invoke-PickerScript -Keys 'o', 'Right', 'Left', 'Esc' -Items $items
        $last = ($r.Frames -split "$([char]27)\[H")[-1]
        $last | Should -Match 'Projects'
        $last | Should -Match '\[39m o'
        $last | Should -Match 'other'
    }

    It 'filters direct subfolders only' {
        $r = Invoke-PickerScript -Keys 'Right', 'd', 'o', 'Enter' -Items $items
        $r.Result.Path | Should -Be (Join-Path $proj 'docs')
    }

    It 'offers the other actions on a browsed folder' {
        $r = Invoke-PickerScript -Keys 'Right', 'Down', 'Shift+Enter' -Items $items
        $r.Result.Action | Should -Be 'tab'
        $r.Result.Path | Should -Be (Join-Path $proj 'docs')
        (Invoke-PickerScript -Keys 'Right', 'Down', 'Ctrl+S' -Items $items).Result.Action | Should -Be 'split'
        (Invoke-PickerScript -Keys 'Right', 'Down', 'Ctrl+O' -Items $items).Result.Action | Should -Be 'editor'
    }

    It 'ignores Left in the project list and cancels with Esc' {
        $r = Invoke-PickerScript -Keys 'Left', 'Esc' -Items $items
        $r.Result | Should -BeNullOrEmpty
    }

    It 'does not rescan from inside a browsed folder' {
        (Invoke-PickerScript -Keys 'Right', 'Ctrl+R', 'Esc' -Items $items).Result | Should -BeNullOrEmpty
        (Invoke-PickerScript -Keys 'Ctrl+R' -Items $items).Result.Action | Should -Be 'refresh'
    }

    It 'refuses to browse into a folder that no longer exists' {
        $gone = Join-Path $TestDrive 'gone-dir'
        $missing = @(InModuleScope ProjectJump -Parameters @{ g = $gone } { param($g) Get-ProjectItemList -Saved @($g) })
        $r = Invoke-PickerScript -Keys 'Right', 'Esc' -Items $missing
        $r.Frames | Should -Match 'Folder not found'
    }

    It 'ranks the folder you use most first while browsing' {
        InModuleScope ProjectJump -Parameters @{ p = (Join-Path $proj 'src') } { param($p) Add-ProjectUsage $p; Add-ProjectUsage $p }
        $r = Invoke-PickerScript -Keys 'Right', 'Down', 'Enter' -Items $items
        $r.Result.Path | Should -Be (Join-Path $proj 'src')
    }
}

Describe 'Task picker' {
    BeforeAll {
        Get-ChildItem $env:PROJECTJUMP_HOME -File -ErrorAction SilentlyContinue | Remove-Item -Force
        $script:tproj = Join-Path $TestDrive 'picker-taskproj'
        Initialize-TaskFixture $script:tproj
        $script:titems = @(InModuleScope ProjectJump -Parameters @{ p = $script:tproj } { param($p) Get-ProjectTaskItem $p })
    }

    It 'filters tasks as you type and runs the highlighted one with Enter' {
        $r = Invoke-PickerScript -Keys 'd', 'e', 'v', '-', 'b', 'Enter' -Items $titems -Options @{ Tasks = $true }
        $r.Result.Action | Should -Be 'run'
        $r.Result.Item.Command | Should -Be 'make dev-backend'
    }

    It 'opens the task in a new tab with Shift+Enter and a split pane with Ctrl+S' {
        (Invoke-PickerScript -Keys 'a', 's', 'p', 'e', 'Shift+Enter' -Items $titems -Options @{ Tasks = $true }).Result.Action | Should -Be 'tab'
        (Invoke-PickerScript -Keys 'Ctrl+S' -Items $titems -Options @{ Tasks = $true }).Result.Action | Should -Be 'split'
    }

    It 'has no folder-only keys' {
        # Ctrl+O/Ctrl+E/Right/Ctrl+R do nothing here, so the script runs out and presses Esc
        $r = Invoke-PickerScript -Keys 'Ctrl+O', 'Ctrl+E', 'Right', 'Ctrl+R' -Items $titems -Options @{ Tasks = $true }
        $r.Result | Should -BeNullOrEmpty
    }

    It 'shows the project name and the hint for an empty project' {
        $r = Invoke-PickerScript -Keys 'Esc' -Items @() -Options @{ Tasks = $true; Title = 'Tasks in demo'; EmptyMessage = 'No tasks found here.' }
        $r.Frames | Should -Match 'Tasks in demo'
        $r.Frames | Should -Match 'No tasks found here'
    }
}

Describe 'Console encoding' {
    It 'switches to UTF-8 and restores the previous encoding' {
        InModuleScope ProjectJump {
            $original = [Console]::OutputEncoding
            try {
                try { [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437) } catch { Set-ItResult -Skipped -Because 'console encoding cannot be changed in this host'; return }
                $previous = Enter-Utf8Output
                [Console]::OutputEncoding.CodePage | Should -Be 65001
                Exit-Utf8Output $previous
                [Console]::OutputEncoding.CodePage | Should -Be 437
            }
            finally { [Console]::OutputEncoding = $original }
        }
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
