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
