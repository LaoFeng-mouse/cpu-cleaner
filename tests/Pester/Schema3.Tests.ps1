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
    if (-not ('CpuCleaner.Tests.ThrowingPublisherValue' -as [type])) {
        Add-Type -TypeDefinition @'
namespace CpuCleaner.Tests {
    public sealed class ThrowingPublisherValue {
        private readonly string message;
        public ThrowingPublisherValue(string message) { this.message = message; }
        public override string ToString() { throw new System.ArgumentException(message); }
    }
}
'@
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
    It 'publisher 非法表达式不抛错返回 false' {
        $context = [pscustomobject]@{
            Signature = [pscustomobject]@{ SignerCertificate = [pscustomobject]@{ Subject = 'CN=Trusted Publisher' } }
        }
        $result = [pscustomobject]@{ Value = $true }

        { $result.Value = Test-DetectMatch 'C:\Trusted\ExactSvc.exe' @{ match = '['; type = 'publisher' } -Context $context } | Should -Not -Throw
        $result.Value | Should -BeFalse
    }
    It 'publisher 不吞掉 Subject 字符串转换 ArgumentException' {
        $throwingSubject = New-Object CpuCleaner.Tests.ThrowingPublisherValue -ArgumentList 'subject conversion boom'
        $context = [pscustomobject]@{
            Signature = [pscustomobject]@{
                SignerCertificate = [pscustomobject]@{ Subject = $throwingSubject }
            }
        }

        { Test-DetectMatch 'C:\Trusted\ExactSvc.exe' @{ match = 'Trusted'; type = 'publisher' } -Context $context } |
            Should -Throw
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
        $tmp = Join-Path $TestDrive 's3_process.json'
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
        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It 'Match-Profiles 对 regex 使用标准化后的进程名' {
        $tmp = Join-Path $TestDrive 's3_process_regex.json'
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

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }
}

Describe 'Schema 3.0 执行闸门 (识别可以宽, 执行必须窄)' {
    It 'autostart name exact 从 Match 到 pending 绑定原始 Value 且变化后拒绝授权' {
        $oldPendingFile = $script:PendingFile
        try {
            $script:PendingFile = Join-Path $TestDrive 'autostart-name-e2e.json'
            $profile = [pscustomobject]@{
                id='autostart-name-e2e'; vendor='T'; name='Auto'; name_cn='Auto'; risk='high'; safe=$true; reason_cn='r'
                evidence=[pscustomobject]@{ tested=$true }
                detect=[pscustomobject]@{ services=@(); processes=@(); tasks=@(); autostarts=@([pscustomobject]@{ match='Updater'; type='exact' }) }
                actions=[pscustomobject]@{ autostart='remove_autostart' }
            }
            $profiles = [pscustomobject]@{ profiles=@($profile) }
            $script:CurrentAutostartValue = 'C:\Apps\Updater.exe'
            Mock Load-Profiles { $profiles }
            Mock Get-ItemProperty { [pscustomobject]@{ Updater=$script:CurrentAutostartValue } } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }

            $hits = @(Match-Profiles -Services @() -AutoStarts @([pscustomobject]@{ Name='Updater'; Value='C:\Apps\Updater.exe'; Source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }) -Tasks @() -TopProcs @())
            Save-PendingActions -Hits $hits -Suspicious @()
            $saved = Read-StrictPendingJsonFile $script:PendingFile

            $saved.actions[0].matched_field | Should -Be 'autostart_name'
            $saved.actions[0].autostart_value | Should -Be 'C:\Apps\Updater.exe'
            Test-PendingActionAuthorized $saved.actions[0] $profiles | Should -BeTrue
            $script:CurrentAutostartValue = 'C:\Apps\Changed.exe'
            Test-PendingActionAuthorized $saved.actions[0] $profiles | Should -BeFalse
        } finally {
            $script:PendingFile = $oldPendingFile
        }
    }

    It 'autostart value <type> 从 Match 到 pending 再到授权保持原始值' -TestCases @(
        @{ type='exact'; pattern='C:\Apps\Updater.exe'; value='C:\Apps\Updater.exe' }
        @{ type='path'; pattern='C:\Apps'; value='C:\Apps\Updater.exe --silent' }
    ) {
        param($type, $pattern, $value)
        $oldPendingFile = $script:PendingFile
        try {
            $script:PendingFile = Join-Path $TestDrive ("autostart-e2e-$type.json")
            $profile = [pscustomobject]@{
                id='autostart-e2e'; vendor='T'; name='Auto'; name_cn='Auto'; risk='high'; safe=$true; reason_cn='r'
                evidence=[pscustomobject]@{ tested=$true }
                detect=[pscustomobject]@{ services=@(); processes=@(); tasks=@(); autostarts=@([pscustomobject]@{ match=$pattern; type=$type }) }
                actions=[pscustomobject]@{ autostart='remove_autostart' }
            }
            $profiles = [pscustomobject]@{ profiles=@($profile) }
            Mock Load-Profiles { $profiles }
            Mock Get-ItemProperty { [pscustomobject]@{ Updater=$value } } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }

            $hits = @(Match-Profiles -Services @() -AutoStarts @([pscustomobject]@{ Name='Updater'; Value=$value; Source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }) -Tasks @() -TopProcs @())
            Save-PendingActions -Hits $hits -Suspicious @()
            $saved = Read-StrictPendingJsonFile $script:PendingFile

            $hits.Count | Should -Be 1
            $hits[0].autostart_value | Should -Be $value
            $saved.actions[0].autostart_value | Should -Be $value
            Test-PendingActionAuthorized $saved.actions[0] $profiles | Should -BeTrue
        } finally {
            $script:PendingFile = $oldPendingFile
        }
    }

    It '可执行 autostart_value 命中把原始值保存到 pending' {
        $oldPendingFile = $script:PendingFile
        try {
            $script:PendingFile = Join-Path $TestDrive 'autostart-value-pending.json'
            Mock Get-ItemProperty { [pscustomobject]@{ Updater='C:\Apps\old.exe' } } -ParameterFilter { $Path -eq 'HKCU:\Software\Vendor\Run' }
            $hit = [pscustomobject]@{
                id='autostart-value'; vendor='T'; name_cn='Auto'; action='remove_autostart'; hit_type='autostart'; detail='Updater'; reason_cn='r'
                service_name=''; autostart_source='HKCU:\Software\Vendor\Run'; autostart_name='Updater'; autostart_value='C:\Apps\old.exe'
                task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{tested=$true}
                matched_pattern='C:\Apps'; matched_type='path'; matched_field='autostart_value'
            }

            Save-PendingActions -Hits @($hit) -Suspicious @()

            $saved = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($saved.actions).Count | Should -Be 1
            $saved.actions[0].autostart_value | Should -Be 'C:\Apps\old.exe'
        } finally {
            $script:PendingFile = $oldPendingFile
        }
    }

    It 'path 证据只允许真实路径字段且语义无效命中只保存为 observation' {
        $validFields = @(
            [pscustomobject]@{ hit_type='autostart'; matched_pattern='C:\Apps'; matched_type='path'; matched_field='autostart_value' },
            [pscustomobject]@{ hit_type='task'; matched_pattern='\Vendor'; matched_type='path'; matched_field='task_path' },
            [pscustomobject]@{ hit_type='process'; matched_pattern='C:\Apps'; matched_type='path'; matched_field='process_path' }
        )
        foreach ($evidence in $validFields) {
            Test-HitMatcherEvidenceShape $evidence | Should -BeTrue
        }
        foreach ($case in @(
            @{ hit_type='service'; field='service_name' },
            @{ hit_type='service'; field='service_display_name' },
            @{ hit_type='autostart'; field='autostart_name' },
            @{ hit_type='task'; field='task_name' },
            @{ hit_type='process'; field='process_name' }
        )) {
            $evidence = [pscustomobject]@{ hit_type=$case.hit_type; matched_pattern='C:\Apps'; matched_type='path'; matched_field=$case.field }
            Test-HitMatcherEvidenceShape $evidence | Should -BeFalse -Because ($case.hit_type + '/' + $case.field)
        }

        $oldPendingFile = $script:PendingFile
        try {
            $script:PendingFile = Join-Path $TestDrive 'invalid-path-pending.json'
            $hit = [pscustomobject]@{
                id='invalid-path'; vendor='T'; name_cn='Invalid'; action='disable_service'; hit_type='service'; detail='Svc'; reason_cn='r'
                service_name='Svc'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
                safe=$true; evidence=[pscustomobject]@{tested=$true}
                matched_pattern='Svc'; matched_type='path'; matched_field='service_name'
            }
            Save-PendingActions -Hits @($hit) -Suspicious @()
            $saved = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($saved.actions).Count | Should -Be 0
            @($saved.observations).Count | Should -Be 1
        } finally {
            $script:PendingFile = $oldPendingFile
        }
    }

    It 'exact 危险动作无需 allow_auto 保留' {
        $tmp = Join-Path $TestDrive 's3a.json'
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.profiles[0].actions.service | Should -Be 'disable_service'
    }
    It 'contains 危险动作加载时保留声明值' {
        $tmp = Join-Path $TestDrive 's3b.json'
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"contains"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.profiles[0].actions.service | Should -Be 'disable_service'
    }
    It 'contains 危险动作 + allow_auto=true 加载时保留声明值' {
        $tmp = Join-Path $TestDrive 's3c.json'
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"execution":{"allow_auto":true,"review_note":"实机验证"},"detect":{"services":[{"match":"S1","type":"contains"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.profiles[0].actions.service | Should -Be 'disable_service'
    }
    It 'regex 危险动作加载时保留声明值' {
        $tmp = Join-Path $TestDrive 's3d.json'
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"regex"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service","process":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.profiles[0].actions.service | Should -Be 'disable_service'
    }
}

Describe 'Schema 3.0 命中证据与逐命中执行闸门' {
    It 'keeps an earlier exact match when a later publisher expression is invalid' {
        $context = [pscustomobject]@{
            Path = 'C:\Trusted\ExactSvc.exe'
            Signature = [pscustomobject]@{ SignerCertificate = [pscustomobject]@{ Subject = 'CN=Trusted Publisher' } }
        }
        $patterns = @(
            [pscustomobject]@{ match='ExactSvc'; type='exact' },
            [pscustomobject]@{ match='['; type='publisher' }
        )
        $candidates = @(
            [pscustomobject]@{ field='service_name'; value='ExactSvc'; context=$context },
            [pscustomobject]@{ field='service_path'; value='C:\Trusted\ExactSvc.exe'; context=$context }
        )
        $result = [pscustomobject]@{ Evidence = $null }

        { $result.Evidence = Find-DetectMatch $patterns $candidates } | Should -Not -Throw
        $result.Evidence.matched_pattern | Should -BeExactly 'ExactSvc'
        $result.Evidence.matched_type | Should -BeExactly 'exact'
        $result.Evidence.matched_field | Should -BeExactly 'service_name'
    }

    It 'assigns deterministic strengths to matcher types' {
        @(
            [pscustomobject]@{ Type='exact'; Expected=0 },
            [pscustomobject]@{ Type='path'; Expected=1 },
            [pscustomobject]@{ Type='contains'; Expected=2 },
            [pscustomobject]@{ Type='regex'; Expected=3 },
            [pscustomobject]@{ Type='publisher'; Expected=4 }
        ) | ForEach-Object {
            Get-DetectMatchStrength $_.Type | Should -Be $_.Expected
        }
    }

    It 'prefers an actually matched exact rule even when contains is declared first' {
        $patterns = @(
            [pscustomobject]@{ match='Lenovo'; type='contains' },
            [pscustomobject]@{ match='LenovoExactService'; type='exact' }
        )
        $evidence = Find-DetectMatch $patterns @(
            [pscustomobject]@{ field='service_name'; value='LenovoExactService'; context=$null }
        )

        $evidence.matched_pattern | Should -BeExactly 'LenovoExactService'
        $evidence.matched_type | Should -BeExactly 'exact'
        $evidence.matched_field | Should -BeExactly 'service_name'
    }

    It 'does not borrow an exact matcher that did not match the current object' {
        $patterns = @(
            [pscustomobject]@{ match='Lenovo'; type='contains' },
            [pscustomobject]@{ match='LenovoExactService'; type='exact' }
        )
        $evidence = Find-DetectMatch $patterns @(
            [pscustomobject]@{ field='service_name'; value='LenovoOtherService'; context=$null }
        )

        $evidence.matched_pattern | Should -BeExactly 'Lenovo'
        $evidence.matched_type | Should -BeExactly 'contains'
    }

    It 'keeps declaration and candidate order stable among equally strong matches' {
        $patterns = @(
            [pscustomobject]@{ match='Lenovo'; type='contains' },
            [pscustomobject]@{ match='Service'; type='contains' }
        )
        $evidence = Find-DetectMatch $patterns @(
            [pscustomobject]@{ field='service_display_name'; value='Lenovo Service'; context=$null },
            [pscustomobject]@{ field='service_name'; value='LenovoService'; context=$null }
        )

        $evidence.matched_pattern | Should -BeExactly 'Lenovo'
        $evidence.matched_field | Should -BeExactly 'service_display_name'
    }

    It '混合规则按实际命中证据决定动作并保留规则顺序' {
        $tmp = Join-Path $TestDrive 's3_hit_mixed.json'
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
        $tmp = Join-Path $TestDrive 's3_hit_contains.json'
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
        $tmp = Join-Path $TestDrive 's3_hit_display.json'
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

Describe 'Schema 3.0 进程字段语义隔离' {
    It '路径形 exact 不得通过同名进程在其他路径命中' {
        $tmp = Join-Path $TestDrive 's3_process_exact_path.json'
        $originalProfileFile = $script:ProfileFile
        try {
            [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"process-exact-path","vendor":"T","name_cn":"进程路径精确匹配","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":true},"detect":{"services":[],"processes":[{"match":"C:\\Trusted\\foo.exe","type":"exact"}],"autostarts":[],"tasks":[]},"actions":{"process":"uninstall"}}]}', (New-Object System.Text.UTF8Encoding($false)))
            $script:ProfileFile = $tmp

            $wrongPathHits = @(Match-Profiles -Services @() -AutoStarts @() -Tasks @() -TopProcs @([pscustomobject]@{ Name = 'foo.exe'; PID = 41; 'CPU%' = 1; Path = 'C:\Elsewhere\foo.exe' }))
            $trustedPathHits = @(Match-Profiles -Services @() -AutoStarts @() -Tasks @() -TopProcs @([pscustomobject]@{ Name = 'foo.exe'; PID = 42; 'CPU%' = 1; Path = 'C:\Trusted\foo.exe' }))

            $wrongPathHits.Count | Should -Be 0
            $trustedPathHits.Count | Should -Be 1
            $trustedPathHits[0].action | Should -Be 'uninstall'
            $trustedPathHits[0].matched_pattern | Should -Be 'C:\Trusted\foo.exe'
            $trustedPathHits[0].matched_type | Should -Be 'exact'
            $trustedPathHits[0].matched_field | Should -Be 'process_path'
            $trustedPathHits[0].process_id | Should -Be 42
            $trustedPathHits[0].process_path | Should -Be 'C:\Trusted\foo.exe'
        } finally {
            $script:ProfileFile = $originalProfileFile
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    It '<type> 证据只归因于 process_path' -TestCases @(
        @{ type = 'publisher'; match = 'Trusted Publisher' }
        @{ type = 'sha256'; match = 'ABC123' }
    ) {
        param($type, $match)
        $context = [pscustomobject]@{
            Path = 'C:\Trusted\foo.exe'
            Signature = [pscustomobject]@{ SignerCertificate = [pscustomobject]@{ Subject = 'CN=Trusted Publisher' } }
            FileHash = 'ABC123'
        }
        $candidates = @(
            [pscustomobject]@{ field = 'process_name'; value = 'foo.exe'; context = $context },
            [pscustomobject]@{ field = 'process_path'; value = 'C:\Trusted\foo.exe'; context = $context }
        )

        $evidence = Find-DetectMatch @([pscustomobject]@{ match = $match; type = $type }) $candidates -NormalizeProcessName

        $evidence | Should -Not -BeNullOrEmpty
        $evidence.matched_pattern | Should -Be $match
        $evidence.matched_type | Should -Be $type
        $evidence.matched_field | Should -Be 'process_path'
    }
}

Describe 'Schema 3.0 matched_field 覆盖矩阵' {
    It '为自启、任务和进程的每种候选字段各生成一条命中' {
        $tmp = Join-Path $TestDrive 's3_field_matrix.json'
        $originalProfileFile = $script:ProfileFile
        try {
            $profiles = @(
                [pscustomobject]@{ id='auto-name'; vendor='T'; name_cn='a1'; risk='high'; safe=$true; reason_cn='r'; evidence=[pscustomobject]@{tested=$true}; detect=[pscustomobject]@{services=@();processes=@();autostarts=@([pscustomobject]@{match='AutoName';type='exact'});tasks=@()}; actions=[pscustomobject]@{autostart='investigate'} },
                [pscustomobject]@{ id='auto-value'; vendor='T'; name_cn='a2'; risk='high'; safe=$true; reason_cn='r'; evidence=[pscustomobject]@{tested=$true}; detect=[pscustomobject]@{services=@();processes=@();autostarts=@([pscustomobject]@{match='C:\Vendor\auto.exe';type='exact'});tasks=@()}; actions=[pscustomobject]@{autostart='investigate'} },
                [pscustomobject]@{ id='task-name'; vendor='T'; name_cn='t1'; risk='high'; safe=$true; reason_cn='r'; evidence=[pscustomobject]@{tested=$true}; detect=[pscustomobject]@{services=@();processes=@();autostarts=@();tasks=@([pscustomobject]@{match='NameTask';type='exact'})}; actions=[pscustomobject]@{task='investigate'} },
                [pscustomobject]@{ id='task-path'; vendor='T'; name_cn='t2'; risk='high'; safe=$true; reason_cn='r'; evidence=[pscustomobject]@{tested=$true}; detect=[pscustomobject]@{services=@();processes=@();autostarts=@();tasks=@([pscustomobject]@{match='\Vendor\FullTask';type='exact'})}; actions=[pscustomobject]@{task='investigate'} },
                [pscustomobject]@{ id='proc-name'; vendor='T'; name_cn='p1'; risk='high'; safe=$true; reason_cn='r'; evidence=[pscustomobject]@{tested=$true}; detect=[pscustomobject]@{services=@();processes=@([pscustomobject]@{match='foo.exe';type='exact'});autostarts=@();tasks=@()}; actions=[pscustomobject]@{process='investigate'} },
                [pscustomobject]@{ id='proc-path'; vendor='T'; name_cn='p2'; risk='high'; safe=$true; reason_cn='r'; evidence=[pscustomobject]@{tested=$true}; detect=[pscustomobject]@{services=@();processes=@([pscustomobject]@{match='C:\Trusted';type='path'});autostarts=@();tasks=@()}; actions=[pscustomobject]@{process='investigate'} }
            )
            $json = [pscustomobject]@{ schema_version = 3; profiles = $profiles } | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
            $script:ProfileFile = $tmp

            $hits = @(Match-Profiles -Services @() -AutoStarts @(
                [pscustomobject]@{ Name='AutoName'; Value='C:\Other\one.exe'; Source='HKCU' },
                [pscustomobject]@{ Name='OtherAuto'; Value='C:\Vendor\auto.exe'; Source='HKLM' }
            ) -Tasks @(
                [pscustomobject]@{ TaskName='NameTask'; TaskPath='\Other\'; State='Ready' },
                [pscustomobject]@{ TaskName='FullTask'; TaskPath='\Vendor\'; State='Ready' }
            ) -TopProcs @(
                [pscustomobject]@{ Name='FOO.EXE'; PID=51; 'CPU%'=1; Path='C:\Elsewhere\foo.exe' },
                [pscustomobject]@{ Name='bar.exe'; PID=52; 'CPU%'=1; Path='C:\Trusted\bar.exe' }
            ))

            $expectedFields = @{
                'auto-name'='autostart_name'; 'auto-value'='autostart_value'
                'task-name'='task_name'; 'task-path'='task_path'
                'proc-name'='process_name'; 'proc-path'='process_path'
            }
            $hits.Count | Should -Be 6
            foreach ($id in $expectedFields.Keys) {
                $profileHits = @($hits | Where-Object { $_.id -eq $id })
                $profileHits.Count | Should -Be 1
                $profileHits[0].matched_field | Should -Be $expectedFields[$id]
            }
            @($hits | Where-Object { $_.id -eq 'task-path' })[0].task_path | Should -Be '\Vendor\FullTask'
            $nameProcess = @($hits | Where-Object { $_.id -eq 'proc-name' })[0]
            $nameProcess.process_id | Should -Be 51
            $nameProcess.process_path | Should -Be 'C:\Elsewhere\foo.exe'
            $pathProcess = @($hits | Where-Object { $_.id -eq 'proc-path' })[0]
            $pathProcess.process_id | Should -Be 52
            $pathProcess.process_path | Should -Be 'C:\Trusted\bar.exe'
            $pathProcess.matched_type | Should -Be 'path'
        } finally {
            $script:ProfileFile = $originalProfileFile
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Schema 3.0 格式校验' {
    It '非法 match_type → 拒绝加载' {
        $tmp = Join-Path $TestDrive 's3e.json'
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"bogus"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should -Throw '*匹配类型非法*'
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It '空 match 项 → 拒绝加载' {
        $tmp = Join-Path $TestDrive 's3f.json'
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should -Throw '*空匹配项*'
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'schema_version=4 → 拒绝加载' {
        $tmp = Join-Path $TestDrive 's3g.json'
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":4,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"S1","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should -Throw '*高于程序支持的 v3*'
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'allow_auto 非布尔 → 拒绝加载' {
        $tmp = Join-Path $TestDrive 's3h.json'
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","execution":{"allow_auto":"yes"},"detect":{"services":[{"match":"S1","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should -Throw '*allow_auto 必须是布尔值*'
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'safe <label> → 拒绝加载' -TestCases @(
        @{ label='missing'; fragment='' }
        @{ label='null'; fragment='"safe":null,' }
        @{ label='string'; fragment='"safe":"true",' }
        @{ label='number'; fragment='"safe":1,' }
        @{ label='array'; fragment='"safe":[true],' }
    ) {
        param($label, $fragment)
        $tmp = Join-Path $TestDrive ("safe_$label.json")
        $json = '{"schema_version":3,"profiles":[{"id":"safe-type","vendor":"T","name_cn":"测试","risk":"high",' + $fragment + '"reason_cn":"r","detect":{"services":[{"match":"S1","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"investigate"}}]}'
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))

        { Load-Profiles -Path $tmp } | Should -Throw '*safe 必须是布尔值*'
    }
    It 'evidence.tested <label> → 拒绝加载' -TestCases @(
        @{ label='null'; value='null' }
        @{ label='string'; value='"true"' }
        @{ label='number'; value='1' }
        @{ label='array'; value='[true]' }
    ) {
        param($label, $value)
        $tmp = Join-Path $TestDrive ("tested_$label.json")
        $json = '{"schema_version":3,"profiles":[{"id":"tested-type","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","evidence":{"tested":' + $value + '},"detect":{"services":[{"match":"S1","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"investigate"}}]}'
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))

        { Load-Profiles -Path $tmp } | Should -Throw '*evidence.tested 必须是布尔值*'
    }
    It 'evidence 或 tested 缺失兼容加载且 safe=false 非危险动作有效' {
        $tmp = Join-Path $TestDrive 'optional_evidence.json'
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":3,"profiles":[{"id":"no-evidence","vendor":"T","name_cn":"a","risk":"high","safe":true,"reason_cn":"r","detect":{"services":[{"match":"A","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}},{"id":"no-tested","vendor":"T","name_cn":"b","risk":"high","safe":true,"reason_cn":"r","evidence":{},"detect":{"services":[{"match":"B","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}},{"id":"safe-false","vendor":"T","name_cn":"c","risk":"high","safe":false,"reason_cn":"r","evidence":{"tested":false},"detect":{"services":[{"match":"C","type":"exact"}],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"investigate"}}]}', (New-Object System.Text.UTF8Encoding($false)))

        $loaded = Load-Profiles -Path $tmp

        @($loaded.profiles).Count | Should -Be 3
    }
    It '危险动作闸门对缺失、false 或非布尔安全字段失败关闭' {
        $matchEvidence = [pscustomobject]@{ matched_pattern='S1'; matched_type='exact'; matched_field='service_name' }
        $profiles = @(
            [pscustomobject]@{ actions=[pscustomobject]@{service='disable_service'}; safe=$true },
            [pscustomobject]@{ actions=[pscustomobject]@{service='disable_service'}; safe=$true; evidence=[pscustomobject]@{} },
            [pscustomobject]@{ actions=[pscustomobject]@{service='disable_service'}; safe=$true; evidence=[pscustomobject]@{tested=$false} },
            [pscustomobject]@{ actions=[pscustomobject]@{service='disable_service'}; safe=$false; evidence=[pscustomobject]@{tested=$true} },
            [pscustomobject]@{ actions=[pscustomobject]@{service='disable_service'}; safe='true'; evidence=[pscustomobject]@{tested=$true} },
            [pscustomobject]@{ actions=[pscustomobject]@{service='disable_service'}; safe=1; evidence=[pscustomobject]@{tested=$true} },
            [pscustomobject]@{ actions=[pscustomobject]@{service='disable_service'}; safe=$true; evidence=[pscustomobject]@{tested='true'} },
            [pscustomobject]@{ actions=[pscustomobject]@{service='disable_service'}; safe=$true; evidence=[pscustomobject]@{tested=1} }
        )

        foreach ($profile in $profiles) {
            Get-EffectiveHitAction $profile 'service' $matchEvidence | Should -Be 'investigate'
        }
    }
    It 'v2 字符串格式自动迁移为 v3 (转换后 detect 对象化 + schema_version=3)' {
        $tmp = Join-Path $TestDrive 's3i.json'
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
    It '七个已验证 Lenovo 清理规则使用 exact 内部服务名且 evidence.tested=true' {
        $profiles = Load-Profiles -Path $script:ProfileFile
        $expected = @{
            'lenovo-lemcpmanager' = 'LeMCPManagerService'
            'lenovo-xlsmart' = 'XLSmartService'
            'lenovo-lisf' = 'LISFService'
            'lenovo-serviceas' = 'LenovoServiceAS'
            'lenovo-gaserivce' = 'GAService'
            'lenovo-smartconnect' = 'SmartConnect'
            'lenovo-lnvvcam' = 'LnvVCamInstaller'
        }

        foreach ($id in $expected.Keys) {
            $profile = @($profiles.profiles | Where-Object { $_.id -eq $id }) | Select-Object -First 1
            $matcher = @($profile.detect.services | Where-Object { $_.match -ceq $expected[$id] }) | Select-Object -First 1

            $profile | Should -Not -BeNullOrEmpty
            $matcher | Should -Not -BeNullOrEmpty
            $matcher.type | Should -BeExactly 'exact'
            $profile.evidence.tested | Should -BeTrue
        }
    }
    It '真实 LeMCPManager 服务可执行但后缀伪装仅由备用 broad matcher 调查' {
        $services = @(
            [pscustomobject]@{ Name = 'LeMCPManagerService'; DisplayName = 'Real'; State = 'Running'; StartMode = 'Automatic' },
            [pscustomobject]@{ Name = 'LeMCPManagerServiceFake'; DisplayName = 'Fake'; State = 'Running'; StartMode = 'Automatic' }
        )
        $hits = @(Match-Profiles -Services $services -AutoStarts @() -Tasks @() -TopProcs @())
        $real = @($hits | Where-Object { $_.id -eq 'lenovo-lemcpmanager' -and $_.service_name -eq 'LeMCPManagerService' }) | Select-Object -First 1
        $fake = @($hits | Where-Object { $_.id -eq 'lenovo-lemcpmanager' -and $_.service_name -eq 'LeMCPManagerServiceFake' }) | Select-Object -First 1

        $real | Should -Not -BeNullOrEmpty
        $real.action | Should -BeExactly 'disable_service'
        $real.matched_pattern | Should -BeExactly 'LeMCPManagerService'
        $real.matched_type | Should -BeExactly 'exact'
        $real.matched_field | Should -BeExactly 'service_name'

        $fake | Should -Not -BeNullOrEmpty
        $fake.action | Should -BeExactly 'investigate'
        $fake.matched_pattern | Should -BeExactly 'LeMcpManager'
        $fake.matched_type | Should -BeExactly 'contains'
        $fake.matched_field | Should -BeExactly 'service_name'
    }
    It '授权验证 target 检查兼容对象化 detect' {
        $profiles = Load-Profiles
        $rule = @($profiles.profiles | Where-Object { $_.id -eq 'lenovo-serviceas' }) | Select-Object -First 1
        $rule | Should -Not -BeNullOrEmpty
        $pending = [pscustomobject]@{ rule_id = 'lenovo-serviceas'; hit_type = 'service'; action = 'disable_service'; service_name = 'LenovoServiceAS'; autostart_name = ''; task_path = ''; process_name = ''; id = 'lenovo-serviceas' }
        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
        $pending2 = [pscustomobject]@{ rule_id = 'lenovo-serviceas'; hit_type = 'service'; action = 'disable_service'; service_name = 'HackerService'; autostart_name = ''; task_path = ''; process_name = ''; id = 'lenovo-serviceas' }
        Test-PendingActionAuthorized $pending2 $profiles | Should -BeFalse
    }
}
