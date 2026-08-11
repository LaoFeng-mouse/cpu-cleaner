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

    function Is-Admin { return $false }
    function Write-Step { param([string]$Message) }
    if (-not (Get-Command Get-NormalizedFinalPathFromHandle -ErrorAction SilentlyContinue)) {
        function Get-NormalizedFinalPathFromHandle { throw 'handle identity helper not implemented' }
    }
    if (-not (Get-Command Invoke-GetFinalPathNameByHandleNative -ErrorAction SilentlyContinue)) {
        function Invoke-GetFinalPathNameByHandleNative {
            param($SafeFileHandle, $Builder, $Capacity, $Flags)
            throw 'native API wrapper not implemented'
        }
    }
    if (-not (Get-Command Invoke-GetFileInformationByHandleNative -ErrorAction SilentlyContinue)) {
        function Invoke-GetFileInformationByHandleNative {
            param($SafeFileHandle)
            throw 'file information API wrapper not implemented'
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
            autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='Updater'; autostart_value='C:\Apps\updater.exe'
            matched_pattern='Updater'; matched_type='exact'; matched_field='autostart_name'
        }
        Mock Get-ItemProperty { [pscustomobject]@{ Updater='C:\Apps\updater.exe' } } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }

        Test-PendingActionAuthorized $pending $profiles | Should -BeTrue
    }

    It 'autostart_name exact 在保存值缺失或当前值变化时拒绝' {
        $profiles = New-AuthProfiles -HitType autostart -Action remove_autostart -Matchers @([pscustomobject]@{match='Updater';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='autostart'; action='remove_autostart'; status='pending'
            autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='Updater'; autostart_value='C:\Apps\old.exe'
            matched_pattern='Updater'; matched_type='exact'; matched_field='autostart_name'
        }
        Mock Get-ItemProperty { [pscustomobject]@{ Updater=$script:CurrentAutostartValue } } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }

        $script:CurrentAutostartValue = 'C:\Apps\changed.exe'
        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
        $pending.autostart_value = ''
        $script:CurrentAutostartValue = 'C:\Apps\old.exe'
        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
    }

    It 'autostart_name exact 在当前 Value 空白、非字符串或读取异常时拒绝' {
        $profiles = New-AuthProfiles -HitType autostart -Action remove_autostart -Matchers @([pscustomobject]@{match='Updater';type='exact'})
        $pending = [pscustomobject]@{
            id='rule'; hit_type='autostart'; action='remove_autostart'; status='pending'
            autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='Updater'; autostart_value='C:\Apps\old.exe'
            matched_pattern='Updater'; matched_type='exact'; matched_field='autostart_name'
        }
        Mock Get-ItemProperty { $script:CurrentAutostartKey } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }

        foreach ($badValue in @($null, ' ', 123)) {
            $script:CurrentAutostartKey = [pscustomobject]@{ Updater=$badValue }
            Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
        }
        $script:CurrentAutostartKey = [pscustomobject]@{}
        $script:CurrentAutostartKey | Add-Member -MemberType ScriptProperty -Name Updater -Value { throw 'current value unreadable' }
        Test-PendingActionAuthorized $pending $profiles | Should -BeFalse
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
            autostart_source='hkcu:\software\microsoft\windows\currentversion\run'; autostart_name='Updater'; autostart_value='C:\Apps\updater.exe'
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
            autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='Updater'; autostart_value='C:\Apps\old.exe'
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
        $mutations = @('Initialize-ProtectedBackupDirectory', 'Backup-RegistryKey', 'sc.exe config', 'sc.exe stop', 'Invoke-LiteralAutostartRemoval', 'Disable-ScheduledTask', 'Stop-Process') |
            ForEach-Object { $source.IndexOf($_, $loop) }

        $loop | Should -BeGreaterOrEqual 0
        $guard | Should -BeGreaterThan $loop
        foreach ($mutation in $mutations) {
            $mutation | Should -BeGreaterThan $guard
        }
    }

    It 'restore 主入口严格按 resolve join ACL read plan-mutation 顺序且不继承空 manifestFile' {
        $source = Get-Content (Join-Path $script:Root 'src\Core\ActionEngine.ps1') -Raw
        $start = $source.IndexOf('function Invoke-Restore {')
        $end = $source.IndexOf('function Update-Profiles {', $start)
        $body = $source.Substring($start, $end - $start)
        $resolve = $body.IndexOf('Resolve-TrustedRestoreBackupDirectory')
        $join = $body.IndexOf('$manifestFile = Join-Path')
        $packageAcl = $body.IndexOf('Assert-TrustedBackupPackagePath')
        $manifestAcl = $body.IndexOf('Assert-TrustedBackupPathAcl')
        $read = $body.IndexOf('Read-BackupManifestEntries $manifestFile')

        $resolve | Should -BeGreaterOrEqual 0
        $join | Should -BeGreaterThan $resolve
        $packageAcl | Should -BeGreaterThan $join
        $manifestAcl | Should -BeGreaterThan $packageAcl
        $read | Should -BeGreaterThan $manifestAcl

        $driver = Join-Path $TestDrive 'restore-order-driver.ps1'
        $orderFile = Join-Path $TestDrive 'restore-order.txt'
        $projectRootLiteral = $script:Root.Replace("'", "''")
        $orderFileLiteral = $orderFile.Replace("'", "''")
        $driverSource = @"
`$projectRoot = '$projectRootLiteral'
`$orderFile = '$orderFileLiteral'
`$src = Get-Content (Join-Path `$projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
`$idx = `$src.IndexOf("switch (```$Mode)")
`$defs = `$src.Substring(0, `$idx).Replace('`$script:Root = Split-Path -Parent `$MyInvocation.MyCommand.Path', '`$script:Root = `$projectRoot')
Invoke-Expression `$defs
`$BackupDir = 'C:\legacy\20260811_120000'
`$script:BackupRoot = 'C:\legacy'
`$manifestFile = `$null
`$script:Order = @()
function Is-Admin { return `$true }
function Resolve-TrustedRestoreBackupDirectory { param(`$RequestedPath, `$LegacyRoot); `$script:Order += 'resolve'; return 'C:\trusted\20260811_120000' }
function Assert-TrustedBackupPackagePath { param(`$BackupDir); `$script:Order += 'package-acl'; return `$BackupDir }
function Assert-TrustedBackupPathAcl { param(`$Path, `$RequireProtected); if ([System.IO.Path]::GetFileName(`$Path) -cne 'manifest.json' -or `$Path -notmatch 'trusted') { throw ('wrong manifest path: ' + `$Path) }; `$script:Order += 'manifest-acl' }
function Read-BackupManifestEntries { param(`$ManifestFile); if ([string]::IsNullOrWhiteSpace(`$ManifestFile)) { throw 'empty manifestFile' }; `$script:Order += 'read'; return [pscustomobject]@{type='process';name='noop';path=''} }
function Invoke-ValidatedRestoreManifest { `$script:Order += 'plans-then-pre-mutation'; [System.IO.File]::WriteAllText(`$orderFile, ('ORDER=' + (`$script:Order -join ','))); return [pscustomobject]@{success=`$true} }
function Write-Step {}
Invoke-Restore
"@
        [System.IO.File]::WriteAllText($driver, $driverSource, [System.Text.UTF8Encoding]::new($false))

        $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $driver 2>&1

        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        (Get-Content -LiteralPath $orderFile -Raw) | Should -BeExactly 'ORDER=resolve,package-acl,manifest-acl,read,plans-then-pre-mutation'
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

    It 'pending 读取入口不再使用 Get-Item 与 Get-Content 分离检查和读取' {
        $path = Join-Path $TestDrive 'single-stream.json'
        [System.IO.File]::WriteAllText($path, '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        Mock Get-Item { throw 'Get-Item must not run' }
        Mock Get-Content { throw 'Get-Content must not run' }

        (Read-StrictPendingJsonFile $path).pending_schema_version | Should -Be 2
        Assert-MockCalled Get-Item -Times 0 -Exactly
        Assert-MockCalled Get-Content -Times 0 -Exactly
    }

    It '同一 FileStream helper 先检查 Length 再读取且兼容包装及时释放' {
        $source = Get-Content (Join-Path $script:Root 'src\Core\ActionEngine.ps1') -Raw
        $start = $source.IndexOf('function Read-LimitedPendingJsonStream')
        $start | Should -BeGreaterOrEqual 0
        if ($start -lt 0) { return }
        $end = $source.IndexOf('function Read-LimitedPendingJsonFile', $start)
        $body = $source.Substring($start, $end - $start)

        $body | Should -Not -Match '\bGet-Item\b|\bGet-Content\b'
        $body.IndexOf('.Length') | Should -BeGreaterOrEqual 0
        $body.IndexOf('StreamReader') | Should -BeGreaterThan $body.IndexOf('.Length')
        $body.IndexOf('ReadToEnd') | Should -BeGreaterThan $body.IndexOf('StreamReader')

        $wrapperEnd = $source.IndexOf('function Read-StrictPendingJsonFile', $end)
        $wrapper = $source.Substring($end, $wrapperEnd - $end)
        $wrapper | Should -Match 'Open-LockedPendingFile'
        $wrapper | Should -Match 'Read-LimitedPendingJsonStream'
        $wrapper | Should -Match 'finally'
        $wrapper | Should -Match '\.Dispose\(\)'
    }

    It '静态超限文件在读取全部内容前拒绝' {
        $path = Join-Path $TestDrive 'oversized-pending.json'
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $stream.SetLength(5MB + 1) } finally { $stream.Dispose() }

        { Read-LimitedPendingJsonFile $path } | Should -Throw '*过大*'
    }

    It '精确 5 MiB 的合法 JSON 位于允许边界' {
        $path = Join-Path $TestDrive 'max-pending.json'
        $prefix = '{"pending_schema_version":2,"actions":[]}'
        $prefixBytes = [System.Text.Encoding]::UTF8.GetBytes($prefix)
        $json = $prefix + [string]::new([char]' ', (5MB - $prefixBytes.Length))
        [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::UTF8.GetBytes($json))

        $text = Read-LimitedPendingJsonFile $path
        [System.Text.Encoding]::UTF8.GetByteCount($text) | Should -Be 5MB
        $text.StartsWith($prefix) | Should -BeTrue
    }

    It '合法 UTF-8 pending 在有无 BOM 时均可读取' -TestCases @(
        @{ label='without BOM'; bom=$false }
        @{ label='with BOM'; bom=$true }
    ) {
        param($label, $bom)
        $path = Join-Path $TestDrive ("utf8-$label.json")
        $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes('{"pending_schema_version":2,"name":"测试","actions":[]}')
        $bytes = if ($bom) { [byte[]]([System.Text.Encoding]::UTF8.GetPreamble() + $jsonBytes) } else { $jsonBytes }
        [System.IO.File]::WriteAllBytes($path, $bytes)

        $pending = Read-StrictPendingJsonFile $path
        $pending.pending_schema_version | Should -Be 2
        $pending.name | Should -Be '测试'
    }

    It 'pending 句柄打开后拒绝写入和替换并在 finally 后释放' {
        $path = Join-Path $TestDrive 'locked-pending.json'
        $replacement = Join-Path $TestDrive 'replacement.json'
        $backup = Join-Path $TestDrive 'replace-backup.json'
        [System.IO.File]::WriteAllText($path, '{"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($replacement, '{"actions":[1]}', [System.Text.UTF8Encoding]::new($false))
        $locked = $null
        try {
            $locked = Open-PendingJsonReadStream $path
            { [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite).Dispose() } | Should -Throw
            { [System.IO.File]::Replace($replacement, $path, $backup) } | Should -Throw
        } finally {
            if ($null -ne $locked) { $locked.Dispose() }
        }

        $probe = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $probe.Dispose()
    }

    It '读写锁拒绝并发写删替换且只向已打开对象回写无 BOM UTF-8' {
        $path = Join-Path $TestDrive 'locked-read-write.json'
        $replacement = Join-Path $TestDrive 'locked-replacement.json'
        $backup = Join-Path $TestDrive 'locked-backup.json'
        [System.IO.File]::WriteAllText($path, '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($replacement, '{"replacement":true}', [System.Text.UTF8Encoding]::new($false))
        $stream = $null
        try {
            $stream = Open-LockedPendingFile $path
            $stream.CanRead | Should -BeTrue
            $stream.CanWrite | Should -BeTrue
            { [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite).Dispose() } | Should -Throw
            { [System.IO.File]::Delete($path) } | Should -Throw
            { [System.IO.File]::Replace($replacement, $path, $backup) } | Should -Throw

            $payload = [pscustomobject]@{ pending_schema_version=2; generated='locked'; actions=@(); observations=@(); suspicious=@() }
            Write-PendingToLockedStream -Stream $stream -Pending $payload
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }

        $bytes = [System.IO.File]::ReadAllBytes($path)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        ([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json).generated | Should -Be 'locked'
        ([System.IO.File]::ReadAllText($replacement) | ConvertFrom-Json).replacement | Should -BeTrue
    }

    It '普通文件的已打开句柄最终路径与输入身份一致' {
        $path = Join-Path $TestDrive 'identity-normal.json'
        [System.IO.File]::WriteAllText($path, '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
        try {
            Test-OpenedPendingFileIdentity -Stream $stream -Path $path | Should -BeTrue
        } finally {
            $stream.Dispose()
        }
    }

    It '普通临时文件的已打开句柄 link count 严格为 1' {
        $path = Join-Path $TestDrive 'single-link.json'
        [System.IO.File]::WriteAllText($path, '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
        try {
            Test-OpenedPendingFileHasSingleLink -Stream $stream | Should -BeTrue
        } finally {
            $stream.Dispose()
        }
    }

    It '存在第二个硬链接时 Open-LockedPendingFile 在读取前关闭并拒绝' {
        $target = Join-Path $TestDrive 'hardlink-target.json'
        $link = Join-Path $TestDrive 'hardlink-alias.json'
        [System.IO.File]::WriteAllText($target, '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        $null = New-Item -ItemType HardLink -Path $link -Target $target
        Mock Read-LimitedPendingJsonStream { throw 'must not parse hardlink' }
        $script:UnexpectedHardlinkStream = $null
        try {
            { $script:UnexpectedHardlinkStream = Open-LockedPendingFile $target } | Should -Throw '*硬链接*'
            Assert-MockCalled Read-LimitedPendingJsonStream -Times 0 -Exactly
            $probe = [System.IO.File]::Open($target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $probe.Dispose()
        } finally {
            if ($null -ne $script:UnexpectedHardlinkStream) { $script:UnexpectedHardlinkStream.Dispose() }
            Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
    }

    It 'GetFileInformationByHandle API 失败或 link count 非 1 时 fail closed' {
        $path = Join-Path $TestDrive 'link-api-failure.json'
        [System.IO.File]::WriteAllText($path, '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
        try {
            Mock Invoke-GetFileInformationByHandleNative { return [pscustomobject]@{ success=$false; nNumberOfLinks=[uint32]0 } }
            Test-OpenedPendingFileHasSingleLink -Stream $stream | Should -BeFalse

            Mock Invoke-GetFileInformationByHandleNative { return [pscustomobject]@{ success=$true; nNumberOfLinks=[uint32]0 } }
            Test-OpenedPendingFileHasSingleLink -Stream $stream | Should -BeFalse

            Mock Invoke-GetFileInformationByHandleNative { return [pscustomobject]@{ success=$true; nNumberOfLinks=[uint32]2 } }
            Test-OpenedPendingFileHasSingleLink -Stream $stream | Should -BeFalse
        } finally {
            $stream.Dispose()
        }
    }

    It '已打开句柄返回不同最终目标时失败关闭且路径换回不改变结论' {
        $path = Join-Path $TestDrive 'identity-input.json'
        [System.IO.File]::WriteAllText($path, '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
        Mock Invoke-GetFinalPathNameByHandleNative {
            $null = $Builder.Append('\\?\C:\Different\target.json')
            return [uint32]$Builder.Length
        }
        try {
            Test-OpenedPendingFileIdentity -Stream $stream -Path $path | Should -BeFalse
            Test-OpenedPendingFileIdentity -Stream $stream -Path $path | Should -BeFalse
        } finally {
            $stream.Dispose()
        }
        Assert-MockCalled Invoke-GetFinalPathNameByHandleNative -Times 2 -Exactly
    }

    It '最终路径 Windows API 失败时句柄身份校验 fail closed' {
        $path = Join-Path $TestDrive 'identity-api-failure.json'
        [System.IO.File]::WriteAllText($path, '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
        Mock Invoke-GetFinalPathNameByHandleNative { return [uint32]0 }
        try {
            Test-OpenedPendingFileIdentity -Stream $stream -Path $path | Should -BeFalse
        } finally {
            $stream.Dispose()
        }
    }

    It '句柄身份不一致时 Invoke-Clean 不进入 JSON 解析或写回并释放句柄' {
        $path = Join-Path $TestDrive 'identity-block-clean.json'
        [System.IO.File]::WriteAllText($path, '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        Mock Is-Admin { $true }
        Mock Invoke-GetFinalPathNameByHandleNative {
            $null = $Builder.Append('\\?\C:\Different\target.json')
            return [uint32]$Builder.Length
        }
        Mock Read-LimitedPendingJsonStream { throw 'must not parse' }
        Mock Write-PendingToLockedStream { throw 'must not write' }
        try {
            { Invoke-Clean } | Should -Throw '*身份*'
            Assert-MockCalled Read-LimitedPendingJsonStream -Times 0 -Exactly
            Assert-MockCalled Write-PendingToLockedStream -Times 0 -Exactly
            $probe = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $probe.Dispose()
        } finally {
            $script:PendingFile = $oldPendingFile
        }
    }

    It '即使纵深 reparse 预检被绕过，junction 最终句柄目标仍拒绝' {
        $targetDirectory = Join-Path $TestDrive 'identity-target'
        $junctionPath = Join-Path $TestDrive 'identity-junction'
        $null = New-Item -ItemType Directory -Path $targetDirectory
        $null = New-Item -ItemType Junction -Path $junctionPath -Target $targetDirectory
        [System.IO.File]::WriteAllText((Join-Path $targetDirectory 'pending.json'), '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        $pendingPath = Join-Path $junctionPath 'pending.json'
        Mock Assert-PendingPathIsNotReparsePoint {}
        $script:UnexpectedIdentityStream = $null
        try {
            { $script:UnexpectedIdentityStream = Open-LockedPendingFile $pendingPath } | Should -Throw '*身份*'
        } finally {
            if ($null -ne $script:UnexpectedIdentityStream) { $script:UnexpectedIdentityStream.Dispose() }
        }
    }

    It '拒绝经过 reparse-point 目录组件的 pending 输入路径' {
        $targetDirectory = Join-Path $TestDrive 'pending-target'
        $junctionPath = Join-Path $TestDrive 'pending-junction'
        $null = New-Item -ItemType Directory -Path $targetDirectory
        $null = New-Item -ItemType Junction -Path $junctionPath -Target $targetDirectory
        $pendingPath = Join-Path $junctionPath 'pending.json'
        [System.IO.File]::WriteAllText((Join-Path $targetDirectory 'pending.json'), '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))

        $script:UnexpectedReparseStream = $null
        try {
            { $script:UnexpectedReparseStream = Open-LockedPendingFile $pendingPath } | Should -Throw '*reparse point*'
        } finally {
            if ($null -ne $script:UnexpectedReparseStream) { $script:UnexpectedReparseStream.Dispose() }
        }
    }

    It 'Invoke-Clean 严格 JSON 异常后释放 pending 独占写句柄' {
        $path = Join-Path $TestDrive 'invalid-locked-pending.json'
        [System.IO.File]::WriteAllText($path, '{"pending_schema_version":2,"actions":[],"Actions":[]}', [System.Text.UTF8Encoding]::new($false))
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        Mock Is-Admin { $true }
        try {
            { Invoke-Clean } | Should -Throw '*重复*'
            $probe = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $probe.Dispose()
        } finally {
            $script:PendingFile = $oldPendingFile
        }
    }
}

Describe 'clean pending v2 状态持久化' {
    It 'CLI 同句柄写回无损保留 <Levels> 层 envelope 扩展字段' -TestCases @(
        @{ Levels = 12 }
        @{ Levels = 55 }
    ) {
        param($Levels)
        $deep = [pscustomobject]@{ terminal = "depth-$Levels" }
        for ($i = 0; $i -lt $Levels; $i++) {
            $deep = [pscustomobject]@{ next = $deep }
        }
        $payload = [pscustomobject]@{
            pending_schema_version = 2
            generated = 'deep'
            actions = @()
            observations = @()
            suspicious = @()
            extension = $deep
        }
        $path = Join-Path $TestDrive "deep-cli-$Levels.json"
        [System.IO.File]::WriteAllText($path, '{"pending_schema_version":2,"actions":[]}', [System.Text.UTF8Encoding]::new($false))
        $stream = $null
        try {
            $stream = Open-LockedPendingFile $path
            Write-PendingToLockedStream -Stream $stream -Pending $payload
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }

        $roundTrip = Read-StrictPendingJsonFile $path
        $cursor = $roundTrip.extension
        for ($i = 0; $i -lt $Levels; $i++) { $cursor = $cursor.next }
        $cursor | Should -BeOfType ([pscustomobject])
        $cursor.terminal | Should -Be "depth-$Levels"
    }

    It '初始授权全部拒绝也写回 skipped 并保留完整安全 envelope' {
        $path = Join-Path $TestDrive 'rejected-v2.json'
        $pending = [pscustomobject]@{
            pending_schema_version = 2
            generated = 'scan-time'
            actions = @([pscustomobject]@{ id='reject'; status='pending'; action='disable_service'; hit_type='service' })
            observations = @([pscustomobject]@{ id='observe'; obs_reason='keep' })
            suspicious = @([pscustomobject]@{ PID=42; Name='suspect' })
            safety_nonce = 'preserve-me'
        }
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $pending -Depth 6), [System.Text.UTF8Encoding]::new($false))
        $oldPendingFile = $script:PendingFile
        $script:PendingFile = $path
        Mock Is-Admin { $true }
        Mock Load-Profiles { [pscustomobject]@{ profiles=@() } }
        Mock Test-PendingActionAuthorized { $false }
        Mock Write-Step {}
        $YesToAll = $true
        try {
            Invoke-Clean
            $after = Read-StrictPendingJsonFile $path
        } finally {
            $script:PendingFile = $oldPendingFile
        }

        $after.pending_schema_version | Should -Be 2
        $after.generated | Should -Be 'scan-time'
        $after.actions[0].status | Should -Be 'skipped'
        $after.observations[0].obs_reason | Should -Be 'keep'
        $after.suspicious[0].PID | Should -Be 42
        $after.safety_nonce | Should -Be 'preserve-me'
    }

    It '集中 payload builder 保留 envelope 扩展字段但强制 v2 和当前数组' {
        $source = [pscustomobject]@{ pending_schema_version=2; generated='g'; actions=@('old'); observations=@('obs'); suspicious=@('sus'); safety_nonce='n' }
        $built = Build-PendingV2Payload -Source $source -Actions @('new')

        $built.pending_schema_version | Should -Be 2
        $built.generated | Should -Be 'g'
        @($built.actions) | Should -Be @('new')
        @($built.observations) | Should -Be @('obs')
        @($built.suspicious) | Should -Be @('sus')
        $built.safety_nonce | Should -Be 'n'
    }
}
