# Schema 3.0 专项测试 (v1.6.0): match_type 分发 / 执行闸门 / detect 格式校验
# 运行: Import-Module Pester -RequiredVersion 5.9.0; Invoke-Pester tests\Pester\Schema3.Tests.ps1
BeforeAll {
    $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Root = $projectRoot
    $script:ProfileFile = Join-Path $script:Root 'bloatware-profiles.json'
    $script:PendingFile = Join-Path $script:Root 'pending_actions.json'
    $script:BackupRoot = Join-Path $script:Root 'backups'
    $script:Version = '1.7.0'
    $script:ProfileUrl = ''
    $script:ProfileSha256Url = ''
    foreach ($f in @('Utils','ProfileEngine','Scanner','RiskEngine','ReportEngine','ActionEngine','BackupManager')) {
        . (Join-Path $projectRoot ('src\Core\' + $f + '.ps1'))
    }
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
    It 'contains 使用大小写不敏感的序号字面子串匹配' {
        Test-DetectMatch 'abc*def' @{ match = '*'; type = 'contains' } | Should -BeTrue
        Test-DetectMatch 'abcdef' @{ match = '*'; type = 'contains' } | Should -BeFalse
        Test-DetectMatch 'abc?def' @{ match = '?'; type = 'contains' } | Should -BeTrue
        Test-DetectMatch 'abcXdef' @{ match = '?'; type = 'contains' } | Should -BeFalse
        Test-DetectMatch 'abc[def]' @{ match = '[def]'; type = 'contains' } | Should -BeTrue
        Test-DetectMatch 'abcdef' @{ match = '[def]'; type = 'contains' } | Should -BeFalse
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
    It 'path 使用大小写不敏感的序号字面前缀匹配' {
        Test-DetectMatch 'c:\PROGRAM FILES\Lenovo\app.exe' @{ match = 'C:\Program Files\Lenovo'; type = 'path' } | Should -BeTrue
        Test-DetectMatch 'C:\Apps\[*]\app.exe' @{ match = 'C:\Apps\[*]'; type = 'path' } | Should -BeTrue
        Test-DetectMatch 'C:\Apps\x\app.exe' @{ match = 'C:\Apps\[*]'; type = 'path' } | Should -BeFalse
    }
    It '空 match / null target 返回 false' {
        Test-DetectMatch 'anything' @{ match = ''; type = 'exact' } | Should -BeFalse
        Test-DetectMatch $null 'x' | Should -BeFalse
    }
    It '未知 type 返回 false' {
        Test-DetectMatch 'abc123' @{ match = '123'; type = 'fuzzy' } | Should -BeFalse
    }
}

Describe '进程标准化匹配保持字面语义' {
    It 'Match-Profiles 不把 contains 通配符解释为模式' {
        $tmp = Join-Path $env:TEMP ("s3_process_" + [guid]::NewGuid().ToString('N') + ".json")
        $originalProfileFile = $script:ProfileFile
        try {
            [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"process-wildcard","vendor":"T","name_cn":"进程字面匹配","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"execution":{"allow_auto":true},"detect":{"services":[],"processes":[{"match":"foo*bar","type":"contains"}],"autostarts":[],"tasks":[]},"actions":{"process":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
            $script:ProfileFile = $tmp

            $wildcardHit = Match-Profiles -Services @() -AutoStarts @() -Tasks @() -TopProcs @([pscustomobject]@{ Name = 'fooXbar.exe'; PID = 1; 'CPU%' = 1; Path = 'C:\fooXbar.exe' })
            $literalHit = Match-Profiles -Services @() -AutoStarts @() -Tasks @() -TopProcs @([pscustomobject]@{ Name = 'foo*bar.exe'; PID = 2; 'CPU%' = 1; Path = 'C:\foo*bar.exe' })

            @($wildcardHit).Count | Should -Be 0
            @($literalHit).Count | Should -Be 1
        } finally {
            $script:ProfileFile = $originalProfileFile
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    It '授权校验不把 contains 通配符解释为模式' {
        $rule = [pscustomobject]@{
            id = 'process-wildcard'; safe = $true
            evidence = [pscustomobject]@{ tested = $true }
            detect = [pscustomobject]@{ services = @(); processes = @([pscustomobject]@{ match = 'foo*bar'; type = 'contains' }); autostarts = @(); tasks = @() }
            actions = [pscustomobject]@{ process = 'investigate' }
        }
        $profiles = [pscustomobject]@{ profiles = @($rule) }
        $pending = [pscustomobject]@{ id = 'process-wildcard'; hit_type = 'process'; action = 'investigate'; process_name = 'fooXbar.exe' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
        $pending.process_name = 'foo*bar.exe'
        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
    }

    It 'Match-Profiles 对 regex 使用标准化后的进程名' {
        $tmp = Join-Path $env:TEMP ("s3_process_regex_" + [guid]::NewGuid().ToString('N') + ".json")
        $originalProfileFile = $script:ProfileFile
        try {
            [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"process-regex","vendor":"T","name_cn":"进程正则匹配","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"execution":{"allow_auto":true},"detect":{"services":[],"processes":[{"match":"^foo$","type":"regex"}],"autostarts":[],"tasks":[]},"actions":{"process":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
            $script:ProfileFile = $tmp

            $hits = Match-Profiles -Services @() -AutoStarts @() -Tasks @() -TopProcs @([pscustomobject]@{ Name = 'foo.exe'; PID = 3; 'CPU%' = 1; Path = 'C:\foo.exe' })

            @($hits).Count | Should -Be 1
        } finally {
            $script:ProfileFile = $originalProfileFile
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    It '授权校验对 regex 使用标准化后的进程名' {
        $rule = [pscustomobject]@{
            id = 'process-regex'; safe = $true
            evidence = [pscustomobject]@{ tested = $true }
            detect = [pscustomobject]@{ services = @(); processes = @([pscustomobject]@{ match = '^foo$'; type = 'regex' }); autostarts = @(); tasks = @() }
            actions = [pscustomobject]@{ process = 'investigate' }
        }
        $profiles = [pscustomobject]@{ profiles = @($rule) }
        $pending = [pscustomobject]@{ id = 'process-regex'; hit_type = 'process'; action = 'investigate'; process_name = 'foo.exe' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
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
    It 'contains 危险动作加载时保留声明值' {
        $tmp = Join-Path $env:TEMP ("s3b_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"contains"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.profiles[0].actions.service | Should -Be 'disable_service'
    }
    It 'contains 危险动作 + allow_auto=true 加载时保留声明值' {
        $tmp = Join-Path $env:TEMP ("s3c_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"execution":{"allow_auto":true,"review_note":"实机验证"},"detect":{"services":[{"match":"S1","type":"contains"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.profiles[0].actions.service | Should -Be 'disable_service'
    }
    It 'regex 危险动作加载时保留声明值' {
        $tmp = Join-Path $env:TEMP ("s3d_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"regex"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_task","process":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.profiles[0].actions.service | Should -Be 'disable_task'
    }
}

Describe 'Schema 3.0 命中证据与逐命中执行闸门' {
    It '混合规则按实际命中证据决定动作并保留规则顺序' {
        $tmp = Join-Path $env:TEMP ("s3_hit_mixed_" + [guid]::NewGuid().ToString('N') + ".json")
        $originalProfileFile = $script:ProfileFile
        try {
            [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"mixed-service","vendor":"Lenovo","name_cn":"混合服务规则","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"execution":{"allow_auto":true},"detect":{"services":[{"match":"LenovoExactService","type":"exact"},{"match":"Lenovo","type":"contains"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
            $script:ProfileFile = $tmp

            $services = @(
                [pscustomobject]@{ Name = 'LenovoOtherService'; DisplayName = 'Other'; State = 'Running'; StartMode = 'Automatic' },
                [pscustomobject]@{ Name = 'LenovoExactService'; DisplayName = 'Exact'; State = 'Running'; StartMode = 'Automatic' }
            )
            $hits = @(Match-Profiles -Services $services -AutoStarts @() -Tasks @() -TopProcs @())
            $broadHit = @($hits | Where-Object { $_.service_name -eq 'LenovoOtherService' }) | Select-Object -First 1
            $exactHit = @($hits | Where-Object { $_.service_name -eq 'LenovoExactService' }) | Select-Object -First 1

            $broadHit | Should -Not -BeNullOrEmpty
            $broadHit.action | Should -Be 'investigate'
            $broadHit.matched_pattern | Should -Be 'Lenovo'
            $broadHit.matched_type | Should -Be 'contains'
            $broadHit.matched_field | Should -Be 'service_name'
            $exactHit.action | Should -Be 'disable_service'
            $exactHit.matched_pattern | Should -Be 'LenovoExactService'
            $exactHit.matched_type | Should -Be 'exact'
            $exactHit.matched_field | Should -Be 'service_name'
        } finally {
            $script:ProfileFile = $originalProfileFile
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    It 'pure contains 即使 allow_auto=true 也只生成 investigate 命中' {
        $tmp = Join-Path $env:TEMP ("s3_hit_contains_" + [guid]::NewGuid().ToString('N') + ".json")
        $originalProfileFile = $script:ProfileFile
        try {
            [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"broad-service","vendor":"Lenovo","name_cn":"宽服务规则","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"execution":{"allow_auto":true},"detect":{"services":[{"match":"Lenovo","type":"contains"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
            $script:ProfileFile = $tmp

            $hits = @(Match-Profiles -Services @([pscustomobject]@{ Name = 'LenovoOtherService'; DisplayName = 'Other'; State = 'Running'; StartMode = 'Automatic' }) -AutoStarts @() -Tasks @() -TopProcs @())

            $hits.Count | Should -Be 1
            $hits[0].action | Should -Be 'investigate'
            $hits[0].matched_type | Should -Be 'contains'
        } finally {
            $script:ProfileFile = $originalProfileFile
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    It '记录实际命中的 service display name 字段' {
        $tmp = Join-Path $env:TEMP ("s3_hit_display_" + [guid]::NewGuid().ToString('N') + ".json")
        $originalProfileFile = $script:ProfileFile
        try {
            [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"display-service","vendor":"Lenovo","name_cn":"显示名规则","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"detect":{"services":[{"match":"Lenovo Display Service","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
            $script:ProfileFile = $tmp

            $hits = @(Match-Profiles -Services @([pscustomobject]@{ Name = 'UnrelatedInternalName'; DisplayName = 'Lenovo Display Service'; State = 'Running'; StartMode = 'Automatic' }) -AutoStarts @() -Tasks @() -TopProcs @())

            $hits.Count | Should -Be 1
            $hits[0].action | Should -Be 'disable_service'
            $hits[0].matched_pattern | Should -Be 'Lenovo Display Service'
            $hits[0].matched_type | Should -Be 'exact'
            $hits[0].matched_field | Should -Be 'service_display_name'
        } finally {
            $script:ProfileFile = $originalProfileFile
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
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
        # 加载只做迁移和校验, 不改写声明动作; 执行资格由实际命中证据决定
        $p.profiles[0].actions.service | Should -Be 'disable_service'
    }
}

Describe 'Schema 3.0 集成 (真实特征库 v3 + Match-Profiles + 授权)' {
    It 'detect 对象化后服务命中正常 (contains, 真实 lenovo-serviceas 规则)' {
        $svc = [pscustomobject]@{ Name = 'LenovoServiceAS'; DisplayName = '联想服务'; State = 'Running'; StartMode = 'Automatic' }
        $hits = Match-Profiles -Services @($svc) -AutoStarts @() -Tasks @() -TopProcs @()
        $hit = @($hits | Where-Object { $_.hit_type -eq 'service' -and $_.id -eq 'lenovo-serviceas' }) | Select-Object -First 1
        $hit | Should -Not -BeNullOrEmpty
        $hit.action | Should -Be 'investigate'
        $hit.matched_pattern | Should -Be 'LenovoServiceAS'
        $hit.matched_type | Should -Be 'contains'
        $hit.matched_field | Should -Be 'service_name'
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
