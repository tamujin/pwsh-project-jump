#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'install.ps1' {
    BeforeAll {
        $script:Installer = Join-Path $PSScriptRoot '../install.ps1'
        $script:Bytes = [IO.File]::ReadAllBytes($script:Installer)
    }

    It 'has no byte order mark, which would break irm | iex' {
        # Invoke-RestMethod keeps a BOM as U+FEFF, and then the param block no longer parses.
        $script:Bytes[0..2] -join ',' | Should -Not -Be '239,187,191'
    }

    It 'is ASCII, so Windows PowerShell 5.1 reads it correctly without a BOM' {
        @($script:Bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'parses as a script block the way the one-line install runs it' {
        $text = [Text.Encoding]::UTF8.GetString($script:Bytes)
        { [scriptblock]::Create($text) } | Should -Not -Throw
    }
}

Describe 'tools/New-ReleasePackage.ps1' {
    BeforeAll {
        $script:Out = Join-Path ([IO.Path]::GetTempPath()) "projectjump-package-tests-$([guid]::NewGuid())"
        $script:Zip = & (Join-Path $PSScriptRoot '../tools/New-ReleasePackage.ps1') -OutputPath $script:Out 6> $null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
    }
    AfterAll {
        Remove-Item -LiteralPath $script:Out -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'puts the module files and LICENSE at the root of the zip' {
        $archive = [IO.Compression.ZipFile]::OpenRead($script:Zip.FullName)
        try { $names = @($archive.Entries | ForEach-Object FullName) }
        finally { $archive.Dispose() }
        $names | Should -Contain 'ProjectJump.psd1'
        $names | Should -Contain 'ProjectJump.psm1'
        $names | Should -Contain 'LICENSE'
    }

    It 'writes a matching SHA-256 checksum file' {
        $expected = (Get-FileHash -LiteralPath $script:Zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        Get-Content -LiteralPath "$($script:Zip.FullName).sha256" | Should -Be "$expected  ProjectJump.zip"
    }
}
