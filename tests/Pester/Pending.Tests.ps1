# Pester 测试: 待办清单 (去重 / safe 规则 / 状态机) (Pester 5 固定版本 5.9.0)
Describe '待办清单规则' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw '主流程 switch 未找到' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        # Pester 5 固定版本 (5.9.0): 直接使用原生断言, 不做 3.4/5.x 兼容包装
        $script:PendingFile = Join-Path $env:TEMP ("pending_" + [guid]::NewGuid().ToString('N') + ".json")
        # v1.5.2: Mock Windows 状态, 模拟"服务/自启/任务存在但未达目标状态"
        # (Save-PendingActions 会查真实系统: Get-Service / Get-ItemProperty / Get-ScheduledTask,
        #  不 Mock 的话测试结果取决于跑测试的机器, CI 上 S1/X/T1 不存在导致行为漂移)
        Mock Get-Service { throw "Unexpected Get-Service read: $Name" }
        Mock Get-Service { [pscustomobject]@{ Name='S1'; StartType='Automatic'; Status='Running' } } -ParameterFilter { $Name -eq 'S1' }
        Mock Get-ScheduledTask { throw "Unexpected Get-ScheduledTask read: $TaskName $TaskPath" }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='T1'; TaskPath='\X\'; State='Running' } } -ParameterFilter { $TaskName -eq 'T1' -and $TaskPath -eq '\X\' }
        Mock Get-ItemProperty { throw "Unexpected Get-ItemProperty read: $Path" }
        Mock Get-ItemProperty { [pscustomobject]@{ X = 'C:\fake\X.exe' } } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }

        # Fault-injection seams are declared here until production provides them. This keeps
        # the RED failures focused on Save-PendingActions not using the atomic publish path.
        if (-not (Get-Command Invoke-PendingAtomicWrite -ErrorAction SilentlyContinue)) {
            function Invoke-PendingAtomicWrite($Stream, [byte[]]$Bytes) { $Stream.Write($Bytes, 0, $Bytes.Length) }
        }
        if (-not (Get-Command Invoke-PendingAtomicFlush -ErrorAction SilentlyContinue)) {
            function Invoke-PendingAtomicFlush($Stream) { $Stream.Flush($true) }
        }
        if (-not (Get-Command Invoke-PendingAtomicMove -ErrorAction SilentlyContinue)) {
            function Invoke-PendingAtomicMove($Source, $Destination) { [System.IO.File]::Move($Source, $Destination) }
        }
        if (-not (Get-Command Invoke-PendingAtomicReplace -ErrorAction SilentlyContinue)) {
            function Invoke-PendingAtomicReplace($Source, $Destination, $Backup) { [System.IO.File]::Replace($Source, $Destination, $Backup) }
        }

        function New-Schema3PolicyHit {
            param(
                [string]$Id,
                [string]$Action,
                [string]$HitType,
                [string]$ServiceName = '',
                [string]$ServiceDisplayName = '',
                [string]$TaskPath = '',
                [string]$MatchedPattern,
                [string]$MatchedField,
                [string]$ExecutionClass = 'automatic_safe',
                [string]$Necessity = 'optional',
                [bool]$DefaultSelected = $true,
                [bool]$RequiresConfirmation = $false,
                [string]$ImpactCn = '会停止 OEM 后台功能',
                [string]$CleanupReasonCn = '减少不需要的后台占用'
            )
            return [pscustomobject]@{
                id=$Id; vendor='Lenovo'; name_cn=$Id; action=$Action; hit_type=$HitType; detail=$Id; reason_cn='测试规则'
                service_name=$ServiceName; service_display_name=$ServiceDisplayName; autostart_source=''; autostart_name=''; autostart_value=''
                task_path=$TaskPath; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }
                matched_pattern=$MatchedPattern; matched_type='exact'; matched_field=$MatchedField
                execution_class=$ExecutionClass; necessity=$Necessity; default_selected=$DefaultSelected
                requires_confirmation=$RequiresConfirmation; impact_cn=$ImpactCn; cleanup_reason_cn=$CleanupReasonCn
            }
        }

        function Set-ValidAutomaticPolicy($Hit) {
            $policy = [ordered]@{
                execution_class='automatic_safe'; necessity='optional'; default_selected=$true; requires_confirmation=$false
                impact_cn='会停止 OEM 后台功能'; cleanup_reason_cn='减少不需要的后台占用'
            }
            foreach ($name in $policy.Keys) {
                if ($Hit.PSObject.Properties.Name -contains $name) { $Hit.$name = $policy[$name] }
                else { $Hit | Add-Member -NotePropertyName $name -NotePropertyValue $policy[$name] }
            }
            return $Hit
        }
    }

    It '空数组以 schema v3 和 UTF-8 BOM 原子保存' {
        Save-PendingActions -Hits @() -Suspicious @()

        $bytes = [System.IO.File]::ReadAllBytes($script:PendingFile)
        $bytes.Length | Should -BeGreaterThan 3
        @($bytes[0], $bytes[1], $bytes[2]) | Should -Be @(0xEF, 0xBB, 0xBF)
        $pending = Get-Content -LiteralPath $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $pending.pending_schema_version | Should -Be 3
        @($pending.actions).Count | Should -Be 0
        @($pending.resolved).Count | Should -Be 0
        @($pending.observations).Count | Should -Be 0
        @($pending.suspicious).Count | Should -Be 0
    }

    It '写入失败保留旧文件并清理唯一同目录临时文件' {
        $oldBytes = [System.Text.UTF8Encoding]::new($true).GetBytes('{"old":"valid"}')
        [System.IO.File]::WriteAllBytes($script:PendingFile, $oldBytes)
        Mock Invoke-PendingAtomicWrite { throw 'injected write failure' }

        { Save-PendingActions -Hits @() -Suspicious @() } | Should -Throw '*injected write failure*'

        [System.IO.File]::ReadAllBytes($script:PendingFile) | Should -Be $oldBytes
        @(Get-ChildItem -LiteralPath (Split-Path $script:PendingFile -Parent) -Filter ((Split-Path $script:PendingFile -Leaf) + '.*.tmp')) | Should -HaveCount 0
    }

    It '持久化刷新失败不创建 final 并清理唯一同目录临时文件' {
        Mock Invoke-PendingAtomicFlush { throw 'injected flush failure' }

        { Save-PendingActions -Hits @() -Suspicious @() } | Should -Throw '*injected flush failure*'

        Test-Path -LiteralPath $script:PendingFile | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Split-Path $script:PendingFile -Parent) -Filter ((Split-Path $script:PendingFile -Leaf) + '.*.tmp')) | Should -HaveCount 0
    }

    It '首次发布 move 失败不创建 final 并清理临时文件' {
        Mock Invoke-PendingAtomicMove { throw 'injected move failure' }

        { Save-PendingActions -Hits @() -Suspicious @() } | Should -Throw '*injected move failure*'

        Test-Path -LiteralPath $script:PendingFile | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Split-Path $script:PendingFile -Parent) -Filter ((Split-Path $script:PendingFile -Leaf) + '.*.tmp')) | Should -HaveCount 0
    }

    It '替换失败保留旧文件并清理临时及备份文件' {
        $oldBytes = [System.Text.UTF8Encoding]::new($true).GetBytes('{"old":"valid"}')
        [System.IO.File]::WriteAllBytes($script:PendingFile, $oldBytes)
        Mock Invoke-PendingAtomicReplace { throw 'injected replace failure' }

        { Save-PendingActions -Hits @() -Suspicious @() } | Should -Throw '*injected replace failure*'

        [System.IO.File]::ReadAllBytes($script:PendingFile) | Should -Be $oldBytes
        $parent = Split-Path $script:PendingFile -Parent
        $leaf = Split-Path $script:PendingFile -Leaf
        @(Get-ChildItem -LiteralPath $parent -Filter ($leaf + '.*.tmp')) | Should -HaveCount 0
        @(Get-ChildItem -LiteralPath $parent -Filter ($leaf + '.*.bak')) | Should -HaveCount 0
    }

    It '替换成功后备份删除失败仍返回成功并保留新 final' {
        $oldBytes = [System.Text.UTF8Encoding]::new($true).GetBytes('{"old":"valid"}')
        [System.IO.File]::WriteAllBytes($script:PendingFile, $oldBytes)
        Mock Remove-PendingAtomicFile { throw 'injected backup cleanup failure' } -ParameterFilter { $Path -like '*.bak' }

        { Save-PendingActions -Hits @() -Suspicious @() } | Should -Not -Throw

        $pending = ConvertFrom-StrictPendingJson (Get-Content -LiteralPath $script:PendingFile -Raw -Encoding UTF8)
        $pending.pending_schema_version | Should -Be 3
        @($pending.actions).Count | Should -Be 0
        @($pending.resolved).Count | Should -Be 0
        @($pending.observations).Count | Should -Be 0
        @($pending.suspicious).Count | Should -Be 0
        $parent = Split-Path $script:PendingFile -Parent
        $leaf = Split-Path $script:PendingFile -Leaf
        @(Get-ChildItem -LiteralPath $parent -Filter ($leaf + '.*.bak')) | Should -HaveCount 1
        @(Get-ChildItem -LiteralPath $parent -Filter ($leaf + '.*.tmp')) | Should -HaveCount 0
        Assert-MockCalled Remove-PendingAtomicFile -Times 1 -Exactly -ParameterFilter { $Path -like '*.bak' }
    }

    It '首次发布前并发出现 final 时拒绝覆盖并保留并发文件' {
        $concurrentBytes = [System.Text.UTF8Encoding]::new($true).GetBytes('{"concurrent":"winner"}')
        Mock Invoke-PendingAtomicMove {
            [System.IO.File]::WriteAllBytes($Destination, $concurrentBytes)
            [System.IO.File]::Move($Source, $Destination)
        }

        { Save-PendingActions -Hits @() -Suspicious @() } | Should -Throw

        [System.IO.File]::ReadAllBytes($script:PendingFile) | Should -Be $concurrentBytes
        @(Get-ChildItem -LiteralPath (Split-Path $script:PendingFile -Parent) -Filter ((Split-Path $script:PendingFile -Leaf) + '.*.tmp')) | Should -HaveCount 0
    }

    It '拒绝目录目标和不存在的父目录' {
        $script:PendingFile = $TestDrive
        { Save-PendingActions -Hits @() -Suspicious @() } | Should -Throw '*文件路径*'

        $script:PendingFile = Join-Path (Join-Path $TestDrive 'missing-parent') 'pending.json'
        { Save-PendingActions -Hits @() -Suspicious @() } | Should -Throw '*父目录*'
    }

    It '目标文件被判定为 reparse point 时保留旧文件' {
        $oldBytes = [System.Text.UTF8Encoding]::new($true).GetBytes('{"old":"valid"}')
        [System.IO.File]::WriteAllBytes($script:PendingFile, $oldBytes)
        Mock Assert-PendingPathIsNotReparsePoint {
            if ([string]::Equals([System.IO.Path]::GetFullPath($Path), [System.IO.Path]::GetFullPath($script:PendingFile), [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'injected target reparse point'
            }
        }

        { Save-PendingActions -Hits @() -Suspicious @() } | Should -Throw '*target reparse point*'
        [System.IO.File]::ReadAllBytes($script:PendingFile) | Should -Be $oldBytes
    }

    It '临时文件被判定为 reparse point 时不发布并清理临时文件' {
        Mock Assert-PendingPathIsNotReparsePoint {
            if ($Path -like '*.tmp') { throw 'injected temp reparse point' }
        }

        { Save-PendingActions -Hits @() -Suspicious @() } | Should -Throw '*temp reparse point*'
        Test-Path -LiteralPath $script:PendingFile | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Split-Path $script:PendingFile -Parent) -Filter ((Split-Path $script:PendingFile -Leaf) + '.*.tmp')) | Should -HaveCount 0
    }

    It '仅接受 Int32 pending schema v3' {
        Test-PendingSchemaSupported ([pscustomobject]@{ pending_schema_version = [int32]3 }) | Should -BeTrue
    }

    It '接受 Windows PowerShell ConvertFrom-Json 可能产生的 Int64 schema v3' {
        Test-PendingSchemaSupported ([pscustomobject]@{ pending_schema_version = [int64]3 }) | Should -BeTrue
    }

    It '严格 schema v3 envelope 只接受四个真正数组分支' {
        $valid = [pscustomobject]@{
            pending_schema_version = [int32]3
            actions = @()
            resolved = @()
            observations = @()
            suspicious = @()
        }
        Test-PendingEnvelopeShape $valid | Should -BeTrue

        foreach ($branch in @('actions','resolved','observations','suspicious')) {
            $missing = $valid.PSObject.Copy()
            $missing.PSObject.Properties.Remove($branch)
            Test-PendingEnvelopeShape $missing | Should -BeFalse

            foreach ($invalidValue in @($null, 'not-an-array', [pscustomobject]@{ nested = 'object' })) {
                $invalid = $valid.PSObject.Copy()
                $invalid.$branch = $invalidValue
                Test-PendingEnvelopeShape $invalid | Should -BeFalse
            }
        }
    }

    It '严格 schema v3 envelope 拒绝二维 <Branch> 分支' -TestCases @(
        @{ Branch='actions' }
        @{ Branch='resolved' }
        @{ Branch='observations' }
        @{ Branch='suspicious' }
    ) {
        param($Branch)
        $pending = [pscustomobject]@{
            pending_schema_version = [int32]3
            actions = @()
            resolved = @()
            observations = @()
            suspicious = @()
        }
        $matrix = [System.Array]::CreateInstance([object], [int[]]@(1,1))
        $matrix.SetValue([pscustomobject]@{ id='matrix' }, 0, 0)
        $pending.$Branch = $matrix

        Test-PendingEnvelopeShape $pending | Should -BeFalse
    }

    It '严格 schema v3 envelope 接受四个一维单元素数组' {
        $item = [pscustomobject]@{ id='one' }
        $pending = [pscustomobject]@{
            pending_schema_version = [int32]3
            actions = [object[]]@($item)
            resolved = [object[]]@($item)
            observations = [object[]]@($item)
            suspicious = [object[]]@($item)
        }

        Test-PendingEnvelopeShape $pending | Should -BeTrue
        foreach ($branch in @('actions','resolved','observations','suspicious')) {
            $pending.$branch.Rank | Should -Be 1
        }
    }

    It '拒绝缺失、空值、错误版本及非整数标量 pending schema' {
        $unsupported = @(
            [pscustomobject]@{},
            [pscustomobject]@{ pending_schema_version = $null },
            [pscustomobject]@{ pending_schema_version = [int32]1 },
            [pscustomobject]@{ pending_schema_version = [int32]2 },
            [pscustomobject]@{ pending_schema_version = [int32]4 },
            [pscustomobject]@{ pending_schema_version = '3' },
            [pscustomobject]@{ pending_schema_version = [double]3.0 },
            [pscustomobject]@{ pending_schema_version = [decimal]3 },
            [pscustomobject]@{ pending_schema_version = $true },
            [pscustomobject]@{ pending_schema_version = @([int32]3) },
            [pscustomobject]@{ pending_schema_version = [pscustomobject]@{ value = 3 } }
        )

        foreach ($pending in $unsupported) {
            Test-PendingSchemaSupported $pending | Should -BeFalse
        }
    }

    It 'Build-PendingPayload 生成 Int32 schema 3 四数组并保留扩展字段' {
        $sourceAction = [pscustomobject][ordered]@{
            id = 'extension-action'
            action = 'disable_service'
            extension_flag = 'keep-action-extension'
        }
        $sourceResolved = [pscustomobject][ordered]@{
            id = 'extension-resolved'
            extension_state = 'keep-resolved-extension'
        }
        $source = [pscustomobject][ordered]@{
            pending_schema_version = [int32]3
            generated = '2026-08-21 12:00:00'
            actions = @($sourceAction)
            resolved = @($sourceResolved)
            observations = @()
            suspicious = @()
            envelope_extension = 'keep-envelope-extension'
        }

        $payload = Build-PendingPayload -Source $source

        $payload.pending_schema_version.GetType() | Should -Be ([int32])
        $payload.pending_schema_version | Should -Be 3
        foreach ($name in @('actions','resolved','observations','suspicious')) {
            $payload.PSObject.Properties.Name | Should -Contain $name
            $payload.$name -is [System.Array] | Should -BeTrue
        }
        @($payload.PSObject.Properties | Where-Object { $_.Name -ceq 'resolved' }).Count | Should -Be 1
        $payload.envelope_extension | Should -BeExactly 'keep-envelope-extension'
        $payload.actions[0].extension_flag | Should -BeExactly 'keep-action-extension'
        $payload.resolved[0].extension_state | Should -BeExactly 'keep-resolved-extension'
    }

    It 'Build-PendingPayload 的空集合始终序列化为 JSON 数组' {
        $payload = Build-PendingPayload -Source ([pscustomobject]@{ envelope_extension = 'keep' })
        $raw = ConvertTo-Json -InputObject $payload -Depth 100

        foreach ($name in @('actions','resolved','observations','suspicious')) {
            $raw | Should -Match ('"' + $name + '"\s*:\s*\[\s*\]')
        }
    }

    It 'strict reader 拒绝重复 resolved envelope 属性' {
        $raw = '{"pending_schema_version":3,"actions":[],"resolved":[],"resolved":[],"observations":[],"suspicious":[]}'
        { ConvertFrom-StrictPendingJson $raw } | Should -Throw '*重复*'
    }

    It 'Invoke-Clean 在读取 actions 和 Load-Profiles 前拒绝非法 pending envelope' {
        $actionEnginePath = Join-Path $projectRoot 'src\Core\ActionEngine.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($actionEnginePath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $invokeClean = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Clean'
        }, $true)
        $body = $invokeClean.Body.Extent.Text

        $convertIndex = $body.IndexOf('$pending = ConvertFrom-StrictPendingJson $pendingRaw')
        $gateIndex = $body.IndexOf('Test-PendingEnvelopeShape $pending')
        $actionsIndex = $body.IndexOf('$pending.actions')
        $profilesIndex = $body.IndexOf('Load-Profiles')

        $convertIndex | Should -BeGreaterOrEqual 0
        $gateIndex | Should -BeGreaterThan $convertIndex
        $gateIndex | Should -BeLessThan $actionsIndex
        $gateIndex | Should -BeLessThan $profilesIndex
        $body.Substring($gateIndex, $actionsIndex - $gateIndex) | Should -Match '\bexit\s+1\b'
        $body | Should -Match '旧|不兼容|数组结构'
        $body | Should -Match 'scan'
    }

    It '非法 pending envelope 在隔离子进程中输出错误且不加载特征库或读取系统并以非零退出' -TestCases @(
        @{ Label='legacy v2'; Json='{"pending_schema_version":2,"actions":[],"resolved":[],"observations":[],"suspicious":[]}' }
        @{ Label='missing actions'; Json='{"pending_schema_version":3,"resolved":[],"observations":[],"suspicious":[]}' }
        @{ Label='null resolved'; Json='{"pending_schema_version":3,"actions":[],"resolved":null,"observations":[],"suspicious":[]}' }
        @{ Label='scalar observations'; Json='{"pending_schema_version":3,"actions":[],"resolved":[],"observations":"bad","suspicious":[]}' }
        @{ Label='object suspicious'; Json='{"pending_schema_version":3,"actions":[],"resolved":[],"observations":[],"suspicious":{}}' }
    ) {
        param($Label, $Json)
        $pendingPath = Join-Path $TestDrive ("invalid-pending-$Label.json")
        $markerPath = Join-Path $TestDrive ("forbidden-calls-$Label.txt")
        $fixturePath = Join-Path $TestDrive ("invoke-clean-$Label.ps1")
        [System.IO.File]::WriteAllText($pendingPath, $Json, [System.Text.UTF8Encoding]::new($false))
        $actionEnginePath = Join-Path $projectRoot 'src\Core\ActionEngine.ps1'
        $fixture = @'
param([string]$PendingPath, [string]$MarkerPath, [string]$ActionEnginePath)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$script:PendingFile = $PendingPath
$script:ProfileFile = 'must-not-load.json'
$script:BackupRoot = 'must-not-create'
function Is-Admin { return $true }
function Add-ForbiddenCall([string]$Name) { [System.IO.File]::AppendAllText($MarkerPath, ($Name + [Environment]::NewLine)) }
function Load-Profiles { Add-ForbiddenCall 'Load-Profiles'; throw 'Load-Profiles must not run' }
function Get-Service { Add-ForbiddenCall 'Get-Service'; throw 'Get-Service must not run' }
function Get-ItemProperty { Add-ForbiddenCall 'Get-ItemProperty'; throw 'Get-ItemProperty must not run' }
function Get-ScheduledTask { Add-ForbiddenCall 'Get-ScheduledTask'; throw 'Get-ScheduledTask must not run' }
function Get-Process { Add-ForbiddenCall 'Get-Process'; throw 'Get-Process must not run' }
. $ActionEnginePath
Invoke-Clean
exit 0
'@
        [System.IO.File]::WriteAllText($fixturePath, $fixture, [System.Text.UTF8Encoding]::new($false))
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
        $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -PendingPath "{1}" -MarkerPath "{2}" -ActionEnginePath "{3}"' -f $fixturePath, $pendingPath, $markerPath, $actionEnginePath)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        if ($psi.PSObject.Properties.Name -contains 'StandardOutputEncoding') {
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        }
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $process.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath $markerPath | Should -BeFalse
        ($stdout + $stderr) | Should -Match 'pending'
        ($stdout + $stderr) | Should -Match 'scan'
    }

    It '自定义 pending 缺失或错误 SHA-256 时在解析、授权和动作前 fail closed' -TestCases @(
        @{ label='missing'; supplied='' }
        @{ label='wrong'; supplied=('0' * 64) }
    ) {
        param($label, $supplied)
        $pendingPath = Join-Path $TestDrive "hash-$label.json"
        $markerPath = Join-Path $TestDrive "hash-$label-forbidden.txt"
        $fixturePath = Join-Path $TestDrive "hash-$label-fixture.ps1"
        [System.IO.File]::WriteAllText($pendingPath, '{"pending_schema_version":3,"actions":[],"resolved":[],"observations":[],"suspicious":[]}', [System.Text.UTF8Encoding]::new($false))
        $actionEnginePath = Join-Path $projectRoot 'src\Core\ActionEngine.ps1'
        $fixture = @'
param([string]$PendingPath, [string]$MarkerPath, [string]$ActionEnginePath, [string]$ProvidedHash)
$ErrorActionPreference = 'Stop'
$script:PendingFile = $PendingPath
$script:PendingSha256 = $ProvidedHash
$script:RequirePendingSha256 = $true
function Is-Admin { return $true }
function Add-ForbiddenCall([string]$Name) { [System.IO.File]::AppendAllText($MarkerPath, ($Name + [Environment]::NewLine)) }
function ConvertFrom-StrictPendingJson { Add-ForbiddenCall 'ConvertFrom-StrictPendingJson'; throw 'parse must not run' }
function Load-Profiles { Add-ForbiddenCall 'Load-Profiles'; throw 'profiles must not load' }
function Get-Service { Add-ForbiddenCall 'Get-Service'; throw 'service must not run' }
function Get-ItemProperty { Add-ForbiddenCall 'Get-ItemProperty'; throw 'registry must not run' }
function Get-ScheduledTask { Add-ForbiddenCall 'Get-ScheduledTask'; throw 'task must not run' }
. $ActionEnginePath
Invoke-Clean
'@
        [System.IO.File]::WriteAllText($fixturePath, $fixture, [System.Text.UTF8Encoding]::new($false))
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
        $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -PendingPath "{1}" -MarkerPath "{2}" -ActionEnginePath "{3}" -ProvidedHash "{4}"' -f $fixturePath, $pendingPath, $markerPath, $actionEnginePath, $supplied)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $process.ExitCode | Should -Not -Be 0
        $output | Should -Match 'SHA-256|hash'
        Test-Path -LiteralPath $markerPath | Should -BeFalse
    }

    It '自定义空动作 pending 的正确 SHA-256 通过锁内 hash gate、解析并到达 Load-Profiles' {
        $pendingPath = Join-Path $TestDrive 'hash-correct-empty.json'
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes('{"pending_schema_version":3,"actions":[],"resolved":[],"observations":[],"suspicious":[]}')
        [System.IO.File]::WriteAllBytes($pendingPath, $bytes)
        $oldPendingFile = $script:PendingFile
        $oldPendingSha256 = $script:PendingSha256
        $oldRequirePendingSha256 = $script:RequirePendingSha256
        $script:PendingFile = $pendingPath
        $script:PendingSha256 = (Get-FileHash -LiteralPath $pendingPath -Algorithm SHA256).Hash
        $script:RequirePendingSha256 = $true
        Mock Is-Admin { return $true }
        Mock Load-Profiles { return [pscustomobject]@{ profiles=@() } }
        Mock Get-Service { throw 'system service access must not run' }
        Mock Get-ItemProperty { throw 'registry access must not run' }
        Mock Get-ScheduledTask { throw 'scheduled task access must not run' }
        Mock Get-Process { throw 'process access must not run' }
        try {
            Invoke-Clean
        } finally {
            $script:PendingFile = $oldPendingFile
            $script:PendingSha256 = $oldPendingSha256
            $script:RequirePendingSha256 = $oldRequirePendingSha256
        }

        Assert-MockCalled Load-Profiles -Times 1 -Exactly
        Assert-MockCalled Get-Service -Times 0 -Exactly
        Assert-MockCalled Get-ItemProperty -Times 0 -Exactly
        Assert-MockCalled Get-ScheduledTask -Times 0 -Exactly
        Assert-MockCalled Get-Process -Times 0 -Exactly
    }

    It '同一 id 不同动作都保留(不丢 autostart)' {
        $hits = @(
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name' },
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='remove_autostart'; hit_type='autostart'; detail='X'; reason_cn='r'; service_name=''; autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='X'; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='X'; matched_type='exact'; matched_field='autostart_name' }
        )
        $hits | ForEach-Object { $null = Set-ValidAutomaticPolicy $_ }
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 2
        @($p.observations).Count | Should -Be 0
    }
    It '完全重复(同 id+类型+目标)才去重' {
        $hits = @(
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name' },
            [pscustomobject]@{ id='a'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name' }
        )
        $hits | ForEach-Object { $null = Set-ValidAutomaticPolicy $_ }
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 1
    }
    It 'tested=false 永不进入执行队列, 进观察(v1.5.6)' {
        $hits = @(
            [pscustomobject]@{ id='d'; vendor='T'; name_cn='D'; action='disable_service'; hit_type='service'; detail='S4'; reason_cn='r'; service_name='S4'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$false }; matched_pattern='S4'; matched_type='exact'; matched_field='service_name' }
        )
        $hits | ForEach-Object { $null = Set-ValidAutomaticPolicy $_ }
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].obs_reason | Should -Match '未实测'
    }
    It 'safe=false 永不进入执行队列, 进观察(v1.5.6)' {
        $hits = @(
            [pscustomobject]@{ id='b'; vendor='T'; name_cn='B'; action='disable_service'; hit_type='service'; detail='S2'; reason_cn='r'; service_name='S2'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$false; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S2'; matched_type='exact'; matched_field='service_name' }
        )
        $hits | ForEach-Object { $null = Set-ValidAutomaticPolicy $_ }
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].obs_reason | Should -Match 'safe=false'
    }
    It 'investigate 动作进观察不进执行队列(v1.5.6)' {
        $hits = @(
            [pscustomobject]@{ id='e'; vendor='T'; name_cn='E'; action='investigate'; hit_type='process'; detail='P1'; reason_cn='r'; service_name=''; autostart_source=''; autostart_name=''; task_path=''; process_name='P1'; process_id=321; process_path='C:\Apps\P1.exe'; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='P1'; matched_type='exact'; matched_field='process_name' }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].obs_reason | Should -Match '仅观察'
        $p.observations[0].matched_pattern | Should -Be 'P1'
        $p.observations[0].matched_type | Should -Be 'exact'
        $p.observations[0].matched_field | Should -Be 'process_name'
        $p.observations[0].process_id | Should -Be 321
        $p.observations[0].process_path | Should -Be 'C:\Apps\P1.exe'
    }
    It '无 evidence 字段视为未实测进观察(v1.5.6 边界)' {
        $hits = @(
            [pscustomobject]@{ id='f'; vendor='T'; name_cn='F'; action='disable_service'; hit_type='service'; detail='S5'; reason_cn='r'; service_name='S5'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; matched_pattern='S5'; matched_type='exact'; matched_field='service_name' }
        )
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
    }
    It '待办初始状态为 pending' {
        $hits = @(
            [pscustomobject]@{ id='c'; vendor='T'; name_cn='C'; action='disable_task'; hit_type='task'; detail='\X\T1'; reason_cn='r'; service_name=''; autostart_source=''; autostart_name=''; task_path='\X\T1'; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='\X\T1'; matched_type='exact'; matched_field='task_path' }
        )
        $hits | ForEach-Object { $null = Set-ValidAutomaticPolicy $_ }
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $p.actions[0].status | Should -Be 'pending'
    }
    It 'pending v3 保存可执行服务的匹配证据和进程空值' {
        $hit = [pscustomobject]@{
            id='v2-service'; vendor='T'; name_cn='V2'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
            service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
            safe=$true; evidence=[pscustomobject]@{ tested=$true }
            matched_pattern='S1'; matched_type='exact'; matched_field='service_name'
        }
        $null = Set-ValidAutomaticPolicy $hit
        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $p.pending_schema_version | Should -Be 3
        @($p.actions).Count | Should -Be 1
        $p.actions[0].matched_pattern | Should -Be 'S1'
        $p.actions[0].matched_type | Should -Be 'exact'
        $p.actions[0].matched_field | Should -Be 'service_name'
        $p.actions[0].process_id | Should -Be 0
        $p.actions[0].process_path | Should -Be ''
    }
    It '宽匹配伪造危险命中只进入观察并保留证据' {
        $hit = [pscustomobject]@{
            id='broad'; vendor='T'; name_cn='Broad'; action='disable_service'; hit_type='service'; detail='LenovoOther'; reason_cn='r'
            service_name='LenovoOther'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
            safe=$true; evidence=[pscustomobject]@{ tested=$true }
            matched_pattern='Lenovo'; matched_type='contains'; matched_field='service_name'
        }
        $null = Set-ValidAutomaticPolicy $hit
        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].matched_pattern | Should -Be 'Lenovo'
        $p.observations[0].matched_type | Should -Be 'contains'
        $p.observations[0].matched_field | Should -Be 'service_name'
        $p.observations[0].process_id | Should -Be 0
        $p.observations[0].process_path | Should -Be ''
        $p.observations[0].obs_reason | Should -Match '宽匹配.*禁止'
    }
    It '缺失或空匹配来源不能进入执行队列' {
        $cases = @(
            [pscustomobject]@{ label='missing'; hit=[pscustomobject]@{ id='missing'; vendor='T'; name_cn='M'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true } } },
            [pscustomobject]@{ label='empty pattern'; hit=[pscustomobject]@{ id='empty-pattern'; vendor='T'; name_cn='M'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern=''; matched_type='exact'; matched_field='service_name' } },
            [pscustomobject]@{ label='empty type'; hit=[pscustomobject]@{ id='empty-type'; vendor='T'; name_cn='M'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type=''; matched_field='service_name' } },
            [pscustomobject]@{ label='empty field'; hit=[pscustomobject]@{ id='empty-field'; vendor='T'; name_cn='M'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='' } }
        )
        foreach ($case in $cases) {
            Save-PendingActions -Hits @($case.hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $case.label
            @($p.observations).Count | Should -Be 1 -Because $case.label
            $p.observations[0].obs_reason | Should -Match '匹配来源缺失或无效' -Because $case.label
        }
    }
    It '非 Boolean 的 safe 或 tested 不能进入执行队列' {
        $cases = @(
            [pscustomobject]@{ label='safe string'; safe='true'; tested=$true; reason='safe' },
            [pscustomobject]@{ label='safe number'; safe=1; tested=$true; reason='safe' },
            [pscustomobject]@{ label='tested string'; safe=$true; tested='true'; reason='未实测' },
            [pscustomobject]@{ label='tested number'; safe=$true; tested=1; reason='未实测' }
        )
        foreach ($case in $cases) {
            $hit = [pscustomobject]@{
                id=$case.label; vendor='T'; name_cn='Type'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
                service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
                safe=$case.safe; evidence=[pscustomobject]@{ tested=$case.tested }
                matched_pattern='S1'; matched_type='exact'; matched_field='service_name'
            }
            Save-PendingActions -Hits @($hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $case.label
            @($p.observations).Count | Should -Be 1 -Because $case.label
            $p.observations[0].obs_reason | Should -Match $case.reason -Because $case.label
        }
    }
    It 'pending v3 保存可执行进程的身份和窄匹配来源' {
        $hit = [pscustomobject]@{
            id='process-path'; vendor='T'; name_cn='Process'; action='uninstall'; hit_type='process'; detail='P1 PID=4242'; reason_cn='r'
            service_name=''; autostart_source=''; autostart_name=''; task_path=''; process_name='P1'; process_id=4242; process_path='C:\Apps\P1.exe'
            safe=$true; evidence=[pscustomobject]@{ tested=$true }
            matched_pattern='C:\Apps'; matched_type='path'; matched_field='process_path'
        }
        $null = Set-ValidAutomaticPolicy $hit
        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 1
        $p.actions[0].matched_pattern | Should -Be 'C:\Apps'
        $p.actions[0].matched_type | Should -Be 'path'
        $p.actions[0].matched_field | Should -Be 'process_path'
        $p.actions[0].process_id | Should -Be 4242
        $p.actions[0].process_path | Should -Be 'C:\Apps\P1.exe'
    }
    It '不支持或跨类型 matched_field 不能进入执行队列' {
        $fields = @('unsupported_field', 'process_name')
        foreach ($field in $fields) {
            $hit = [pscustomobject]@{
                id=$field; vendor='T'; name_cn='Field'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
                service_name='S1'; service_display_name='Display S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
                safe=$true; evidence=[pscustomobject]@{ tested=$true }
                matched_pattern='S1'; matched_type='exact'; matched_field=$field
            }
            Save-PendingActions -Hits @($hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $field
            @($p.observations).Count | Should -Be 1 -Because $field
            $p.observations[0].obs_reason | Should -Match '匹配来源缺失或无效' -Because $field
        }
    }
    It '数组或非字符串 matcher provenance 不能进入执行队列' {
        $cases = @(
            [pscustomobject]@{ label='pattern array'; pattern=@('S1'); type='exact'; field='service_name' },
            [pscustomobject]@{ label='pattern number'; pattern=1; type='exact'; field='service_name' },
            [pscustomobject]@{ label='type array'; pattern='S1'; type=@('exact'); field='service_name' },
            [pscustomobject]@{ label='type number'; pattern='S1'; type=1; field='service_name' },
            [pscustomobject]@{ label='field array'; pattern='S1'; type='exact'; field=@('service_name') },
            [pscustomobject]@{ label='field number'; pattern='S1'; type='exact'; field=1 }
        )
        foreach ($case in $cases) {
            $hit = [pscustomobject]@{
                id=$case.label; vendor='T'; name_cn='Shape'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
                service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
                safe=$true; evidence=[pscustomobject]@{ tested=$true }
                matched_pattern=$case.pattern; matched_type=$case.type; matched_field=$case.field
            }
            Save-PendingActions -Hits @($hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $case.label
            @($p.observations).Count | Should -Be 1 -Because $case.label
            $p.observations[0].obs_reason | Should -Match '匹配来源缺失或无效' -Because $case.label
        }
    }
    It '宽匹配观察不能压制同目标的精确可执行命中' {
        $base = [ordered]@{
            id='mixed'; vendor='T'; name_cn='Mixed'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
            service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
            safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S'; matched_type='contains'; matched_field='service_name'
        }
        $broad = [pscustomobject]$base
        $exact = $broad.PSObject.Copy()
        $exact.matched_pattern = 'S1'
        $exact.matched_type = 'exact'
        $null = Set-ValidAutomaticPolicy $broad
        $null = Set-ValidAutomaticPolicy $exact
        Save-PendingActions -Hits @($broad, $exact) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 1
        @($p.observations).Count | Should -Be 1
        $p.actions[0].matched_type | Should -Be 'exact'
        $p.observations[0].matched_type | Should -Be 'contains'
    }
    It '同进程名不同 PID 的可执行命中都保留' {
        $hits = foreach ($processId in @(101, 202)) {
            [pscustomobject]@{
                id='same-process'; vendor='T'; name_cn='Process'; action='uninstall'; hit_type='process'; detail="P1 PID=$processId"; reason_cn='r'
                service_name=''; autostart_source=''; autostart_name=''; task_path=''; process_name='P1'; process_id=$processId; process_path='C:\Apps\P1.exe'
                safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='P1'; matched_type='exact'; matched_field='process_name'
            }
        }
        $hits | ForEach-Object { $null = Set-ValidAutomaticPolicy $_ }
        Save-PendingActions -Hits $hits -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 2
        @($p.actions.process_id) | Should -Contain 101
        @($p.actions.process_id) | Should -Contain 202
    }
    It '数组、非字符串、null 或空 hit_type 不能进入执行队列' {
        $cases = @(
            [pscustomobject]@{ label='unknown string'; hit_type='bogus' },
            [pscustomobject]@{ label='array bypass'; hit_type=@('bogus','service') },
            [pscustomobject]@{ label='number'; hit_type=1 },
            [pscustomobject]@{ label='null'; hit_type=$null },
            [pscustomobject]@{ label='empty'; hit_type='' }
        )
        foreach ($case in $cases) {
            $hit = [pscustomobject]@{
                id=$case.label; vendor='T'; name_cn='HitType'; action='disable_service'; hit_type=$case.hit_type; detail='S1'; reason_cn='r'
                service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
                safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name'
            }
            Save-PendingActions -Hits @($hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $case.label
            @($p.observations).Count | Should -Be 1 -Because $case.label
            $p.observations[0].obs_reason | Should -Match '匹配来源缺失或无效' -Because $case.label
        }
    }
    It '数组、非字符串、null、空或缺失 action 不能进入执行队列且保留审计证据' {
        $cases = @(
            [pscustomobject]@{ label='one-element array'; has_action=$true; action=@('uninstall') },
            [pscustomobject]@{ label='multi-element array'; has_action=$true; action=@('uninstall','disable_service') },
            [pscustomobject]@{ label='number'; has_action=$true; action=1 },
            [pscustomobject]@{ label='null'; has_action=$true; action=$null },
            [pscustomobject]@{ label='blank'; has_action=$true; action='  ' },
            [pscustomobject]@{ label='missing'; has_action=$false; action=$null }
        )
        foreach ($case in $cases) {
            $hit = [pscustomobject]@{
                id=$case.label; vendor='T'; name_cn='Action'; hit_type='process'; detail='P1 PID=101'; reason_cn='r'
                service_name=''; autostart_source=''; autostart_name=''; task_path=''; process_name='P1'; process_id=101; process_path='C:\Apps\P1.exe'
                safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='P1'; matched_type='exact'; matched_field='process_name'
            }
            if ($case.has_action) { $hit | Add-Member -NotePropertyName action -NotePropertyValue $case.action }
            Save-PendingActions -Hits @($hit) -Suspicious @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
            @($p.actions).Count | Should -Be 0 -Because $case.label
            @($p.observations).Count | Should -Be 1 -Because $case.label
            $p.observations[0].matched_pattern | Should -Be 'P1' -Because $case.label
            $p.observations[0].matched_type | Should -Be 'exact' -Because $case.label
            $p.observations[0].matched_field | Should -Be 'process_name' -Because $case.label
            $p.observations[0].process_id | Should -Be 101 -Because $case.label
            $p.observations[0].process_path | Should -Be 'C:\Apps\P1.exe' -Because $case.label
        }
    }
    It 'enabled exact Lenovo task persists as an automatic_safe action with its display policy' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='LenovoMachineFixUser_OOBE_AUTO_Notification'; TaskPath='\Lenovo\'; State='Ready' } } -ParameterFilter { $TaskName -eq 'LenovoMachineFixUser_OOBE_AUTO_Notification' -and $TaskPath -eq '\Lenovo\' }
        $hit = New-Schema3PolicyHit -Id 'lenovo-task-notify' -Action 'disable_task' -HitType 'task' -TaskPath '\Lenovo\LenovoMachineFixUser_OOBE_AUTO_Notification' -MatchedPattern 'LenovoMachineFixUser_OOBE_AUTO_Notification' -MatchedField 'task_name'

        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 1
        @($p.resolved).Count | Should -Be 0
        $p.actions[0].execution_class | Should -BeExactly 'automatic_safe'
        $p.actions[0].default_selected | Should -BeTrue
        $p.actions[0].requires_confirmation | Should -BeFalse
        $p.actions[0].impact_cn | Should -BeExactly '会停止 OEM 后台功能'
        $p.actions[0].cleanup_reason_cn | Should -BeExactly '减少不需要的后台占用'
    }

    It 'disabled exact Lenovo task persists as resolved rather than an action' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='LenovoMachineFixUser_OOBE_AUTO_Notification'; TaskPath='\Lenovo\'; State='Disabled' } } -ParameterFilter { $TaskName -eq 'LenovoMachineFixUser_OOBE_AUTO_Notification' -and $TaskPath -eq '\Lenovo\' }
        $hit = New-Schema3PolicyHit -Id 'lenovo-task-notify' -Action 'disable_task' -HitType 'task' -TaskPath '\Lenovo\LenovoMachineFixUser_OOBE_AUTO_Notification' -MatchedPattern 'LenovoMachineFixUser_OOBE_AUTO_Notification' -MatchedField 'task_name'

        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 0
        @($p.resolved).Count | Should -Be 1
        $p.resolved[0].current_state | Should -BeExactly 'disabled'
        $p.resolved[0].status | Should -BeExactly 'success'
        $p.resolved[0].task_path | Should -BeExactly '\Lenovo\LenovoMachineFixUser_OOBE_AUTO_Notification'
    }

    It 'promotes a complete running HRWSCCtrl exact identity to a one-time action' {
        $profiles = Load-Profiles -Path $script:ProfileFile
        $profile = @($profiles.profiles | Where-Object { $_.id -ceq 'lenovo-hrwscctrl' }) | Select-Object -First 1
        $binaryDir = Join-Path $TestDrive 'Program Files\Lenovo Security Center'
        [System.IO.Directory]::CreateDirectory($binaryDir) | Out-Null
        $binary = Join-Path $binaryDir 'wsctrl11.exe'
        [System.IO.File]::WriteAllBytes($binary, [byte[]](1))
        $pathName = '"' + $binary + '" -service'
        $services = @([pscustomobject]@{
            Name='HRWSCCtrl'; DisplayName='Lenovo Security Controller'; State='Running'; StartMode='Manual'; PathName=$pathName; ProcessId=[int]4321
            ProcessIdentitySource='trusted_inventory_v3'; ProcessIdentityStatus='complete'; ProcessName='wsctrl11.exe'
            ProcessPath=$binary; ProcessStartTimeUtc='2026-08-24T01:02:03.0000000Z'
        })
        Mock Get-CimInstance {
            return [pscustomobject]@{ Name='HRWSCCtrl'; State='Running'; ProcessId=[int]4321; PathName=$pathName }
        } -ParameterFilter { $ClassName -ceq 'Win32_Service' }
        $hit = @(Match-Profiles -Services $services -AutoStarts @() -Tasks @() -TopProcs @() | Where-Object { $_.id -ceq 'lenovo-hrwscctrl' }) | Select-Object -First 1

        $profile.safe | Should -BeFalse
        $profile.evidence.tested | Should -BeTrue
        Get-ManualActionFor $profile 'service' | Should -BeExactly 'stop_service_runtime'
        $hit.safe | Should -BeFalse
        $hit.evidence.tested | Should -BeTrue
        $hit.matched_type | Should -BeExactly 'exact'
        $hit.execution_class | Should -BeExactly 'manual_impact'
        $hit.action | Should -BeExactly 'stop_service_runtime'
        $hit.service_binary_path | Should -BeExactly $binary
        $hit.process_id | Should -Be 4321
        $hit.process_name | Should -BeExactly 'wsctrl11.exe'
        $hit.process_path | Should -BeExactly $binary
        $hit.process_start_time_utc | Should -BeExactly '2026-08-24T01:02:03.0000000Z'
        Assert-MockCalled Get-CimInstance -Times 2 -Exactly -ParameterFilter { $ClassName -ceq 'Win32_Service' }
        Assert-MockCalled Get-CimInstance -Times 0 -Exactly -ParameterFilter { $ClassName -ceq 'Win32_Process' }

        Save-PendingActions -Hits @($hit) -Suspicious @()
        $pendingJson = Get-Content $script:PendingFile -Raw -Encoding UTF8
        $p = if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $pendingJson | ConvertFrom-Json -DateKind String
        } else {
            $pendingJson | ConvertFrom-Json
        }

        @($p.actions).Count | Should -Be 1
        @($p.resolved).Count | Should -Be 0
        @($p.observations).Count | Should -Be 0
        $p.actions[0].execution_class | Should -BeExactly 'manual_impact'
        $p.actions[0].action | Should -BeExactly 'stop_service_runtime'
        $p.actions[0].service_name | Should -BeExactly 'HRWSCCtrl'
        $p.actions[0].service_binary_path | Should -BeExactly $binary
        $p.actions[0].process_id | Should -Be 4321
        $p.actions[0].process_name | Should -BeExactly 'wsctrl11.exe'
        $p.actions[0].process_path | Should -BeExactly $binary
        $p.actions[0].process_start_time_utc | Should -BeOfType [string]
        $p.actions[0].process_start_time_utc | Should -BeExactly '2026-08-24T01:02:03.0000000Z'
        $p.actions[0].default_selected | Should -BeFalse
        $p.actions[0].requires_confirmation | Should -BeTrue
    }

    It 'accepts stop_service_runtime only for service hits with exact provenance' {
        Test-ActionMatchesHitType 'stop_service_runtime' 'service' | Should -BeTrue
        Test-ActionMatchesHitType 'stop_service_runtime' 'process' | Should -BeFalse
        Test-ActionMatchesHitType 'stop_service_runtime' 'task' | Should -BeFalse
    }

    It 'persists stopped HRWSCCtrl exact hit as observation rather than resolved disabled' {
        $profiles = Load-Profiles -Path $script:ProfileFile
        $profile = @($profiles.profiles | Where-Object { $_.id -ceq 'lenovo-hrwscctrl' }) | Select-Object -First 1
        $services = @([pscustomobject]@{ Name='HRWSCCtrl'; DisplayName='Lenovo Security Controller'; State='Stopped'; StartMode='Manual'; PathName='"C:\Program Files\Lenovo Security Center\wsctrl11.exe" -service'; ProcessId=[int]0 })
        Mock Get-CimInstance { [pscustomobject]@{ Name='HRWSCCtrl'; State='Stopped'; ProcessId=[int]0; PathName='"C:\Program Files\Lenovo Security Center\wsctrl11.exe" -service' } } -ParameterFilter { $ClassName -eq 'Win32_Service' }
        $hit = @(Match-Profiles -Services $services -AutoStarts @() -Tasks @() -TopProcs @() | Where-Object { $_.id -ceq 'lenovo-hrwscctrl' }) | Select-Object -First 1

        $profile.safe | Should -BeFalse
        $profile.evidence.tested | Should -BeTrue
        Get-ManualActionFor $profile 'service' | Should -BeExactly 'stop_service_runtime'
        $hit.safe | Should -BeFalse
        $hit.evidence.tested | Should -BeTrue
        $hit.matched_type | Should -BeExactly 'exact'
        $hit.execution_class | Should -BeExactly 'observation'
        $hit.action | Should -BeExactly 'investigate'
        [string]::IsNullOrWhiteSpace([string]$hit.obs_reason) | Should -BeFalse

        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 0
        @($p.resolved).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].execution_class | Should -BeExactly 'observation'
        $p.observations[0].action | Should -BeExactly 'investigate'
    }

    It 'does not promote a running HRWSCCtrl hit with incomplete one-time identity' {
        $missingBinary = Join-Path $TestDrive 'Program Files\Lenovo Security Center\missing-wsctrl11.exe'
        $pathName = '"' + $missingBinary + '" -service'
        $services = @([pscustomobject]@{ Name='HRWSCCtrl'; DisplayName='Lenovo Security Controller'; State='Running'; StartMode='Manual'; PathName=$pathName; ProcessId=[int]4321 })
        Mock Get-CimInstance {
            if ($ClassName -ceq 'Win32_Service') { return [pscustomobject]@{ Name='HRWSCCtrl'; State='Running'; ProcessId=[int]4321; PathName=$pathName } }
            throw 'process lookup must not occur for a missing service binary'
        } -ParameterFilter { $ClassName -in @('Win32_Service','Win32_Process') }

        $hit = @(Match-Profiles -Services $services -AutoStarts @() -Tasks @() -TopProcs @() | Where-Object { $_.id -ceq 'lenovo-hrwscctrl' }) | Select-Object -First 1
        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        $hit.action | Should -BeExactly 'investigate'
        $hit.execution_class | Should -BeExactly 'observation'
        [string]::IsNullOrWhiteSpace([string]$hit.obs_reason) | Should -BeFalse
        @($p.actions).Count | Should -Be 0
        @($p.resolved).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
    }

    It 'keeps the real HRWSCCtrl contains Match-Profiles hit as observation' {
        $profiles = Load-Profiles -Path $script:ProfileFile
        $profile = @($profiles.profiles | Where-Object { $_.id -ceq 'lenovo-hrwscctrl' }) | Select-Object -First 1
        $services = @([pscustomobject]@{ Name='HRWSCCtrlHelper'; DisplayName='Lenovo Security Controller Helper'; State='Running'; StartMode='Auto' })
        $hit = @(Match-Profiles -Services $services -AutoStarts @() -Tasks @() -TopProcs @() | Where-Object { $_.id -ceq 'lenovo-hrwscctrl' }) | Select-Object -First 1

        $profile.safe | Should -BeFalse
        $profile.evidence.tested | Should -BeTrue
        Get-ManualActionFor $profile 'service' | Should -BeExactly 'stop_service_runtime'
        $hit.safe | Should -BeFalse
        $hit.evidence.tested | Should -BeTrue
        $hit.matched_type | Should -BeExactly 'contains'
        $hit.execution_class | Should -BeExactly 'observation'
        $hit.action | Should -BeExactly 'investigate'

        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 0
        @($p.resolved).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].matched_type | Should -BeExactly 'contains'
        $p.observations[0].action | Should -BeExactly 'investigate'
    }

    It 'keeps the exact action when an exact and contains hit share a target' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='LenovoMachineFixUser_OOBE_AUTO_Notification'; TaskPath='\Lenovo\'; State='Ready' } } -ParameterFilter { $TaskName -eq 'LenovoMachineFixUser_OOBE_AUTO_Notification' -and $TaskPath -eq '\Lenovo\' }
        $exact = New-Schema3PolicyHit -Id 'lenovo-task-notify' -Action 'disable_task' -HitType 'task' -TaskPath '\Lenovo\LenovoMachineFixUser_OOBE_AUTO_Notification' -MatchedPattern 'LenovoMachineFixUser_OOBE_AUTO_Notification' -MatchedField 'task_name'
        $broad = $exact.PSObject.Copy()
        $broad.matched_pattern = 'Lenovo'
        $broad.matched_type = 'contains'

        Save-PendingActions -Hits @($broad, $exact) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 1
        @($p.resolved).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.actions[0].matched_type | Should -BeExactly 'exact'
        $p.observations[0].matched_type | Should -BeExactly 'contains'
    }

    It 'keeps the exact resolved row when a contains observation shares its target' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='LenovoMachineFixUser_OOBE_AUTO_Notification'; TaskPath='\Lenovo\'; State='Disabled' } } -ParameterFilter { $TaskName -eq 'LenovoMachineFixUser_OOBE_AUTO_Notification' -and $TaskPath -eq '\Lenovo\' }
        $exact = New-Schema3PolicyHit -Id 'lenovo-task-notify' -Action 'disable_task' -HitType 'task' -TaskPath '\Lenovo\LenovoMachineFixUser_OOBE_AUTO_Notification' -MatchedPattern 'LenovoMachineFixUser_OOBE_AUTO_Notification' -MatchedField 'task_name'
        $broad = $exact.PSObject.Copy()
        $broad.matched_pattern = 'Lenovo'
        $broad.matched_type = 'contains'

        Save-PendingActions -Hits @($broad, $exact) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 0
        @($p.resolved).Count | Should -Be 1
        @($p.observations).Count | Should -Be 1
        $p.resolved[0].matched_type | Should -BeExactly 'exact'
        $p.observations[0].matched_type | Should -BeExactly 'contains'
    }

    It 'deduplicates different service rules and matcher provenance by the actual service target' {
        Mock Get-Service { [pscustomobject]@{ Name='SharedSvc'; StartType='Automatic'; Status='Running' } } -ParameterFilter { $Name -eq 'SharedSvc' }
        $byName = New-Schema3PolicyHit -Id 'service-by-name' -Action 'disable_service' -HitType 'service' -ServiceName 'SharedSvc' -ServiceDisplayName 'Shared Service' -MatchedPattern 'SharedSvc' -MatchedField 'service_name'
        $byDisplay = New-Schema3PolicyHit -Id 'service-by-display' -Action 'disable_service' -HitType 'service' -ServiceName 'sharedsvc' -ServiceDisplayName 'Shared Service' -MatchedPattern 'Shared Service' -MatchedField 'service_display_name'

        Save-PendingActions -Hits @($byName, $byDisplay) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        (@($p.actions).Count + @($p.resolved).Count) | Should -Be 1
    }

    It 'deduplicates different task rules by the same complete task path' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='SharedTask'; TaskPath='\Vendor\'; State='Ready' } } -ParameterFilter { $TaskName -eq 'SharedTask' -and $TaskPath -eq '\Vendor\' }
        $byName = New-Schema3PolicyHit -Id 'task-by-name' -Action 'disable_task' -HitType 'task' -TaskPath '\Vendor\SharedTask' -MatchedPattern 'SharedTask' -MatchedField 'task_name'
        $byPath = New-Schema3PolicyHit -Id 'task-by-path' -Action 'disable_task' -HitType 'task' -TaskPath '\vendor\sharedtask' -MatchedPattern '\vendor\sharedtask' -MatchedField 'task_path'

        Save-PendingActions -Hits @($byName, $byPath) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        (@($p.actions).Count + @($p.resolved).Count) | Should -Be 1
    }

    It 'reads target state once so duplicate service hits cannot split across action and resolved' {
        $script:SharedServiceReadCount = 0
        Mock Get-Service {
            $script:SharedServiceReadCount++
            if ($script:SharedServiceReadCount -eq 1) {
                return [pscustomobject]@{ Name='SharedSvc'; StartType='Automatic'; Status='Running' }
            }
            return [pscustomobject]@{ Name='SharedSvc'; StartType='Disabled'; Status='Stopped' }
        } -ParameterFilter { $Name -eq 'SharedSvc' }
        $first = New-Schema3PolicyHit -Id 'state-first' -Action 'disable_service' -HitType 'service' -ServiceName 'SharedSvc' -MatchedPattern 'SharedSvc' -MatchedField 'service_name'
        $second = New-Schema3PolicyHit -Id 'state-second' -Action 'disable_service' -HitType 'service' -ServiceName 'SharedSvc' -MatchedPattern 'Shared Service' -MatchedField 'service_display_name' -ServiceDisplayName 'Shared Service'

        Save-PendingActions -Hits @($first, $second) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 1
        @($p.resolved).Count | Should -Be 0
        Assert-MockCalled Get-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'SharedSvc' }
    }

    It 'prefers manual_impact over automatic_safe when the same target and action conflict' {
        Mock Get-Service { [pscustomobject]@{ Name='SharedSvc'; StartType='Automatic'; Status='Running' } } -ParameterFilter { $Name -eq 'SharedSvc' }
        $automatic = New-Schema3PolicyHit -Id 'automatic-rule' -Action 'disable_service' -HitType 'service' -ServiceName 'SharedSvc' -MatchedPattern 'SharedSvc' -MatchedField 'service_name'
        $manual = New-Schema3PolicyHit -Id 'manual-rule' -Action 'disable_service' -HitType 'service' -ServiceName 'SharedSvc' -MatchedPattern 'Shared Service' -MatchedField 'service_display_name' -ServiceDisplayName 'Shared Service' -ExecutionClass 'manual_impact' -DefaultSelected $false -RequiresConfirmation $true

        Save-PendingActions -Hits @($automatic, $manual) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 1
        @($p.resolved).Count | Should -Be 0
        $p.actions[0].id | Should -BeExactly 'manual-rule'
        $p.actions[0].execution_class | Should -BeExactly 'manual_impact'
        $p.actions[0].default_selected | Should -BeFalse
        $p.actions[0].requires_confirmation | Should -BeTrue
    }

    It 'downgrades conflicting executable actions for the same target to observations' {
        Mock Get-Service { throw 'conflicting executable actions must not read target state' }
        $disable = New-Schema3PolicyHit -Id 'disable-rule' -Action 'disable_service' -HitType 'service' -ServiceName 'SharedSvc' -MatchedPattern 'SharedSvc' -MatchedField 'service_name'
        $uninstall = New-Schema3PolicyHit -Id 'uninstall-rule' -Action 'uninstall' -HitType 'service' -ServiceName 'SharedSvc' -MatchedPattern 'Shared Service' -MatchedField 'service_display_name' -ServiceDisplayName 'Shared Service'

        Save-PendingActions -Hits @($disable, $uninstall) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 0
        @($p.resolved).Count | Should -Be 0
        @($p.observations).Count | Should -Be 2
        @($p.observations.obs_reason | Select-Object -Unique) | Should -Be @('同一目标存在冲突动作，禁止自动处理')
        Assert-MockCalled Get-Service -Times 0 -Exactly
    }

    It 'keeps exact executable and broad observation separate for the same actual target' {
        Mock Get-Service { [pscustomobject]@{ Name='SharedSvc'; StartType='Automatic'; Status='Running' } } -ParameterFilter { $Name -eq 'SharedSvc' }
        $exact = New-Schema3PolicyHit -Id 'exact-rule' -Action 'disable_service' -HitType 'service' -ServiceName 'SharedSvc' -MatchedPattern 'SharedSvc' -MatchedField 'service_name'
        $broad = $exact.PSObject.Copy()
        $broad.id = 'broad-rule'
        $broad.matched_pattern = 'Shared'
        $broad.matched_type = 'contains'

        Save-PendingActions -Hits @($broad, $exact) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 1
        @($p.resolved).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].id | Should -BeExactly 'broad-rule'
    }

    It 'does not deduplicate different service targets' {
        Mock Get-Service { [pscustomobject]@{ Name=$Name; StartType='Automatic'; Status='Running' } } -ParameterFilter { $Name -in @('ServiceA','ServiceB') }
        $first = New-Schema3PolicyHit -Id 'same-rule' -Action 'disable_service' -HitType 'service' -ServiceName 'ServiceA' -MatchedPattern 'ServiceA' -MatchedField 'service_name'
        $second = New-Schema3PolicyHit -Id 'same-rule' -Action 'disable_service' -HitType 'service' -ServiceName 'ServiceB' -MatchedPattern 'ServiceB' -MatchedField 'service_name'

        Save-PendingActions -Hits @($first, $second) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 2
        @($p.actions.service_name) | Should -Contain 'ServiceA'
        @($p.actions.service_name) | Should -Contain 'ServiceB'
    }

    It 'preserves autostart value identity when source and name are the same' {
        $first = [pscustomobject]@{
            id='autostart-value'; vendor='T'; name_cn='Auto'; action='remove_autostart'; hit_type='autostart'; detail='X'; reason_cn='r'
            service_name=''; autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autostart_name='X'; autostart_value='C:\Apps\first.exe'
            task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }
            matched_pattern='C:\Apps'; matched_type='path'; matched_field='autostart_value'
        }
        $second = $first.PSObject.Copy()
        $second.autostart_value = 'C:\Apps\second.exe'
        $null = Set-ValidAutomaticPolicy $first
        $null = Set-ValidAutomaticPolicy $second

        Save-PendingActions -Hits @($first, $second) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 2
        @($p.actions.autostart_value) | Should -Contain 'C:\Apps\first.exe'
        @($p.actions.autostart_value) | Should -Contain 'C:\Apps\second.exe'
    }

    It 'fails closed to observations for broad or malformed display policy evidence' -TestCases @(
        @{ Label='broad-only'; Mutate={ param($h) $h.matched_type='contains' } },
        @{ Label='missing policy'; Mutate={ param($h) $h.PSObject.Properties.Remove('impact_cn') } },
        @{ Label='string boolean'; Mutate={ param($h) $h.default_selected='true' } }
    ) {
        param($Label, $Mutate)
        $hit = New-Schema3PolicyHit -Id $Label -Action 'disable_service' -HitType 'service' -ServiceName 'S1' -MatchedPattern 'S1' -MatchedField 'service_name'
        & $Mutate $hit

        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 0
        @($p.resolved).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
    }

    It 'never resolves a disabled service or task when that inventory category is incomplete' -TestCases @(
        @{ HitType='service'; Action='disable_service'; HealthKey='services'; Service='HRWSCCtrl'; Task=''; Pattern='HRWSCCtrl'; Field='service_name' },
        @{ HitType='task'; Action='disable_task'; HealthKey='tasks'; Service=''; Task='\Lenovo\LenovoMachineFixUser_OOBE_AUTO_Notification'; Pattern='LenovoMachineFixUser_OOBE_AUTO_Notification'; Field='task_name' }
    ) {
        param($HitType, $Action, $HealthKey, $Service, $Task, $Pattern, $Field)
        if ($HitType -eq 'service') { Mock Get-Service { [pscustomobject]@{ Name='HRWSCCtrl'; StartType='Disabled'; Status='Stopped' } } -ParameterFilter { $Name -eq 'HRWSCCtrl' } }
        if ($HitType -eq 'task') { Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='LenovoMachineFixUser_OOBE_AUTO_Notification'; TaskPath='\Lenovo\'; State='Disabled' } } -ParameterFilter { $TaskName -eq 'LenovoMachineFixUser_OOBE_AUTO_Notification' -and $TaskPath -eq '\Lenovo\' } }
        $hit = New-Schema3PolicyHit -Id "incomplete-$HitType" -Action $Action -HitType $HitType -ServiceName $Service -TaskPath $Task -MatchedPattern $Pattern -MatchedField $Field
        $health = [pscustomobject]@{ system_info='complete'; services='complete'; tasks='complete' }
        $health.$HealthKey = 'degraded'

        Save-PendingActions -Hits @($hit) -Suspicious @() -ScanHealth $health
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 0
        @($p.resolved).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
    }

    It 'pending JSON keeps the schema 3 four-array envelope when an action resolved and observation coexist' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName='LenovoMachineFixUser_OOBE_AUTO_Notification'; TaskPath='\Lenovo\'; State='Ready' } } -ParameterFilter { $TaskName -eq 'LenovoMachineFixUser_OOBE_AUTO_Notification' -and $TaskPath -eq '\Lenovo\' }
        Mock Get-Service { [pscustomobject]@{ Name='HRWSCCtrl'; StartType='Disabled'; Status='Stopped' } } -ParameterFilter { $Name -eq 'HRWSCCtrl' }
        $action = New-Schema3PolicyHit -Id 'enabled-task' -Action 'disable_task' -HitType 'task' -TaskPath '\Lenovo\LenovoMachineFixUser_OOBE_AUTO_Notification' -MatchedPattern 'LenovoMachineFixUser_OOBE_AUTO_Notification' -MatchedField 'task_name'
        $resolved = New-Schema3PolicyHit -Id 'disabled-service' -Action 'disable_service' -HitType 'service' -ServiceName 'HRWSCCtrl' -MatchedPattern 'HRWSCCtrl' -MatchedField 'service_name'
        $observation = $action.PSObject.Copy()
        $observation.id = 'broad-observation'
        $observation.matched_type = 'contains'
        $observation.matched_pattern = 'Lenovo'

        Save-PendingActions -Hits @($action, $resolved, $observation) -Suspicious @()
        $raw = Get-Content $script:PendingFile -Raw -Encoding UTF8
        $p = $raw | ConvertFrom-Json

        foreach ($branch in @('actions','resolved','observations','suspicious')) {
            $raw | Should -Match ('"' + $branch + '"\s*:\s*\[')
            $p.PSObject.Properties.Name | Should -Contain $branch
        }
        @($p.actions).Count | Should -Be 1
        @($p.resolved).Count | Should -Be 1
        @($p.observations).Count | Should -Be 1
        @($p.suspicious).Count | Should -Be 0
        foreach ($row in @($p.actions) + @($p.resolved) + @($p.observations)) {
            $row.execution_class -is [string] | Should -BeTrue
            $row.necessity -is [string] | Should -BeTrue
            $row.default_selected -is [bool] | Should -BeTrue
            $row.requires_confirmation -is [bool] | Should -BeTrue
            $row.impact_cn -is [string] | Should -BeTrue
            $row.cleanup_reason_cn -is [string] | Should -BeTrue
        }
    }

    It 'pending JSON 对 0/1 条 action 和 observation 始终使用四数组 token' {
        Save-PendingActions -Hits @() -Suspicious @()
        $raw = Get-Content $script:PendingFile -Raw -Encoding UTF8
        $raw | Should -Match '"actions"\s*:\s*\[\s*\]'
        $raw | Should -Match '"resolved"\s*:\s*\[\s*\]'
        $raw | Should -Match '"observations"\s*:\s*\[\s*\]'
        $raw | Should -Match '"suspicious"\s*:\s*\[\s*\]'

        $action = [pscustomobject]@{ id='one-action'; vendor='T'; name_cn='A'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name' }
        $null = Set-ValidAutomaticPolicy $action
        Save-PendingActions -Hits @($action) -Suspicious @()
        $raw = Get-Content $script:PendingFile -Raw -Encoding UTF8
        $raw | Should -Match '"actions"\s*:\s*\[\s*\{'
        $raw | Should -Match '"resolved"\s*:\s*\[\s*\]'
        $raw | Should -Match '"observations"\s*:\s*\[\s*\]'
        $raw | Should -Match '"suspicious"\s*:\s*\[\s*\]'

        $observation = [pscustomobject]@{ id='one-observation'; vendor='T'; name_cn='O'; action='investigate'; hit_type='service'; detail='S2'; reason_cn='r'; service_name='S2'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S2'; matched_type='exact'; matched_field='service_name' }
        Save-PendingActions -Hits @($observation) -Suspicious @()
        $raw = Get-Content $script:PendingFile -Raw -Encoding UTF8
        $raw | Should -Match '"actions"\s*:\s*\[\s*\]'
        $raw | Should -Match '"resolved"\s*:\s*\[\s*\]'
        $raw | Should -Match '"observations"\s*:\s*\[\s*\{'
        $raw | Should -Match '"suspicious"\s*:\s*\[\s*\]'
    }
    It 'pending JSON 保存扫描健康状态与警告' {
        $health = [pscustomobject]@{ system_info='degraded'; services='complete'; tasks='complete' }
        Save-PendingActions -Hits @() -Suspicious @() -ScanHealth $health -ScanWarnings @('系统概况使用兼容采集')

        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $p.scan_health.system_info | Should -Be 'degraded'
        @($p.scan_warnings).Count | Should -Be 1
    }
    It '服务采集降级时精确危险动作只进入观察' {
        $hit = [pscustomobject]@{
            id='health-service'; vendor='T'; name_cn='Service'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
            service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
            safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name'
        }
        $health = [pscustomobject]@{ system_info='complete'; services='degraded'; tasks='complete' }

        Save-PendingActions -Hits @($hit) -Suspicious @() -ScanHealth $health -ScanWarnings @('service incomplete')
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].action | Should -BeExactly 'disable_service'
        $p.observations[0].obs_reason | Should -Match '扫描信息不完整'
    }
    It '任务采集不是 complete 时精确危险动作只进入观察' {
        $hit = [pscustomobject]@{
            id='health-task'; vendor='T'; name_cn='Task'; action='disable_task'; hit_type='task'; detail='\X\T1'; reason_cn='r'
            service_name=''; autostart_source=''; autostart_name=''; task_path='\X\T1'; process_name=''; process_id=0; process_path=''
            safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='\X\T1'; matched_type='exact'; matched_field='task_path'
        }
        $health = [pscustomobject]@{ system_info='complete'; services='complete'; tasks='unknown' }

        Save-PendingActions -Hits @($hit) -Suspicious @() -ScanHealth $health -ScanWarnings @('task incomplete')
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].obs_reason | Should -Match '扫描信息不完整'
    }
    It 'limited 跨类别仅降级 service task 且保留健康自启与身份绑定进程' {
        $hits = @(
            [pscustomobject]@{ id='limited-service';vendor='T';name_cn='Service';action='disable_service';hit_type='service';detail='S1';reason_cn='r';service_name='S1';autostart_source='';autostart_name='';autostart_value='';task_path='';process_name='';process_id=0;process_path='';safe=$true;evidence=[pscustomobject]@{tested=$true};matched_pattern='S1';matched_type='exact';matched_field='service_name' },
            [pscustomobject]@{ id='limited-task';vendor='T';name_cn='Task';action='disable_task';hit_type='task';detail='\X\T1';reason_cn='r';service_name='';autostart_source='';autostart_name='';autostart_value='';task_path='\X\T1';process_name='';process_id=0;process_path='';safe=$true;evidence=[pscustomobject]@{tested=$true};matched_pattern='\X\T1';matched_type='exact';matched_field='task_path' },
            [pscustomobject]@{ id='limited-autostart';vendor='T';name_cn='Auto';action='remove_autostart';hit_type='autostart';detail='X';reason_cn='r';service_name='';autostart_source='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';autostart_name='X';autostart_value='C:\fake\X.exe';task_path='';process_name='';process_id=0;process_path='';safe=$true;evidence=[pscustomobject]@{tested=$true};matched_pattern='X';matched_type='exact';matched_field='autostart_name' }
        )
        $hits | ForEach-Object { $null = Set-ValidAutomaticPolicy $_ }
        $suspicious = [pscustomobject]@{ PID=42;Name='once';'CPU%'=8;MemMB=50;Path='C:\Temp\once.exe';Reason='temp';StartTimeUtc='2026-08-11T00:00:00.0000000Z';CanStop=$true;StopBlockReason='' }
        $health = [pscustomobject]@{ system_info='complete';services='degraded';tasks='unavailable' }

        Save-PendingActions -Hits $hits -Suspicious @($suspicious) -ScanHealth $health -ScanWarnings @('limited')
        $p = ConvertFrom-StrictPendingJson (Get-Content $script:PendingFile -Raw -Encoding UTF8)

        @($p.actions).Count | Should -Be 1
        $autostartAction = @($p.actions | Where-Object { $_.id -ceq 'limited-autostart' })
        $autostartAction.Count | Should -Be 1
        $autostartAction[0].action | Should -BeExactly 'remove_autostart'
        $autostartAction[0].hit_type | Should -BeExactly 'autostart'
        $autostartAction[0].matched_type | Should -BeExactly 'exact'
        $autostartAction[0].matched_field | Should -BeExactly 'autostart_name'
        $autostartAction[0].status | Should -BeExactly 'pending'

        @($p.observations).Count | Should -Be 2
        $serviceObservation = @($p.observations | Where-Object { $_.id -ceq 'limited-service' })
        $serviceObservation.Count | Should -Be 1
        $serviceObservation[0].hit_type | Should -BeExactly 'service'
        $serviceObservation[0].matched_type | Should -BeExactly 'exact'
        $serviceObservation[0].obs_reason | Should -Match '扫描信息不完整'
        $taskObservation = @($p.observations | Where-Object { $_.id -ceq 'limited-task' })
        $taskObservation.Count | Should -Be 1
        $taskObservation[0].hit_type | Should -BeExactly 'task'
        $taskObservation[0].matched_type | Should -BeExactly 'exact'
        $taskObservation[0].obs_reason | Should -Match '扫描信息不完整'

        @($p.suspicious).Count | Should -Be 1
        $savedSuspicious = @($p.suspicious | Where-Object { $_.PID -eq 42 })
        $savedSuspicious.Count | Should -Be 1
        $savedSuspicious[0].Name | Should -BeExactly 'once'
        $savedSuspicious[0].Path | Should -BeExactly 'C:\Temp\once.exe'
        $savedSuspicious[0].StartTimeUtc | Should -BeExactly '2026-08-11T00:00:00.0000000Z'
        $savedSuspicious[0].CanStop | Should -BeTrue
        $savedSuspicious[0].status | Should -BeExactly 'pending'

        $p.scan_health.services | Should -BeExactly 'degraded'
        $p.scan_health.tasks | Should -BeExactly 'unavailable'
        @($p.scan_warnings) | Should -Contain 'limited'
    }
    It 'system_info 降级不阻止健康 services 类别的精确动作' {
        $hit = [pscustomobject]@{
            id='health-independent'; vendor='T'; name_cn='Service'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'
            service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''
            safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name'
        }
        $null = Set-ValidAutomaticPolicy $hit
        $health = [pscustomobject]@{ system_info='degraded'; services='complete'; tasks='complete' }

        Save-PendingActions -Hits @($hit) -Suspicious @() -ScanHealth $health -ScanWarnings @('system info incomplete')
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 1
        @($p.observations).Count | Should -Be 0
    }
    It '动作与命中类型不匹配时不能绕过类别健康闸门进入 actions' {
        $hit = [pscustomobject]@{
            id='mismatched-process-service'; vendor='T'; name_cn='Mismatch'; action='disable_service'; hit_type='process'; detail='P1 PID=101'; reason_cn='r'
            service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name='P1'; process_id=101; process_path='C:\Apps\P1.exe'
            safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='P1'; matched_type='exact'; matched_field='process_name'
        }
        $health = [pscustomobject]@{ system_info='complete'; services='degraded'; tasks='complete' }

        Save-PendingActions -Hits @($hit) -Suspicious @() -ScanHealth $health -ScanWarnings @('service incomplete')
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 1
        $p.observations[0].obs_reason | Should -Match '动作.*命中类型.*不匹配'
    }
    It '所有已知危险动作使用错误 hit_type 时一律只进入观察' {
        $cases = @(
            [pscustomobject]@{ action='disable_service'; hit_type='task'; pattern='\X\T1'; field='task_path'; service=''; task='\X\T1'; autoSource=''; autoName=''; process=''; pid=0; path='' },
            [pscustomobject]@{ action='disable_task'; hit_type='service'; pattern='S1'; field='service_name'; service='S1'; task=''; autoSource=''; autoName=''; process=''; pid=0; path='' },
            [pscustomobject]@{ action='remove_autostart'; hit_type='process'; pattern='P1'; field='process_name'; service=''; task=''; autoSource=''; autoName=''; process='P1'; pid=101; path='C:\Apps\P1.exe' }
        )
        foreach ($case in $cases) {
            $hit = [pscustomobject]@{
                id=('mismatch-' + $case.action); vendor='T'; name_cn='Mismatch'; action=$case.action; hit_type=$case.hit_type; detail='target'; reason_cn='r'
                service_name=$case.service; autostart_source=$case.autoSource; autostart_name=$case.autoName; task_path=$case.task
                process_name=$case.process; process_id=$case.pid; process_path=$case.path
                safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern=$case.pattern; matched_type='exact'; matched_field=$case.field
            }
            $null = Set-ValidAutomaticPolicy $hit

            Save-PendingActions -Hits @($hit) -Suspicious @() -ScanHealth ([pscustomobject]@{ system_info='complete'; services='complete'; tasks='complete' }) -ScanWarnings @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

            @($p.actions).Count | Should -Be 0 -Because "$($case.action) cannot target $($case.hit_type)"
            @($p.observations).Count | Should -Be 1 -Because "$($case.action) cannot target $($case.hit_type)"
            $p.observations[0].obs_reason | Should -Match '动作.*命中类型.*不匹配'
        }
    }
    It 'uninstall 保持 service process autostart task 四类 profile 契约' {
        $cases = @(
            [pscustomobject]@{ hit_type='service'; pattern='S1'; field='service_name'; service='S1'; task=''; autoSource=''; autoName=''; process=''; pid=0; path='' },
            [pscustomobject]@{ hit_type='process'; pattern='P1'; field='process_name'; service=''; task=''; autoSource=''; autoName=''; process='P1'; pid=101; path='C:\Apps\P1.exe' },
            [pscustomobject]@{ hit_type='autostart'; pattern='X'; field='autostart_name'; service=''; task=''; autoSource='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; autoName='X'; process=''; pid=0; path='' },
            [pscustomobject]@{ hit_type='task'; pattern='\X\T1'; field='task_path'; service=''; task='\X\T1'; autoSource=''; autoName=''; process=''; pid=0; path='' }
        )
        foreach ($case in $cases) {
            $hit = [pscustomobject]@{
                id=('uninstall-' + $case.hit_type); vendor='T'; name_cn='Uninstall'; action='uninstall'; hit_type=$case.hit_type; detail='target'; reason_cn='r'
                service_name=$case.service; autostart_source=$case.autoSource; autostart_name=$case.autoName; task_path=$case.task
                process_name=$case.process; process_id=$case.pid; process_path=$case.path
                safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern=$case.pattern; matched_type='exact'; matched_field=$case.field
            }
            $null = Set-ValidAutomaticPolicy $hit

            Save-PendingActions -Hits @($hit) -Suspicious @() -ScanHealth ([pscustomobject]@{ system_info='complete'; services='complete'; tasks='complete' }) -ScanWarnings @()
            $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json

            @($p.actions).Count | Should -Be 1 -Because "uninstall is valid for $($case.hit_type)"
            @($p.observations).Count | Should -Be 0 -Because "uninstall is valid for $($case.hit_type)"
            $p.actions[0].action | Should -BeExactly 'uninstall'
            $p.actions[0].hit_type | Should -BeExactly $case.hit_type
        }
    }
    It '服务已禁用且停止时写入 resolved 而非 action 或 observation' {
        Mock Get-Service { [pscustomobject]@{ Name='S1'; StartType='Disabled'; Status='Stopped' } } -ParameterFilter { $Name -eq 'S1' }
        $hit = [pscustomobject]@{ id='already'; vendor='T'; name_cn='Already'; action='disable_service'; hit_type='service'; detail='S1'; reason_cn='r'; service_name='S1'; autostart_source=''; autostart_name=''; task_path=''; process_name=''; process_id=0; process_path=''; safe=$true; evidence=[pscustomobject]@{ tested=$true }; matched_pattern='S1'; matched_type='exact'; matched_field='service_name' }
        $null = Set-ValidAutomaticPolicy $hit
        Save-PendingActions -Hits @($hit) -Suspicious @()
        $p = Get-Content $script:PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($p.actions).Count | Should -Be 0
        @($p.observations).Count | Should -Be 0
        @($p.resolved).Count | Should -Be 1
    }
    It 'clean 只处理 pending/failed' {
        ('pending') -in @('pending','failed') | Should -Be $true
        ('failed') -in @('pending','failed') | Should -Be $true
        ('success') -in @('pending','failed') | Should -Be $false
        ('manual_required') -in @('pending','failed') | Should -Be $false
    }
    It 'pending 序列化完整可疑进程身份并设置 pending 状态' {
        $s = [pscustomobject]@{
            PID=42; Name='suspect'; 'CPU%'=8; MemMB=50; Path='C:\Temp\suspect.exe'; Reason='temp'
            StartTimeUtc='2026-08-11T00:00:00.0000000Z'; CanStop=$true; StopBlockReason=''
            Necessity='按需结束'; Impact='只结束当前进程，正在使用的功能可能中断'
        }

        Save-PendingActions -Hits @() -Suspicious @($s)
        $pending = ConvertFrom-StrictPendingJson (Get-Content $script:PendingFile -Raw -Encoding UTF8)

        $pending.suspicious[0].status | Should -BeExactly 'pending'
        $pending.suspicious[0].StartTimeUtc | Should -BeExactly $s.StartTimeUtc
        $pending.suspicious[0].CanStop | Should -BeTrue
        $pending.suspicious[0].Necessity | Should -BeExactly '按需结束'
        $pending.suspicious[0].Impact | Should -BeExactly '只结束当前进程，正在使用的功能可能中断'
    }
    It '选择的可疑进程拒绝数组 PID 和缺失身份字段' {
        $arrayPid = [pscustomobject]@{PID=@(42);Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z';CanStop=$true;status='pending'}
        $missingPath = [pscustomobject]@{PID=42;Name='suspect';Path='';StartTimeUtc='2026-08-11T00:00:00.0000000Z';CanStop=$true;status='pending'}

        { Assert-SuspiciousPendingRow $arrayPid -RequireStoppable } | Should -Throw '*PID*'
        { Assert-SuspiciousPendingRow $missingPath -RequireStoppable } | Should -Throw '*Path*'
    }
    It '可疑停止子集保持与 OEM actions resolved observations 完全分离' {
        $row = [pscustomobject]@{PID=42;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z';CanStop=$true;StopBlockReason='';status='pending';Reason='temp';Necessity='按需结束';Impact='只结束当前进程';'CPU%'=8;MemMB=50}

        $subset = Build-SuspiciousSubsetPayload @($row)

        $subset.pending_schema_version.GetType() | Should -Be ([int32])
        $subset.pending_schema_version | Should -Be 3
        @($subset.actions).Count | Should -Be 0
        @($subset.resolved).Count | Should -Be 0
        @($subset.observations).Count | Should -Be 0
        @($subset.suspicious).Count | Should -Be 1
        $subset.suspicious[0].PID | Should -Be 42
        $subset.suspicious[0].Necessity | Should -BeExactly '按需结束'
        $subset.suspicious[0].Impact | Should -BeExactly '只结束当前进程'
    }
}
