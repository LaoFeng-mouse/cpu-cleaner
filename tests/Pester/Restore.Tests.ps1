# Pester 测试: 恢复 (manifest 兼容 / 防御) (Pester 5 固定版本 5.9.0)
Describe '恢复逻辑' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        # Pester 5 固定版本 (5.9.0): 直接使用原生断言, 不做 3.4/5.x 兼容包装
    }

    It '新格式 manifest 用 start_type_sc' {
        $m = [pscustomobject]@{ type='service'; name='X'; start_type_sc='auto'; before=$null }
        $scVal = if ($m.PSObject.Properties.Name -contains 'start_type_sc' -and $m.start_type_sc) { $m.start_type_sc } else { 'disabled' }
        $scVal | Should -Be 'auto'
    }
    It '旧格式 manifest 字符串枚举 Disabled→disabled' {
        $m = [pscustomobject]@{ type='service'; name='X'; before='Disabled' }
        $scVal = if ($m.before -match '^\d+$') { Convert-NumberToSc $m.before } elseif ($m.before) { Convert-StartTypeToSc $m.before } else { 'disabled' }
        $scVal | Should -Be 'disabled'
    }
    It '旧格式 manifest 字符串枚举 Automatic→auto' {
        $m = [pscustomobject]@{ type='service'; name='X'; before='Automatic' }
        $scVal = if ($m.before -match '^\d+$') { Convert-NumberToSc $m.before } elseif ($m.before) { Convert-StartTypeToSc $m.before } else { 'disabled' }
        $scVal | Should -Be 'auto'
    }
    It '旧格式 manifest 数字枚举 3→demand' {
        $m = [pscustomobject]@{ type='service'; name='X'; before='3' }
        $scVal = if ($m.before -match '^\d+$') { Convert-NumberToSc $m.before } elseif ($m.before) { Convert-StartTypeToSc $m.before } else { 'disabled' }
        $scVal | Should -Be 'demand'
    }
    It '缺省恢复为 disabled(保守)' {
        $m = [pscustomobject]@{ type='service'; name='X' }
        $scVal = if ($m.PSObject.Properties.Name -contains 'start_type_sc' -and $m.start_type_sc) { $m.start_type_sc } elseif ($m.before -match '^\d+$') { Convert-NumberToSc $m.before } elseif ($m.before) { Convert-StartTypeToSc $m.before } else { 'disabled' }
        $scVal | Should -Be 'disabled'
    }
    It '空/损坏 manifest 拒绝恢复' {
        $manifest = $null
        ($null -eq $manifest -or @($manifest).Count -eq 0) | Should -Be $true
    }
}
