# Pester 测试: 自启值单值备份/恢复 (v1.5.4 P0 — 恢复粒度必须等于修改粒度)
# 旧实现 reg export 整个 Run 键 + reg import, 会覆盖期间用户新增/修改的同键其他值;
# 新实现只备份单个 Value 的 Name/Type/Data, restore 只写回这一项。
# 测试用 HKCU 临时键 (不需要管理员), 每个用例自建自删。
Describe '自启值单值备份/恢复 (v1.5.4 P0)' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs

        if (-not (Get-Command Write-AutostartValueBackup -ErrorAction SilentlyContinue)) {
            function Write-AutostartValueBackup { throw 'transaction backup writer not implemented' }
        }

        $script:TestKey = 'HKCU:\Software\ShushuCleanerTest'
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\ShushuCleanerTest')
        $k.SetValue('StrVal', 'C:\fake\x.exe', [Microsoft.Win32.RegistryValueKind]::String)
        $k.SetValue('ExpVal', '%SystemRoot%\x.exe', [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $k.SetValue('DwordVal', 123, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('QwordVal', [int64]1234567890123, [Microsoft.Win32.RegistryValueKind]::QWord)
        $k.SetValue('BinVal', [byte[]](1, 2, 254, 255), [Microsoft.Win32.RegistryValueKind]::Binary)
        $k.SetValue('MultiVal', [string[]]@('first', 'second'), [Microsoft.Win32.RegistryValueKind]::MultiString)
        $k.Close()
    }
    AfterEach {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\ShushuCleanerTest', $false)
    }

    It 'String 值备份信息完整 (name/type/value)' {
        $info = Get-AutostartValueInfo $script:TestKey 'StrVal'
        $info | Should -Not -Be $null
        $info.name | Should -Be 'StrVal'
        $info.value_type | Should -Be 'String'
        $info.value | Should -Be 'C:\fake\x.exe'
        $info.key | Should -Be $script:TestKey
    }
    It 'ExpandString 值备份保留 %VAR% 不展开' {
        $info = Get-AutostartValueInfo $script:TestKey 'ExpVal'
        $info.value_type | Should -Be 'ExpandString'
        $info.value | Should -Be '%SystemRoot%\x.exe'
    }
    It 'DWord 值类型与数据正确' {
        $info = Get-AutostartValueInfo $script:TestKey 'DwordVal'
        $info.value_type | Should -Be 'DWord'
        $info.value | Should -Be 123
    }
    It 'QWord 值 JSON 往返后类型/数据保持' {
        $info = Get-AutostartValueInfo $script:TestKey 'QwordVal'
        $info.value_type | Should -Be 'QWord'
        $info.value | Should -Be ([int64]1234567890123)
        $round = $info | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $round.value_type | Should -Be 'QWord'
        Remove-ItemProperty -Path $script:TestKey -Name 'QwordVal'
        Restore-AutostartValue $round
        (Get-ItemProperty $script:TestKey).QwordVal | Should -Be ([int64]1234567890123)
    }
    It 'Binary 值 JSON 往返后恢复为 byte[] 且数据一致' {
        $info = Get-AutostartValueInfo $script:TestKey 'BinVal'
        $info.value_type | Should -Be 'Binary'
        $round = $info | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $round.value_type | Should -Be 'Binary'
        Remove-ItemProperty -Path $script:TestKey -Name 'BinVal'
        Restore-AutostartValue $round
        $after = (Get-ItemProperty $script:TestKey).BinVal
        # 注意不能用管道断言类型: byte[] 会被管道展开成单个 byte
        $after.GetType().FullName | Should -Be 'System.Byte[]'
        [BitConverter]::ToString([byte[]]$after) | Should -Be '01-02-FE-FF'
    }
    It 'MultiString 值 JSON 往返后恢复且内容一致' {
        $info = Get-AutostartValueInfo $script:TestKey 'MultiVal'
        $info.value_type | Should -Be 'MultiString'
        $round = $info | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        Remove-ItemProperty -Path $script:TestKey -Name 'MultiVal'
        Restore-AutostartValue $round
        $after = (Get-ItemProperty $script:TestKey).MultiVal
        @($after) -join ',' | Should -Be 'first,second'
    }
    It '删除后单值恢复: 值回来且类型/数据不变' {
        $info = Get-AutostartValueInfo $script:TestKey 'StrVal'
        Remove-ItemProperty -Path $script:TestKey -Name 'StrVal'
        $afterDel = Get-ItemProperty $script:TestKey -ErrorAction SilentlyContinue
        ($afterDel.PSObject.Properties | Where-Object { $_.Name -eq 'StrVal' }) | Should -Be $null
        Restore-AutostartValue $info
        $after = Get-ItemProperty $script:TestKey
        $after.StrVal | Should -Be 'C:\fake\x.exe'
    }
    It '恢复只写回目标值, 同键其他值不受影响 (最小恢复)' {
        $info = Get-AutostartValueInfo $script:TestKey 'StrVal'
        Remove-ItemProperty -Path $script:TestKey -Name 'StrVal'
        # 模拟用户后来新增了别的值 (如装了微信)
        New-ItemProperty -Path $script:TestKey -Name 'WeChatTest' -Value 'C:\wechat\WeChat.exe' -PropertyType String -Force | Out-Null
        Restore-AutostartValue $info
        $after = Get-ItemProperty $script:TestKey
        $after.StrVal | Should -Be 'C:\fake\x.exe'
        $after.WeChatTest | Should -Be 'C:\wechat\WeChat.exe'
    }
    It '不存在的值返回 null' {
        Get-AutostartValueInfo $script:TestKey 'NoSuchValue' | Should -Be $null
    }
    It '非法路径 (非 HKLM/HKCU) 返回 null' {
        Get-AutostartValueInfo 'C:\Windows\System32' 'x' | Should -Be $null
    }

    It 'RegistryKey 字面删除只删除指定的 * ? [x] 值' {
        $relativePath = 'Software\ShushuCleanerLiteralDeleteTest_' + [guid]::NewGuid().ToString('N')
        try {
            $created = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($relativePath)
            foreach ($name in @('*','?','[x]','keep')) {
                $created.SetValue($name, "value-$name", [Microsoft.Win32.RegistryValueKind]::String)
            }
            $created.Dispose()

            foreach ($target in @('*','?','[x]')) {
                $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativePath, $true)
                try { Remove-LiteralRegistryValueFromKey -RegistryKey $key -Name $target } finally { $key.Dispose() }
                $check = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relativePath, $false)
                try {
                    @($check.GetValueNames()) | Should -Not -Contain $target
                    @($check.GetValueNames()) | Should -Contain 'keep'
                    foreach ($other in @('*','?','[x]') | Where-Object { $_ -ne $target }) {
                        if ($other -in @($check.GetValueNames())) { $check.GetValue($other) | Should -Be "value-$other" }
                    }
                } finally { $check.Dispose() }
            }
        } finally {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($relativePath, $false)
        }
    }

    It '生产 remove_autostart 使用字面 helper 且源码不调用 Remove-ItemProperty' {
        $source = Get-Content (Join-Path $projectRoot 'src\Core\ActionEngine.ps1') -Raw -Encoding UTF8
        $start = $source.IndexOf("'remove_autostart' {")
        $end = $source.IndexOf("'disable_task' {", $start)
        $body = $source.Substring($start, $end - $start)

        $body | Should -Match 'Invoke-LiteralAutostartRemoval'
        $body | Should -Not -Match '\bRemove-ItemProperty\b'
    }

    It '删除事务在当前 Value 已变化时不备份也不删除' {
        $relativePath = 'Software\ShushuCleanerTxn_' + [guid]::NewGuid().ToString('N')
        $key = $null
        try {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($relativePath)
            $key.SetValue('Updater', 'C:\Apps\changed.exe', [Microsoft.Win32.RegistryValueKind]::String)
            Mock Write-AutostartValueBackup { throw 'must not backup changed value' }
            Mock Remove-LiteralRegistryValueFromKey { throw 'must not delete changed value' }

            $result = Invoke-LiteralAutostartRemovalFromKey -RegistryKey $key -Source ('HKCU:\' + $relativePath) -Name 'Updater' -ExpectedValue 'C:\Apps\old.exe' -BackupDir $TestDrive -Tag 'changed'

            $result.status | Should -Be 'skipped'
            Assert-MockCalled Write-AutostartValueBackup -Times 0 -Exactly
            Assert-MockCalled Remove-LiteralRegistryValueFromKey -Times 0 -Exactly
            $key.GetValue('Updater') | Should -Be 'C:\Apps\changed.exe'
        } finally {
            if ($null -ne $key) { $key.Dispose() }
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($relativePath, $false)
        }
    }

    It '删除事务在备份 null 抛错或文件不存在时删除调用均为 0' {
        $relativePath = 'Software\ShushuCleanerTxn_' + [guid]::NewGuid().ToString('N')
        $key = $null
        try {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($relativePath)
            $key.SetValue('Updater', 'C:\Apps\old.exe', [Microsoft.Win32.RegistryValueKind]::String)
            Mock Write-AutostartValueBackup {
                switch ($script:BackupFailureMode) {
                    'null' { return $null }
                    'throw' { throw 'backup failed' }
                    'missing' { return (Join-Path $TestDrive 'not-created.autostart.json') }
                }
            }
            Mock Remove-LiteralRegistryValueFromKey { throw 'must not delete without verified backup' }

            foreach ($mode in @('null','throw','missing')) {
                $script:BackupFailureMode = $mode
                $result = Invoke-LiteralAutostartRemovalFromKey -RegistryKey $key -Source ('HKCU:\' + $relativePath) -Name 'Updater' -ExpectedValue 'C:\Apps\old.exe' -BackupDir $TestDrive -Tag $mode
                $result.status | Should -Be 'failed' -Because $mode
                $key.GetValue('Updater') | Should -Be 'C:\Apps\old.exe' -Because $mode
            }
            Assert-MockCalled Remove-LiteralRegistryValueFromKey -Times 0 -Exactly
        } finally {
            if ($null -ne $key) { $key.Dispose() }
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($relativePath, $false)
        }
    }

    It '备份后同一 RegistryKey 上 Value 变化时不删除' {
        $relativePath = 'Software\ShushuCleanerTxn_' + [guid]::NewGuid().ToString('N')
        $key = $null
        try {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($relativePath)
            $key.SetValue('Updater', 'C:\Apps\old.exe', [Microsoft.Win32.RegistryValueKind]::String)
            $script:TransactionRegistryKey = $key
            Mock Write-AutostartValueBackup {
                $out = Join-Path $TestDrive 'changed-after-backup.autostart.json'
                [System.IO.File]::WriteAllText($out, '{"backup":true}')
                $script:TransactionRegistryKey.SetValue('Updater', 'C:\Apps\changed.exe', [Microsoft.Win32.RegistryValueKind]::String)
                return $out
            }
            Mock Remove-LiteralRegistryValueFromKey { throw 'must not delete changed value' }

            $result = Invoke-LiteralAutostartRemovalFromKey -RegistryKey $key -Source ('HKCU:\' + $relativePath) -Name 'Updater' -ExpectedValue 'C:\Apps\old.exe' -BackupDir $TestDrive -Tag 'changed-after'

            $result.status | Should -Be 'skipped'
            Assert-MockCalled Remove-LiteralRegistryValueFromKey -Times 0 -Exactly
            $key.GetValue('Updater') | Should -Be 'C:\Apps\changed.exe'
        } finally {
            if ($null -ne $key) { $key.Dispose() }
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($relativePath, $false)
        }
    }

    It '备份验证且 Value 未变化时同一 RegistryKey 字面删除恰好 1 次' {
        $relativePath = 'Software\ShushuCleanerTxn_' + [guid]::NewGuid().ToString('N')
        $key = $null
        try {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($relativePath)
            $key.SetValue('Updater', 'C:\Apps\old.exe', [Microsoft.Win32.RegistryValueKind]::String)
            Mock Write-AutostartValueBackup {
                $out = Join-Path $TestDrive 'valid-backup.autostart.json'
                [System.IO.File]::WriteAllText($out, '{"backup":true}')
                return $out
            }
            Mock Remove-LiteralRegistryValueFromKey { $RegistryKey.DeleteValue($Name, $false) }

            $result = Invoke-LiteralAutostartRemovalFromKey -RegistryKey $key -Source ('HKCU:\' + $relativePath) -Name 'Updater' -ExpectedValue 'C:\Apps\old.exe' -BackupDir $TestDrive -Tag 'success'

            $result.status | Should -Be 'success'
            Assert-MockCalled Remove-LiteralRegistryValueFromKey -Times 1 -Exactly
            @($key.GetValueNames()) | Should -Not -Contain 'Updater'
        } finally {
            if ($null -ne $key) { $key.Dispose() }
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($relativePath, $false)
        }
    }
}
