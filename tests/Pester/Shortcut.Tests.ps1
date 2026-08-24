Describe 'branded desktop shortcut and icon' {
    BeforeAll {
        $script:ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        function Get-IcoDirectoryEntries([string]$Path) {
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            if ($bytes.Length -lt 6) { throw 'ICO header is truncated' }
            $count = [BitConverter]::ToUInt16($bytes, 4)
            $rows = @()
            for ($index = 0; $index -lt $count; $index++) {
                $entry = 6 + (16 * $index)
                if (($entry + 16) -gt $bytes.Length) { throw 'ICO directory is truncated' }
                $width = if ($bytes[$entry] -eq 0) { 256 } else { [int]$bytes[$entry] }
                $height = if ($bytes[$entry + 1] -eq 0) { 256 } else { [int]$bytes[$entry + 1] }
                $length = [BitConverter]::ToUInt32($bytes, $entry + 8)
                $offset = [BitConverter]::ToUInt32($bytes, $entry + 12)
                $png = $length -ge 8 -and ($offset + 8) -le $bytes.Length -and
                    $bytes[$offset] -eq 0x89 -and $bytes[$offset + 1] -eq 0x50 -and
                    $bytes[$offset + 2] -eq 0x4E -and $bytes[$offset + 3] -eq 0x47
                $rows += [pscustomobject]@{ Width=$width; Height=$height; IsPng=[bool]$png }
            }
            return @($rows)
        }
    }

    It 'packages all required Windows icon sizes including a PNG 256 frame' {
        $icon = Join-Path $script:ProjectRoot 'assets\shushu.ico'
        (Get-Item -LiteralPath $icon).Length | Should -BeGreaterThan 10KB
        $entries = @(Get-IcoDirectoryEntries $icon)
        @($entries.Width | Sort-Object -Unique) | Should -Be @(16,20,24,32,40,48,64,128,256)
        @($entries | Where-Object { $_.Width -eq 256 -and $_.Height -eq 256 -and $_.IsPng }).Count | Should -Be 1
    }

    It 'keeps a square high-resolution mouse-fantasy source master' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:ProjectRoot 'assets\shushu-cleaner-master.png'))
        [Text.Encoding]::ASCII.GetString($bytes, 1, 3) | Should -BeExactly 'PNG'
        $width = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 16))
        $height = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 20))
        $width | Should -BeGreaterOrEqual 1024
        $height | Should -Be $width
    }

    It 'creates an idempotent desktop shortcut with the verified GUI entrypoint' {
        $installer = Join-Path $script:ProjectRoot 'Install-DesktopShortcut.ps1'
        Test-Path -LiteralPath $installer | Should -BeTrue
        & $installer -DesktopPath $TestDrive
        & $installer -DesktopPath $TestDrive

        $path = Join-Path $TestDrive '鼠鼠 Cleaner.lnk'
        Test-Path -LiteralPath $path | Should -BeTrue
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($path)
        $shortcut.TargetPath | Should -Match 'WindowsPowerShell\\v1\.0\\powershell\.exe$'
        $shortcut.Arguments | Should -Match '^-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "[^"]+\\gui-cleaner\.ps1"$'
        $shortcut.WorkingDirectory | Should -BeExactly $script:ProjectRoot
        $shortcut.IconLocation | Should -BeExactly ((Join-Path $script:ProjectRoot 'assets\shushu.ico') + ',0')
        $shortcut.Description | Should -BeExactly '安全识别并清理 OEM 后台组件和高 CPU 可疑进程'
    }

    It 'preserves a conflicting existing shortcut before installing the cleaner shortcut' {
        $installer = Join-Path $script:ProjectRoot 'Install-DesktopShortcut.ps1'
        $path = Join-Path $TestDrive '鼠鼠 Cleaner.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $old = $shell.CreateShortcut($path)
        $old.TargetPath = "$env:WINDIR\System32\notepad.exe"
        $old.Description = '用户原有快捷方式'
        $old.Save()

        & $installer -DesktopPath $TestDrive

        $backups = @(Get-ChildItem -LiteralPath $TestDrive -Filter '鼠鼠 Cleaner.previous-*.lnk')
        $backups.Count | Should -Be 1
        $preserved = $shell.CreateShortcut($backups[0].FullName)
        $preserved.TargetPath | Should -Match 'notepad\.exe$'
        $installed = $shell.CreateShortcut($path)
        $installed.TargetPath | Should -Match 'WindowsPowerShell\\v1\.0\\powershell\.exe$'
    }
}
