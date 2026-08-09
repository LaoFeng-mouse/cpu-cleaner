# Schema 3.0 专项测试 (v1.6.0): match_type 分发 / 执行闸门 / detect 格式校验
# 运行: Import-Module Pester -RequiredVersion 5.9.0; Invoke-Pester tests\Pester\Schema3.Tests.ps1
BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:Root 'cpu-cleaner.ps1') -NoProfile
}

Describe 'Test-DetectMatch (match_type 分发)' {
    It 'exact 匹配 (大小写不敏感)' {
        Test-DetectMatch 'LenovoServiceAS' @{ match = 'lenovoserviceas'; type = 'exact' } | Should -BeTrue
        Test-DetectMatch 'LenovoServiceAS' @{ match = 'LenovoService'; type = 'exact' } | Should -BeFalse
    }
    It 'contains 默认行为 (字符串 = contains)' {
        Test-DetectMatch 'LenovoServiceAS' 'LenovoService' | Should -BeTrue
        Test-DetectMatch 'LenovoServiceAS' @{ match = 'lenovo'; type = 'contains' } | Should -BeTrue
    }
    It 'regex 匹配' {
        Test-DetectMatch 'WeChatAppEx.exe' @{ match = '^WeChat'; type = 'regex' } | Should -BeTrue
        Test-DetectMatch 'QQMusic.exe' @{ match = '^WeChat'; type = 'regex' } | Should -BeFalse
    }
    It 'regex 非法表达式不抛错返回 false' {
        Test-DetectMatch 'abc' @{ match = '['; type = 'regex' } | Should -BeFalse
    }
    It 'path 前缀匹配' {
        Test-DetectMatch 'C:\Program Files\Lenovo\ImController\Lenovo.Modern.ImController.exe' @{ match = 'C:\Program Files\Lenovo'; type = 'path' } | Should -BeTrue
        Test-DetectMatch 'D:\Games\steam.exe' @{ match = 'C:\Program Files'; type = 'path' } | Should -BeFalse
    }
    It '空 match / null target 返回 false' {
        Test-DetectMatch 'anything' @{ match = ''; type = 'exact' } | Should -BeFalse
        Test-DetectMatch $null 'x' | Should -BeFalse
    }
    It '未知 type 回退 contains' {
        Test-DetectMatch 'abc123' @{ match = '123'; type = 'fuzzy' } | Should -BeTrue
    }
}

Describe 'Schema 3.0 执行闸门 (识别可以宽, 执行必须窄)' {
    It 'exact 危险动作无需 allow_auto 保留' {
        $tmp = Join-Path $env:TEMP ("s3a_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.profiles[0].actions.service | Should -Be 'disable_service'
    }
    It 'contains 危险动作无 allow_auto → 降级 investigate' {
        $tmp = Join-Path $env:TEMP ("s3b_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"contains"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.profiles[0].actions.service | Should -Be 'investigate'
    }
    It 'contains 危险动作 + allow_auto=true → 保留' {
        $tmp = Join-Path $env:TEMP ("s3c_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"execution":{"allow_auto":true,"review_note":"实机验证"},"detect":{"services":[{"match":"S1","type":"contains"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.profiles[0].actions.service | Should -Be 'disable_service'
    }
    It '宽匹配规则加载后带降级标注 (execution 保留原始信息)' {
        $tmp = Join-Path $env:TEMP ("s3d_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"regex"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_task","process":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.profiles[0].actions.service | Should -Be 'investigate'
    }
}

Describe 'Schema 3.0 格式校验' {
    It '非法 match_type → 拒绝加载' {
        $tmp = Join-Path $env:TEMP ("s3e_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"bogus"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should -Throw '*匹配类型非法*'
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It '空 match 项 → 拒绝加载' {
        $tmp = Join-Path $env:TEMP ("s3f_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should -Throw '*空匹配项*'
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'schema_version=4 → 拒绝加载' {
        $tmp = Join-Path $env:TEMP ("s3g_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":4,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should -Throw '*高于程序支持的 v3*'
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'allow_auto 非布尔 → 拒绝加载' {
        $tmp = Join-Path $env:TEMP ("s3h_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","execution":{"allow_auto":"yes"},"detect":{"services":[{"match":"S1","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should -Throw '*allow_auto 必须是布尔值*'
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'v2 字符串格式自动迁移为 v3 (转换后 detect 对象化 + schema_version=3)' {
        $tmp = Join-Path $env:TEMP ("s3i_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":2,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":["S1"],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.schema_version | Should -Be 3
        $p.profiles[0].detect.services[0].match | Should -Be 'S1'
        $p.profiles[0].detect.services[0].type | Should -Be 'contains'
        # v2 无 evidence → allow_auto=false → contains 危险动作降级
        $p.profiles[0].actions.service | Should -Be 'investigate'
    }
}

Describe 'Schema 3.0 集成 (真实特征库 v3 + Match-Profiles + 授权)' {
    It 'detect 对象化后服务命中正常 (contains, 真实 lenovo-serviceas 规则)' {
        $svc = [pscustomobject]@{ Name = 'LenovoServiceAS'; DisplayName = '联想服务'; State = 'Running'; StartMode = 'Automatic' }
        $hits = Match-Profiles -Services @($svc) -AutoStarts @() -Tasks @() -TopProcs @()
        $hit = @($hits | Where-Object { $_.hit_type -eq 'service' -and $_.id -eq 'lenovo-serviceas' }) | Select-Object -First 1
        $hit | Should -Not -BeNullOrEmpty
        $hit.action | Should -Be 'disable_service'
    }
    It '授权验证 target 检查兼容对象化 detect' {
        $profiles = Load-Profiles
        $rule = @($profiles.profiles | Where-Object { $_.id -eq 'lenovo-serviceas' }) | Select-Object -First 1
        $rule | Should -Not -BeNullOrEmpty
        $pending = [pscustomobject]@{ rule_id = 'lenovo-serviceas'; hit_type = 'service'; action = 'disable_service'; service_name = 'LenovoServiceAS'; autostart_name = ''; task_path = ''; process_name = ''; id = 'lenovo-serviceas' }
        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
        $pending2 = [pscustomobject]@{ rule_id = 'lenovo-serviceas'; hit_type = 'service'; action = 'disable_service'; service_name = 'HackerService'; autostart_name = ''; task_path = ''; process_name = ''; id = 'lenovo-serviceas' }
        Test-PendingActionAuthorized $pending2 $profiles | Should -BeFalse
    }
}
