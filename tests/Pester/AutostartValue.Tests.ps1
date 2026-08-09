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
}
