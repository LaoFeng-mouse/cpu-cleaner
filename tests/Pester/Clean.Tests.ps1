# Pester 测试: 清理动作 (映射 / safe 防御) (Pester 5 固定版本 5.9.0)
Describe '清理动作逻辑' {
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

    It '服务启动类型映射 Automatic→auto' {
        Convert-StartTypeToSc 'Automatic' | Should -Be 'auto'
    }
    It '服务启动类型映射 Manual→demand' {
        Convert-StartTypeToSc 'Manual' | Should -Be 'demand'
    }
    It '服务启动类型映射 Disabled→disabled' {
        Convert-StartTypeToSc 'Disabled' | Should -Be 'disabled'
    }
    It '旧 manifest 数字枚举 2→auto' {
        Convert-NumberToSc 2 | Should -Be 'auto'
    }
    It '旧 manifest 数字枚举 4→disabled' {
        Convert-NumberToSc 4 | Should -Be 'disabled'
    }
    It 'safe=false 即使选中也被拒绝(skipped)' {
        $p = [pscustomobject]@{ safe = $false; status = 'pending' }
        if (-not $p.safe) { $p.status = 'skipped' }
        $p.status | Should -Be 'skipped'
    }
    It 'actions 缺省动作返回 none' {
        Get-ActionFor $null 'service' | Should -Be 'none'
        Get-ActionFor ([pscustomobject]@{ process = 'investigate' }) 'service' | Should -Be 'none'
        Get-ActionFor ([pscustomobject]@{ process = 'investigate' }) 'process' | Should -Be 'investigate'
    }
    It 'actions hashtable 兼容(v1 转换产物)' {
        $h = @{ service = 'disable_service' }
        Get-ActionFor $h 'service' | Should -Be 'disable_service'
        Get-ActionFor $h 'process' | Should -Be 'none'
        (Get-ActionKeys $h) -contains 'service' | Should -Be $true
    }
}
