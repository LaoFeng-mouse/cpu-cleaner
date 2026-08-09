# Pester 测试: clean 提权后授权验证 — pending 视为敌对输入，重新读取当前系统字段
BeforeAll {
    $projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Root = $projectRoot
    $script:ProfileFile = Join-Path $script:Root 'bloatware-profiles.json'
    foreach ($f in @('Utils','ProfileEngine','Scanner','RiskEngine','ReportEngine','ActionEngine','BackupManager')) {
        . (Join-Path $projectRoot ('src\Core\' + $f + '.ps1'))
    }

    function New-AuthProfiles {
        param(
            [string]$Id = 'rule',
            [string]$HitType = 'service',
            $Matchers = @([pscustomobject]@{ match = 'Svc'; type = 'exact' }),
            $Action = 'disable_service',
            $Safe = $true,
            $Tested = $true,
            $AllowAuto = $false
        )
        $detect = [pscustomobject]@{ services = @(); autostarts = @(); tasks = @(); processes = @() }
        $detectKey = @{ service='services'; autostart='autostarts'; task='tasks'; process='processes' }[$HitType]
        $detect.$detectKey = @($Matchers)
        $actions = [pscustomobject]@{}
        $actions | Add-Member -NotePropertyName $HitType -NotePropertyValue $Action
        return [pscustomobject]@{ profiles = @([pscustomobject]@{
            id = $Id; safe = $Safe; evidence = [pscustomobject]@{ tested = $Tested }
            execution = [pscustomobject]@{ allow_auto = $AllowAuto }
            detect = $detect; actions = $actions
        }) }
    }

    function New-ServicePending {
        return [pscustomobject]@{
            id = 'rule'; hit_type = 'service'; action = 'disable_service'; status = 'pending'
            service_name = 'Svc'; matched_pattern = 'Svc'; matched_type = 'exact'; matched_field = 'service_name'
        }
    }
}

Describe '授权验证 (提权后重新确认)' {
    BeforeEach {
        Mock Get-Service { throw "Unexpected Get-Service read: $Name" }
        Mock Get-ItemProperty { throw "Unexpected Get-ItemProperty read: $Path" }
        Mock Get-ScheduledTask { throw "Unexpected Get-ScheduledTask read: $TaskName $TaskPath" }
        Mock Get-Process { throw "Unexpected Get-Process read: $Id" }
    }

    It '真实 broad Lenovo pending 缺少旧 provenance 时拒绝' {
        $profiles = Load-Profiles
        $pending = [pscustomobject]@{
            id='lenovo-serviceas'; hit_type='service'; action='disable_service'; status='pending'; service_name='LenovoServiceAS'
        }
        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It '相同 exact service_name matcher 对当前服务授权成功' {
        $profiles = New-AuthProfiles
        $pending = New-ServicePending
        Mock Get-Service { [pscustomobject]@{ Name='Svc'; DisplayName='Service Display' } } -ParameterFilter { $Name -eq 'Svc' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
    }

    It 'exact service_display_name 只在当前显示名匹配时成功' {
        $profiles = New-AuthProfiles -Matchers @([pscustomobject]@{ match='Service Display'; type='exact' })
        $pending = New-ServicePending
        $pending.matched_pattern = 'Service Display'
        $pending.matched_field = 'service_display_name'
        Mock Get-Service { [pscustomobject]@{ Name='Svc'; DisplayName=$script:CurrentDisplayName } } -ParameterFilter { $Name -eq 'Svc' }

        $script:CurrentDisplayName = 'Service Display'
        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
        $script:CurrentDisplayName = 'Changed Display'
        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It '当前系统字段访问异常时仅返回 false' {
        $profiles = New-AuthProfiles -Matchers @([pscustomobject]@{ match='Service Display'; type='exact' })
        $pending = New-ServicePending
        $pending.matched_pattern = 'Service Display'
        $pending.matched_field = 'service_display_name'
        $script:ServiceObject = [pscustomobject]@{ Name='Svc' }
        $script:ServiceObject | Add-Member -MemberType ScriptProperty -Name DisplayName -Value { throw 'Access denied' }
        Mock Get-Service { $script:ServiceObject } -ParameterFilter { $Name -eq 'Svc' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It 'profile 已移除保存 matcher 时即使另一 matcher 命中也拒绝' {
        $profiles = New-AuthProfiles -Matchers @([pscustomobject]@{ match='Svc'; type='exact' })
        $pending = New-ServicePending
        $pending.matched_pattern = 'RemovedSvc'
        Mock Get-Service { [pscustomobject]@{ Name='Svc'; DisplayName='Other Display' } } -ParameterFilter { $Name -eq 'Svc' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It 'mixed profile 的 contains 命中不能借 exact matcher 获得授权' {
        $profiles = New-AuthProfiles -Matchers @(
            [pscustomobject]@{ match='Svc'; type='exact' },
            [pscustomobject]@{ match='Sv'; type='contains' }
        ) -AllowAuto $true
        $pending = New-ServicePending
        $pending.matched_pattern = 'Sv'
        $pending.matched_type = 'contains'

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It 'contains regex publisher sha256 provenance 和 allow_auto 均不能绕过' -TestCases @(
        @{ type='contains'; pattern='Sv' }
        @{ type='regex'; pattern='^Svc$' }
        @{ type='publisher'; pattern='CN=Vendor' }
        @{ type='sha256'; pattern=('a' * 64) }
    ) {
        param($type, $pattern)
        $profiles = New-AuthProfiles -Matchers @([pscustomobject]@{ match=$pattern; type=$type }) -AllowAuto $true
        $pending = New-ServicePending
        $pending.matched_pattern = $pattern
        $pending.matched_type = $type

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It 'pattern identity 大小写敏感且 type/field 不能交换' -TestCases @(
        @{ label='pattern case'; pattern='svc'; type='exact'; field='service_name' }
        @{ label='type swap'; pattern='Svc'; type='path'; field='service_name' }
        @{ label='field swap'; pattern='Svc'; type='exact'; field='service_display_name' }
    ) {
        param($label, $pattern, $type, $field)
        $profiles = New-AuthProfiles
        $pending = New-ServicePending
        $pending.matched_pattern = $pattern
        $pending.matched_type = $type
        $pending.matched_field = $field
        Mock Get-Service { [pscustomobject]@{ Name='Svc'; DisplayName='Other Display' } } -ParameterFilter { $Name -eq 'Svc' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse -Because $label
    }

    It 'id action status target 的篡改均拒绝' -TestCases @(
        @{ label='id'; property='id'; value='other' }
        @{ label='action'; property='action'; value='remove_autostart' }
        @{ label='status'; property='status'; value='success' }
        @{ label='target'; property='service_name'; value='OtherSvc' }
    ) {
        param($label, $property, $value)
        $profiles = New-AuthProfiles
        $pending = New-ServicePending
        $pending.$property = $value
        Mock Get-Service { [pscustomobject]@{ Name='Svc'; DisplayName='Svc' } } -ParameterFilter { $Name -eq 'Svc' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse -Because $label
    }

    It 'failed 状态仍可按相同当前证据重新授权' {
        $profiles = New-AuthProfiles
        $pending = New-ServicePending
        $pending.status = 'failed'
        Mock Get-Service { [pscustomobject]@{ Name='Svc'; DisplayName='Svc' } } -ParameterFilter { $Name -eq 'Svc' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
    }

    It 'pending 核心字段的一元素数组、数字、null、空白或缺失均拒绝' {
        $cases = @(
            @{ label='id array'; property='id'; value=@('rule'); remove=$false },
            @{ label='action array'; property='action'; value=@('disable_service'); remove=$false },
            @{ label='status array'; property='status'; value=@('pending'); remove=$false },
            @{ label='target array'; property='service_name'; value=@('Svc'); remove=$false },
            @{ label='hit array'; property='hit_type'; value=@('service'); remove=$false },
            @{ label='id number'; property='id'; value=1; remove=$false },
            @{ label='status null'; property='status'; value=$null; remove=$false },
            @{ label='action blank'; property='action'; value=' '; remove=$false },
            @{ label='target missing'; property='service_name'; value=$null; remove=$true },
            @{ label='field missing'; property='matched_field'; value=$null; remove=$true }
        )
        foreach ($case in $cases) {
            $pending = New-ServicePending
            if ($case.remove) { $pending.PSObject.Properties.Remove($case.property) }
            else { $pending.$($case.property) = $case.value }
            Test-PendingActionAuthorized $pending (New-AuthProfiles) | Should -BeFalse -Because $case.label
        }
    }

    It 'profile id safe tested declared action 必须保持严格标量类型和值' {
        $cases = @(
            @{ label='profile id array'; mutate={ param($r) $r.id=@('rule') } },
            @{ label='profile id case'; mutate={ param($r) $r.id='Rule' } },
            @{ label='safe string'; mutate={ param($r) $r.safe='true' } },
            @{ label='safe number'; mutate={ param($r) $r.safe=1 } },
            @{ label='tested string'; mutate={ param($r) $r.evidence.tested='true' } },
            @{ label='tested missing'; mutate={ param($r) $r.evidence.PSObject.Properties.Remove('tested') } },
            @{ label='action array'; mutate={ param($r) $r.actions.service=@('disable_service') } },
            @{ label='action not dangerous'; mutate={ param($r) $r.actions.service='investigate' } }
        )
        foreach ($case in $cases) {
            $profiles = New-AuthProfiles
            & $case.mutate $profiles.profiles[0]
            Test-PendingActionAuthorized (New-ServicePending) $profiles | Should -BeFalse -Because $case.label
        }
    }

    It '缺失、多值或空白的当前服务字段均拒绝' {
        $profiles = New-AuthProfiles
        $pending = New-ServicePending
        $script:ServiceRead = $null
        Mock Get-Service { $script:ServiceRead } -ParameterFilter { $Name -eq 'Svc' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
        $script:ServiceRead = @([pscustomobject]@{Name='Svc';DisplayName='Svc'},[pscustomobject]@{Name='Svc';DisplayName='Svc'})
        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
        $script:ServiceRead = [pscustomobject]@{ Name=' '; DisplayName='Svc' }
        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }
}

Describe '当前系统字段解析与相同 matcher 重放' {
    BeforeEach {
        Mock Get-Service { throw "Unexpected Get-Service read: $Name" }
        Mock Get-ItemProperty { throw "Unexpected Get-ItemProperty read: $Path" }
        Mock Get-ScheduledTask { throw "Unexpected Get-ScheduledTask read: $TaskName $TaskPath" }
        Mock Get-Process { throw "Unexpected Get-Process read: $Id" }
    }

    It 'autostart_name 从当前命名属性读取' {
        $profiles = New-AuthProfiles -HitType autostart -Action remove_autostart -Matchers @([pscustomobject]@{match='Updater';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='autostart'; action='remove_autostart'; status='pending'
            autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='Updater'
            matched_pattern='Updater'; matched_type='exact'; matched_field='autostart_name'
        }
        Mock Get-ItemProperty { [pscustomobject]@{ Updater='C:\Apps\updater.exe' } } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
    }

    It 'autostart_value 从当前命名属性值读取且缺失值拒绝' {
        $profiles = New-AuthProfiles -HitType autostart -Action remove_autostart -Matchers @([pscustomobject]@{match='C:\Apps\updater.exe';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='autostart'; action='remove_autostart'; status='pending'
            autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='Updater'; autostart_value='C:\Apps\updater.exe'
            matched_pattern='C:\Apps\updater.exe'; matched_type='exact'; matched_field='autostart_value'
        }
        Mock Get-ItemProperty { $script:AutostartKey } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }

        $script:AutostartKey = [pscustomobject]@{ Updater='C:\Apps\updater.exe' }
        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
        $script:AutostartKey = [pscustomobject]@{ Other='C:\Apps\updater.exe' }
        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It 'autostart_value 在相同 path 前缀内变化仍拒绝授权' {
        $profiles = New-AuthProfiles -HitType autostart -Action remove_autostart -Matchers @([pscustomobject]@{match='C:\Apps';type='path'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='autostart'; action='remove_autostart'; status='pending'
            autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='Updater'; autostart_value='C:\Apps\old.exe'
            matched_pattern='C:\Apps'; matched_type='path'; matched_field='autostart_value'
        }
        Mock Get-ItemProperty { [pscustomobject]@{ Updater='C:\Apps\changed.exe' } } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It '任意高权限注册表键即使同名 exact matcher 也拒绝且不读取' {
        $profiles = New-AuthProfiles -HitType autostart -Action remove_autostart -Matchers @([pscustomobject]@{match='Updater';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='autostart'; action='remove_autostart'; status='pending'
            autostart_source='HKLM:\SYSTEM\CurrentControlSet\Services'; autostart_name='Updater'
            matched_pattern='Updater'; matched_type='exact'; matched_field='autostart_name'
        }
        Mock Get-ItemProperty { [pscustomobject]@{ Updater='C:\Windows\System32\evil.exe' } } -ParameterFilter { $Path -eq 'HKLM:\SYSTEM\CurrentControlSet\Services' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
        Assert-MockCalled Get-ItemProperty -Times 0 -Exactly -ParameterFilter { $Path -eq 'HKLM:\SYSTEM\CurrentControlSet\Services' }
    }

    It 'StartupFolder 和 Run 键子路径均 fail closed' -TestCases @(
        @{ source='StartupFolder' }
        @{ source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\Child' }
        @{ source='HKCU:\Software\Microsoft\Windows\CurrentVersion\R*' }
    ) {
        param($source)
        $profiles = New-AuthProfiles -HitType autostart -Action remove_autostart -Matchers @([pscustomobject]@{match='Updater';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='autostart'; action='remove_autostart'; status='pending'
            autostart_source=$source; autostart_name='Updater'
            matched_pattern='Updater'; matched_type='exact'; matched_field='autostart_name'
        }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It '标准 Run 键允许 OrdinalIgnoreCase 大小写变化' {
        $profiles = New-AuthProfiles -HitType autostart -Action remove_autostart -Matchers @([pscustomobject]@{match='Updater';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='autostart'; action='remove_autostart'; status='pending'
            autostart_source='hkcu:\software\microsoft\windows\currentversion\run'; autostart_name='Updater'
            matched_pattern='Updater'; matched_type='exact'; matched_field='autostart_name'
        }
        Mock Get-ItemProperty { [pscustomobject]@{ Updater='C:\Apps\updater.exe' } } -ParameterFilter { $Path -eq 'hkcu:\software\microsoft\windows\currentversion\run' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
    }

    It 'task_name 从 pending 完整路径定位当前任务' {
        $profiles = New-AuthProfiles -HitType task -Action disable_task -Matchers @([pscustomobject]@{match='Updater';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='task'; action='disable_task'; status='pending'; task_path='\Vendor\Updater'
            matched_pattern='Updater'; matched_type='exact'; matched_field='task_name'
        }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='Updater'; TaskPath='\Vendor\' } } -ParameterFilter { $TaskName -eq 'Updater' -and $TaskPath -eq '\Vendor\' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
    }

    It 'task_path 重建当前完整路径且路径变化拒绝' {
        $profiles = New-AuthProfiles -HitType task -Action disable_task -Matchers @([pscustomobject]@{match='\Vendor\Updater';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='task'; action='disable_task'; status='pending'; task_path='\Vendor\Updater'
            matched_pattern='\Vendor\Updater'; matched_type='exact'; matched_field='task_path'
        }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='Updater'; TaskPath=$script:CurrentTaskFolder } } -ParameterFilter { $TaskName -eq 'Updater' -and $TaskPath -eq '\Vendor\' }

        $script:CurrentTaskFolder = '\Vendor\'
        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
        $script:CurrentTaskFolder = '\Changed\'
        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It 'process_name 通过当前 PID 读取并保留 exe 标准化' {
        $profiles = New-AuthProfiles -HitType process -Action uninstall -Matchers @([pscustomobject]@{match='agent';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='process'; action='uninstall'; status='pending'; process_id=4242
            process_name='Agent.exe'; process_path='C:\Apps\agent.exe'
            matched_pattern='agent'; matched_type='exact'; matched_field='process_name'
        }
        Mock Get-Process { [pscustomobject]@{ Id=4242; Name='AGENT'; Path='C:\Apps\agent.exe' } } -ParameterFilter { $Id -eq 4242 }

        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
    }

    It 'process_path 通过当前 PID 读取且相同路径 matcher 可授权' {
        $profiles = New-AuthProfiles -HitType process -Action uninstall -Matchers @([pscustomobject]@{match='C:\Apps';type='path'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='process'; action='uninstall'; status='pending'; process_id=4242
            process_name='Agent'; process_path='C:\Apps\agent.exe'
            matched_pattern='C:\Apps'; matched_type='path'; matched_field='process_path'
        }
        Mock Get-Process { [pscustomobject]@{ Id=4242; Name='Agent'; Path='C:\Apps\agent.exe' } } -ParameterFilter { $Id -eq 4242 }

        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
    }

    It '当前进程对象缺少 Id 时拒绝授权' {
        $profiles = New-AuthProfiles -HitType process -Action uninstall -Matchers @([pscustomobject]@{match='agent';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='process'; action='uninstall'; status='pending'; process_id=4242
            process_name='Agent'; process_path='C:\Apps\agent.exe'
            matched_pattern='agent'; matched_type='exact'; matched_field='process_name'
        }
        Mock Get-Process { [pscustomobject]@{ Name='Agent'; Path='C:\Apps\agent.exe' } } -ParameterFilter { $Id -eq 4242 }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It 'PID 复用为同名但不同路径进程时拒绝名称授权' {
        $profiles = New-AuthProfiles -HitType process -Action uninstall -Matchers @([pscustomobject]@{match='agent';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='process'; action='uninstall'; status='pending'; process_id=4242
            process_name='Agent'; process_path='C:\Apps\agent.exe'
            matched_pattern='agent'; matched_type='exact'; matched_field='process_name'
        }
        Mock Get-Process { [pscustomobject]@{ Id=4242; Name='Agent'; Path='C:\Other\agent.exe' } } -ParameterFilter { $Id -eq 4242 }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It '进程 PID 名称 路径 或存活状态变化均拒绝' -TestCases @(
        @{ label='changed pid'; targetPid=4243; storedName='Agent'; storedPath='C:\Apps\agent.exe'; currentName='Agent'; currentPath='C:\Apps\agent.exe'; exists=$true; field='process_name'; type='exact'; pattern='Agent' }
        @{ label='changed name'; targetPid=4242; storedName='Agent'; storedPath='C:\Apps\agent.exe'; currentName='Other'; currentPath='C:\Apps\agent.exe'; exists=$true; field='process_name'; type='exact'; pattern='Agent' }
        @{ label='changed path'; targetPid=4242; storedName='Agent'; storedPath='C:\Apps\agent.exe'; currentName='Agent'; currentPath='C:\Apps\other.exe'; exists=$true; field='process_path'; type='path'; pattern='C:\Apps' }
        @{ label='exited'; targetPid=4242; storedName='Agent'; storedPath='C:\Apps\agent.exe'; currentName='Agent'; currentPath='C:\Apps\agent.exe'; exists=$false; field='process_name'; type='exact'; pattern='Agent' }
    ) {
        param($label,$targetPid,$storedName,$storedPath,$currentName,$currentPath,$exists,$field,$type,$pattern)
        $profiles = New-AuthProfiles -HitType process -Action uninstall -Matchers @([pscustomobject]@{match=$pattern;type=$type})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='process'; action='uninstall'; status='pending'; process_id=$targetPid
            process_name=$storedName; process_path=$storedPath
            matched_pattern=$pattern; matched_type=$type; matched_field=$field
        }
        Mock Get-Process {
            if ($exists) { [pscustomobject]@{ Id=4242; Name=$currentName; Path=$currentPath } }
        } -ParameterFilter { $Id -eq 4242 }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse -Because $label
    }

    It 'process_id 必须是正标量整数且对应字段目标必须是标量字符串' {
        $profiles = New-AuthProfiles -HitType process -Action uninstall -Matchers @([pscustomobject]@{match='Agent';type='exact'})
        $cases = @(
            @{ label='pid array'; pid=@(4242); name='Agent' },
            @{ label='pid string'; pid='4242'; name='Agent' },
            @{ label='pid zero'; pid=0; name='Agent' },
            @{ label='pid negative'; pid=-1; name='Agent' },
            @{ label='name array'; pid=4242; name=@('Agent') },
            @{ label='name blank'; pid=4242; name=' ' }
        )
        foreach ($case in $cases) {
            $pending = [pscustomobject]@{
                id='rule'; hit_type='process'; action='uninstall'; status='pending'; process_id=$case.pid
                process_name=$case.name; process_path='C:\Apps\agent.exe'
                matched_pattern='Agent'; matched_type='exact'; matched_field='process_name'
            }
            Test-PendingActionAuthorized $pending $profiles | Should -BeFalse -Because $case.label
        }
    }

    It 'process Path 访问失败时拒绝而不抛错' {
        $profiles = New-AuthProfiles -HitType process -Action uninstall -Matchers @([pscustomobject]@{match='C:\Apps';type='path'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='process'; action='uninstall'; status='pending'; process_id=4242
            process_name='Agent'; process_path='C:\Apps\agent.exe'
            matched_pattern='C:\Apps'; matched_type='path'; matched_field='process_path'
        }
        $proc = [pscustomobject]@{ Id=4242; Name='Agent' }
        $proc | Add-Member -MemberType ScriptProperty -Name Path -Value { throw 'Access denied' }
        Mock Get-Process { $proc } -ParameterFilter { $Id -eq 4242 }

        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }
}

Describe '执行前最终授权防 TOCTOU' {
    It '初次授权后当前值变化时跳过且不调用备份或删除' {
        $profiles = New-AuthProfiles -HitType autostart -Action remove_autostart -Matchers @([pscustomobject]@{match='Updater';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='autostart'; action='remove_autostart'; status='pending'; safe=$true
            autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='Updater'
            matched_pattern='Updater'; matched_type='exact'; matched_field='autostart_name'
        }
        $script:CurrentAutostart = [pscustomobject]@{ Updater='C:\Apps\old.exe' }
        Mock Get-ItemProperty { $script:CurrentAutostart }
        Mock Backup-AutostartValue { 'should-not-run' }
        Mock Backup-RegistryKey { 'should-not-run' }
        Mock Remove-ItemProperty {}
        Mock Disable-ScheduledTask {}
        Mock Stop-Process {}

        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
        $script:CurrentAutostart = [pscustomobject]@{ Other='C:\Apps\old.exe' }
        if (Test-SelectedPendingActionAuthorized $pending $profiles) {
            Backup-AutostartValue $pending.autostart_source $pending.autostart_name 'backup' 'tag'
            Backup-RegistryKey 'HKLM:\fake' 'backup' 'tag'
            Remove-ItemProperty -Path $pending.autostart_source -Name $pending.autostart_name
            Disable-ScheduledTask -TaskName FakeTask -TaskPath '\'
            Stop-Process -Id 4242 -Force
        }

        $pending.status | Should -Be 'skipped'
        Assert-MockCalled Backup-AutostartValue -Times 0 -Exactly
        Assert-MockCalled Backup-RegistryKey -Times 0 -Exactly
        Assert-MockCalled Remove-ItemProperty -Times 0 -Exactly
        Assert-MockCalled Disable-ScheduledTask -Times 0 -Exactly
        Assert-MockCalled Stop-Process -Times 0 -Exactly
    }

    It '真实 clean 选中循环在任何备份或 mutation 之前调用最终授权 helper' {
        $source = Get-Content (Join-Path $script:Root 'src\Core\ActionEngine.ps1') -Raw
        $loop = $source.IndexOf('foreach ($idx in $indexes)')
        $guard = $source.IndexOf('Test-SelectedPendingActionAuthorized', $loop)
        $mutations = @('New-Item -ItemType Directory', 'Backup-RegistryKey', 'sc.exe config', 'sc.exe stop', 'Backup-AutostartValue', 'Remove-ItemProperty', 'Disable-ScheduledTask', 'Stop-Process') |
            ForEach-Object { $source.IndexOf($_, $loop) }

        $loop | Should -BeGreaterOrEqual 0
        $guard | Should -BeGreaterThan $loop
        foreach ($mutation in $mutations) {
            $mutation | Should -BeGreaterThan $guard
        }
    }
}

Describe 'pending JSON 重复属性预检' {
    It '拒绝 envelope 或 action 对象中的重复属性 <label>' -TestCases @(
        @{ label='envelope exact'; json='{"actions":[],"actions":[]}' }
        @{ label='envelope case'; json='{"actions":[],"Actions":[]}' }
        @{ label='id exact'; json='{"actions":[{"id":"a","id":"b"}]}' }
        @{ label='id case'; json='{"actions":[{"id":"a","ID":"b"}]}' }
        @{ label='action exact'; json='{"actions":[{"action":"a","action":"b"}]}' }
        @{ label='action case'; json='{"actions":[{"action":"a","Action":"b"}]}' }
        @{ label='status exact'; json='{"actions":[{"status":"a","status":"b"}]}' }
        @{ label='status case'; json='{"actions":[{"status":"a","STATUS":"b"}]}' }
        @{ label='pattern exact'; json='{"actions":[{"matched_pattern":"a","matched_pattern":"b"}]}' }
        @{ label='pattern case'; json='{"actions":[{"matched_pattern":"a","MATCHED_PATTERN":"b"}]}' }
        @{ label='type exact'; json='{"actions":[{"matched_type":"a","matched_type":"b"}]}' }
        @{ label='type case'; json='{"actions":[{"matched_type":"a","Matched_Type":"b"}]}' }
        @{ label='field exact'; json='{"actions":[{"matched_field":"a","matched_field":"b"}]}' }
        @{ label='field case'; json='{"actions":[{"matched_field":"a","MATCHED_FIELD":"b"}]}' }
    ) {
        param($label, $json)
        Test-JsonPropertyNamesUnique $json | Should -BeFalse
    }

    It '按解码后的属性名拒绝 Unicode escape 重复键' {
        Test-JsonPropertyNamesUnique '{"actions":[{"id":"a","\u0069d":"b"}]}' | Should -BeFalse
    }

    It '接受合法嵌套 JSON 并由严格入口转换' {
        $json = '{"pending_schema_version":2,"actions":[{"id":"a","status":"pending"}],"observations":[]}'
        Test-JsonPropertyNamesUnique $json | Should -BeTrue
        (ConvertFrom-StrictPendingJson $json).pending_schema_version | Should -Be 2
    }

    It '严格入口在 ConvertFrom-Json 前拒绝重复键' {
        { ConvertFrom-StrictPendingJson '{"actions":[],"Actions":[]}' } | Should -Throw '*重复*'
    }

    It '容器深度按根容器为 1 计数，64 合法而 65 拒绝' {
        $depth64 = (('[' * 64) -join '') + '0' + ((']' * 64) -join '')
        $depth65 = (('[' * 65) -join '') + '0' + ((']' * 65) -join '')

        Test-JsonPropertyNamesUnique $depth64 | Should -BeTrue
        Test-JsonPropertyNamesUnique $depth65 | Should -BeFalse
    }

    It 'pending 文件超过 5 MiB 时在 Get-Content 和解析之前关闭' {
        $path = 'C:\fake\oversized-pending.json'
        Mock Get-Item { [pscustomobject]@{ Length = (5MB + 1); PSIsContainer = $false } }
        Mock Get-Content { throw 'Get-Content must not run' }
        Mock ConvertFrom-StrictPendingJson { throw 'parser must not run' }

        { Read-StrictPendingJsonFile $path } | Should -Throw '*过大*'
        Assert-MockCalled Get-Content -Times 0 -Exactly
        Assert-MockCalled ConvertFrom-StrictPendingJson -Times 0 -Exactly
    }
}
