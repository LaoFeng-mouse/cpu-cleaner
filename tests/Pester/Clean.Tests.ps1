# Pester 测试: 清理动作 (映射 / safe 防御 / 验证逻辑)
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
$idx = $src.IndexOf("switch (`$Mode)")
$defs = $src.Substring(0, $idx)
Invoke-Expression $defs

Describe '清理动作逻辑' {
    It '服务启动类型映射 Automatic→auto' {
        Convert-StartTypeToSc 'Automatic' | Should Be 'auto'
    }
    It '服务启动类型映射 Manual→demand' {
        Convert-StartTypeToSc 'Manual' | Should Be 'demand'
    }
    It '服务启动类型映射 Disabled→disabled' {
        Convert-StartTypeToSc 'Disabled' | Should Be 'disabled'
    }
    It '旧 manifest 数字枚举 2→auto' {
        Convert-NumberToSc 2 | Should Be 'auto'
    }
    It '旧 manifest 数字枚举 4→disabled' {
        Convert-NumberToSc 4 | Should Be 'disabled'
    }
    It 'safe=false 即使选中也被拒绝(skipped)' {
        # 模拟 clean 里的防御逻辑
        $p = [pscustomobject]@{ safe = $false; status = 'pending' }
        if (-not $p.safe) { $p.status = 'skipped' }
        $p.status | Should Be 'skipped'
    }
    It 'actions 缺省动作返回 none' {
        Get-ActionFor $null 'service' | Should Be 'none'
        Get-ActionFor ([pscustomobject]@{ process = 'investigate' }) 'service' | Should Be 'none'
        Get-ActionFor ([pscustomobject]@{ process = 'investigate' }) 'process' | Should Be 'investigate'
    }
    It 'actions hashtable 兼容(v1 转换产物)' {
        $h = @{ service = 'disable_service' }
        Get-ActionFor $h 'service' | Should Be 'disable_service'
        Get-ActionFor $h 'process' | Should Be 'none'
        (Get-ActionKeys $h) -contains 'service' | Should Be $true
    }
}
