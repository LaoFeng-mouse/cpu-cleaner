# Pester 测试: clean 提权后授权验证 (v1.5.3 P0 — 不信任 pending_actions.json)
# Test-PendingActionAuthorized 必须按当前特征库确认: id 存在 / tested=true / safe=true / action 匹配 / target 匹配
Describe '授权验证 (提权后重新确认)' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        # 当前真实特征库 (与 clean 提权后加载的一致)
        $script:Profiles = Load-Profiles
    }

    It '合法命中授权通过 (lenovo-serviceas 服务 → disable_service)' {
        $p = [pscustomobject]@{ id='lenovo-serviceas'; hit_type='service'; action='disable_service'; service_name='LenovoServiceAS'; autostart_name=''; task_path=''; process_name='' }
        Test-PendingActionAuthorized $p $script:Profiles | Should -Be $true
    }
    It '合法命中授权通过 (lenovo-serviceas 自启 → remove_autostart)' {
        $p = [pscustomobject]@{ id='lenovo-serviceas'; hit_type='autostart'; action='remove_autostart'; service_name=''; autostart_name='LenovoAppStore'; task_path=''; process_name='' }
        Test-PendingActionAuthorized $p $script:Profiles | Should -Be $true
    }
    It '伪造 id 被拒绝' {
        $p = [pscustomobject]@{ id='hacker-fake-rule'; hit_type='service'; action='disable_service'; service_name='WinDefend'; autostart_name=''; task_path=''; process_name='' }
        Test-PendingActionAuthorized $p $script:Profiles | Should -Be $false
    }
    It 'action 被篡改被拒绝 (disable_service → remove_autostart)' {
        $p = [pscustomobject]@{ id='lenovo-serviceas'; hit_type='service'; action='remove_autostart'; service_name='LenovoServiceAS'; autostart_name=''; task_path=''; process_name='' }
        Test-PendingActionAuthorized $p $script:Profiles | Should -Be $false
    }
    It 'target 被篡改被拒绝 (服务名不在规则 detect)' {
        $p = [pscustomobject]@{ id='lenovo-serviceas'; hit_type='service'; action='disable_service'; service_name='WinDefend'; autostart_name=''; task_path=''; process_name='' }
        Test-PendingActionAuthorized $p $script:Profiles | Should -Be $false
    }
    It 'hit_type 无对应动作被拒绝 (task 未定义 → none ≠ disable_task)' {
        $p = [pscustomobject]@{ id='lenovo-serviceas'; hit_type='task'; action='disable_task'; service_name=''; autostart_name=''; task_path='\Lenovo\X'; process_name='' }
        Test-PendingActionAuthorized $p $script:Profiles | Should -Be $false
    }
    It 'tested=false 规则即使 action 被伪造也拒绝 (generic-cn-bloat)' {
        $p = [pscustomobject]@{ id='generic-cn-bloat'; hit_type='service'; action='disable_service'; service_name='360安全卫士'; autostart_name=''; task_path=''; process_name='' }
        Test-PendingActionAuthorized $p $script:Profiles | Should -Be $false
    }
    It 'safe=false 规则被拒绝 (huawei-pcmanager)' {
        $p = [pscustomobject]@{ id='huawei-pcmanager'; hit_type='service'; action='disable_service'; service_name='HuaweiPCManager'; autostart_name=''; task_path=''; process_name='' }
        Test-PendingActionAuthorized $p $script:Profiles | Should -Be $false
    }
    It 'process 命中按标准化名称匹配 (构造正例)' {
        $p = [pscustomobject]@{ id='lenovo-serviceas'; hit_type='process'; action='investigate'; service_name=''; autostart_name=''; task_path=''; process_name='Appvant.exe' }
        Test-PendingActionAuthorized $p $script:Profiles | Should -Be $true
    }
    It 'process 命中大小写/扩展名容错 (AppVANT.EXE → appvant)' {
        $p = [pscustomobject]@{ id='lenovo-serviceas'; hit_type='process'; action='investigate'; service_name=''; autostart_name=''; task_path=''; process_name='AppVANT.EXE' }
        Test-PendingActionAuthorized $p $script:Profiles | Should -Be $true
    }
    It 'process target 不在 detect 被拒绝' {
        $p = [pscustomobject]@{ id='lenovo-serviceas'; hit_type='process'; action='investigate'; service_name=''; autostart_name=''; task_path=''; process_name='totally-unrelated.exe' }
        Test-PendingActionAuthorized $p $script:Profiles | Should -Be $false
    }
}
