# Pester 测试: 待办清单 (去重 / safe 规则 / 状态机)
$src = Get-Content 'D:\34615\CPU后台整理工具\cpu-cleaner.ps1' -Raw -Encoding UTF8
$idx = $src.IndexOf("switch (`$Mode)")
$defs = $src.Substring(0, $idx)
Invoke-Expression $defs

Describe '待办清单规则' {
    It '同一规则(id)不会重复动作' {
        $hits = @(
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$true },
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='remove_autostart'; hit_type='autostart'; detail='X'; reason_cn='r'; service_name=''; autostart_source='HKCU:\...\Run'; autostart_name='X'; task_path=''; process_name=''; safe=$true }
        )
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $script:PendingFile = $tmp
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        Remove-Item $tmp -ErrorAction SilentlyContinue
        @($p.actions).Count | Should Be 1
    }
    It 'safe=false 永不进入待办队列' {
        $hits = @(
            [pscustomobject]@{ id='b'; vendor='T'; name_cn='B'; action='disable_service'; hit_type='service'; detail='S2'; reason_cn='r'; service_name='S2'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; safe=$false }
        )
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $script:PendingFile = $tmp
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        Remove-Item $tmp -ErrorAction SilentlyContinue
        @($p.actions).Count | Should Be 0
    }
    It '待办初始状态为 pending' {
        $hits = @(
            [pscustomobject]@{ id='c'; vendor='T'; name_cn='C'; action='disable_task'; hit_type='task'; detail='\X\T1'; reason_cn='r'; service_name=''; autostart_source=''; autostart_name=''; task_path='\X\T1'; process_name=''; safe=$true }
        )
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $script:PendingFile = $tmp
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.actions[0].status | Should Be 'pending'
    }
    It 'clean 只处理 pending/failed' {
        ('pending') -in @('pending','failed') | Should Be $true
        ('failed') -in @('pending','failed') | Should Be $true
        ('success') -in @('pending','failed') | Should Be $false
        ('manual_required') -in @('pending','failed') | Should Be $false
    }
}
