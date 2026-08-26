Describe 'one-time suspicious process stop' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw 'main switch not found' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        $script:selectedRow = [pscustomobject]@{
            PID=4242; Name='suspect'; Path='C:\Temp\suspect.exe'; StartTimeUtc='2026-08-11T00:00:00.0000000Z'
            CanStop=$true; StopBlockReason=''; status='pending'; Reason='temp'; 'CPU%'=8; MemMB=50
        }
        function New-TestBoundTarget($Identity) {
            [pscustomobject]@{ Process = [pscustomobject]@{}; Identity = $Identity }
        }
    }

    It 'skips when the PID now belongs to a different path' {
        Mock Get-BoundProcessTarget { New-TestBoundTarget ([pscustomobject]@{PID=4242;Name='suspect';Path='C:\Other\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'}) }
        Mock Stop-BoundProcessTarget { $true }
        $result = Invoke-OneTimeProcessStop $script:selectedRow
        $result.status | Should -BeExactly 'skipped'
        Should -Invoke Stop-BoundProcessTarget -Times 0 -Exactly
    }

    It 'stops only an exact four-field identity and confirms exit' {
        Mock Get-BoundProcessTarget { New-TestBoundTarget ([pscustomobject]@{PID=4242;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'}) }
        Mock Stop-BoundProcessTarget { $true }
        $result = Invoke-OneTimeProcessStop $script:selectedRow
        $result.status | Should -BeExactly 'success'
        Should -Invoke Stop-BoundProcessTarget -Times 1 -Exactly
    }

    It 'skips name or start-time mismatches' {
        foreach ($identity in @(
            [pscustomobject]@{PID=4242;Name='other';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'},
            [pscustomobject]@{PID=4242;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:01.0000000Z'}
        )) {
            Mock Get-BoundProcessTarget { New-TestBoundTarget $identity }
            Mock Stop-BoundProcessTarget { $true }
            (Invoke-OneTimeProcessStop $script:selectedRow).status | Should -BeExactly 'skipped'
            Should -Invoke Stop-BoundProcessTarget -Times 0 -Exactly
        }
    }

    It 'never stops a protected process in a trusted Windows path or the current Pester PID' {
        Mock Get-BoundProcessTarget { throw 'must not inspect protected target' }
        Mock Stop-BoundProcessTarget { $true }
        $protected = $script:selectedRow.PSObject.Copy(); $protected.Name='lsass'; $protected.Path='C:\Windows\System32\lsass.exe'
        (Invoke-OneTimeProcessStop $protected).status | Should -BeExactly 'skipped'
        $self = $script:selectedRow.PSObject.Copy(); $self.PID=$PID
        (Invoke-OneTimeProcessStop $self).status | Should -BeExactly 'skipped'
        Should -Invoke Stop-BoundProcessTarget -Times 0 -Exactly
    }

    It 'allows an exact reviewed process that only masquerades under a protected name outside Windows' {
        $masquerader = $script:selectedRow.PSObject.Copy(); $masquerader.Name='svchost'; $masquerader.Path='C:\Users\Public\Downloads\svchost.exe'
        Mock Get-BoundProcessTarget { New-TestBoundTarget ([pscustomobject]@{PID=4242;Name='svchost';Path='C:\Users\Public\Downloads\svchost.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'}) }
        Mock Stop-BoundProcessTarget { $true }

        $result = Invoke-OneTimeProcessStop $masquerader

        $result.status | Should -BeExactly 'success'
        Should -Invoke Stop-BoundProcessTarget -Times 1 -Exactly
    }

    It 'skips when the PID has disappeared' {
        Mock Get-BoundProcessTarget { $null }
        Mock Stop-BoundProcessTarget { $true }
        (Invoke-OneTimeProcessStop $script:selectedRow).status | Should -BeExactly 'skipped'
        Should -Invoke Stop-BoundProcessTarget -Times 0 -Exactly
    }

    It 'fails when stop throws or the process remains present' {
        Mock Get-BoundProcessTarget { New-TestBoundTarget ([pscustomobject]@{PID=4242;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'}) }
        Mock Stop-BoundProcessTarget { throw 'access denied' }
        (Invoke-OneTimeProcessStop $script:selectedRow).status | Should -BeExactly 'failed'
        Mock Stop-BoundProcessTarget { $false }
        (Invoke-OneTimeProcessStop $script:selectedRow).status | Should -BeExactly 'failed'
    }

    It 'persists a fixed sanitized mutation reason when bound process termination throws' {
        $path = Join-Path $TestDrive 'failed-selected-suspicious.json'
        $payload = Build-SuspiciousSubsetPayload @($script:selectedRow)
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $payload -Depth 20), [System.Text.UTF8Encoding]::new($false))
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Mock Get-BoundProcessTarget { New-TestBoundTarget ([pscustomobject]@{PID=4242;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'}) }
        Mock Stop-BoundProcessTarget { throw 'Access denied at C:\internal\agent.exe --token=raw-secret --command-line=private' }

        $result = Invoke-StopProcessPending -Path $path -ExpectedSha256 $hash
        $saved = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json

        $result.ExitCode | Should -Be 2
        $saved.suspicious[0].status | Should -BeExactly 'failed'
        $saved.suspicious[0].result_reason | Should -Match '权限|拒绝|denied|无法'
        $saved.suspicious[0].result_reason | Should -Not -Match 'internal|secret|token|command-line|C:\\'
        $saved.suspicious[0].failure_stage | Should -BeExactly 'mutation'
    }

    It 'accepts a bounded wait reported by the bound process object' {
        Mock Get-BoundProcessTarget { New-TestBoundTarget ([pscustomobject]@{PID=4242;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'}) }
        Mock Stop-BoundProcessTarget { $true }
        (Invoke-OneTimeProcessStop $script:selectedRow).status | Should -BeExactly 'success'
        Should -Invoke Stop-BoundProcessTarget -Times 1 -Exactly
    }

    It 'requires empty OEM arrays and writes terminal status to the hash-bound file' {
        $path = Join-Path $TestDrive 'selected-suspicious.json'
        $payload = Build-SuspiciousSubsetPayload @($script:selectedRow)
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $payload -Depth 20), [System.Text.UTF8Encoding]::new($false))
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Mock Invoke-OneTimeProcessStop { param($Row) $copy=$Row.PSObject.Copy(); $copy.status='success'; $copy | Add-Member NoteProperty result_reason 'stopped' -Force; $copy }
        $result = Invoke-StopProcessPending -Path $path -ExpectedSha256 $hash
        $result.ExitCode | Should -Be 0
        $saved = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        @($saved.actions).Count | Should -Be 0
        @($saved.observations).Count | Should -Be 0
        $saved.suspicious[0].status | Should -BeExactly 'success'
    }

    It 'rejects a hash mismatch or mixed OEM action without stopping' {
        $path = Join-Path $TestDrive 'invalid-selected.json'
        $payload = Build-SuspiciousSubsetPayload @($script:selectedRow)
        $payload.actions = @([pscustomobject]@{action='disable_service'})
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $payload -Depth 20), [System.Text.UTF8Encoding]::new($false))
        Mock Invoke-OneTimeProcessStop { throw 'must not stop' }
        { Invoke-StopProcessPending -Path $path -ExpectedSha256 ('0' * 64) } | Should -Throw '*SHA-256*'
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        { Invoke-StopProcessPending -Path $path -ExpectedSha256 $hash } | Should -Throw '*actions*'
        Should -Invoke Invoke-OneTimeProcessStop -Times 0 -Exactly
    }

    It 'keeps process termination out of the persistent clean flow' {
        $source = Get-Content (Join-Path $script:Root 'src\Core\ActionEngine.ps1') -Raw
        $start = $source.IndexOf('function Invoke-Clean')
        $clean = $source.Substring($start)

        $start | Should -BeGreaterOrEqual 0
        $clean | Should -Not -Match 'Stop-Process'
        $clean | Should -Not -Match 'Read-Host.+PID'
    }

    It 'binds validation and termination to one Process object instead of stopping a reusable PID' {
        $source = Get-Content (Join-Path $script:Root 'src\Core\ActionEngine.ps1') -Raw
        $start = $source.IndexOf('function Invoke-OneTimeProcessStop')
        $end = $source.IndexOf('function Invoke-StopProcessPending', $start)
        $stop = $source.Substring($start, $end - $start)

        $stop | Should -Match 'Get-BoundProcessTarget'
        $stop | Should -Match 'Stop-BoundProcessTarget'
        $stop | Should -Not -Match 'Stop-Process\s+-Id'
        $stop | Should -Not -Match 'Wait-ProcessIdentityExit'
        $source | Should -Match '\$null\s*=\s*\$process\.Handle'
    }
}

Describe 'identity-bound HRWSCCtrl service process stop' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        if ($idx -lt 0) { throw 'main switch not found' }
        $defs = $src.Substring(0, $idx)
        $defs = $defs.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs

        $script:binaryDir = Join-Path $TestDrive 'Lenovo Security Center'
        [System.IO.Directory]::CreateDirectory($script:binaryDir) | Out-Null
        $script:binary = Join-Path $script:binaryDir 'wsctrl11.exe'
        [System.IO.File]::WriteAllBytes($script:binary, [byte[]](1))
        $script:servicePathName = '"' + $script:binary + '" -service'
        $script:pendingStop = [pscustomobject]@{
            id='lenovo-hrwscctrl'; name_cn='HRWSCCtrl'; detail='HRWSCCtrl'; reason_cn='manual'
            hit_type='service'; action='stop_service_process'; status='pending'; service_name='HRWSCCtrl'
            service_binary_path=$script:binary; process_id=[int]4321; process_name='wsctrl11.exe'
            process_path=$script:binary; process_start_time_utc='2026-08-24T01:02:03.0000000Z'
            matched_pattern='HRWSCCtrl'; matched_type='exact'; matched_field='service_name'; safe=$false
            execution_class='manual_impact'; necessity='optional'; default_selected=$false; requires_confirmation=$true
            impact_cn='只结束当前实例'; cleanup_reason_cn='减少当前后台'
        }
        $script:pendingStop.PSObject.Properties.Name | Should -Not -Contain 'ProcessIdentitySource'
        $script:currentIdentity = [pscustomobject]@{
            service_name='HRWSCCtrl'; service_binary_path=$script:binary; process_id=[int]4321
            process_name='wsctrl11.exe'; process_path=$script:binary
            process_start_time_utc='2026-08-24T01:02:03.0000000Z'
        }
        $script:boundKillToken = $null
        $script:boundWaitToken = $null
        function New-HRWSCTestProcess([string]$Token = 'original') {
            $process = [pscustomobject]@{
                Id=[int]4321; ProcessName='wsctrl11'; Path=$script:binary
                StartTime=[datetime]::ParseExact('2026-08-24T01:02:03.0000000Z','o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
                Handle=[intptr]123; Token=$Token
            }
            $process | Add-Member ScriptMethod Kill { $script:boundKillToken = $this.Token }
            $process | Add-Member ScriptMethod WaitForExit { param($TimeoutMilliseconds) $script:boundWaitToken = $this.Token; return $true }
            $process | Add-Member ScriptMethod Dispose { }
            return $process
        }
        $script:defaultVerificationClock = 0
        function Get-ServiceProcessVerificationTimeMilliseconds {
            $script:defaultVerificationClock += 5000
            return [int64]$script:defaultVerificationClock
        }
        function Start-ServiceProcessVerificationDelay([int]$Milliseconds) { }
        Mock Get-CurrentServiceProcessIdentity { [pscustomobject]@{ Identity=$script:currentIdentity; Reason='' } }
        Mock Stop-Process {}
        Mock Get-Process { New-HRWSCTestProcess }
        Mock Get-CurrentServiceExecutionSnapshot {
            [pscustomobject]@{
                Name='HRWSCCtrl'; State='Running'; ProcessId=[int]4321
                PathName=$script:servicePathName; BinaryPath=$script:binary
            }
        }
        Mock Get-CimInstance {
            [pscustomobject]@{ Name='HRWSCCtrl'; State='Stopped'; ProcessId=[int]0; PathName=$script:servicePathName }
        } -ParameterFilter { $ClassName -ceq 'Win32_Service' }
    }

    It 'skips every recorded identity drift without mutation' -TestCases @(
        @{ field='service_name'; value='OtherSvc'; reason='service name'; administratorDrift=$false }
        @{ field='service_binary_path'; value='C:\Other\wsctrl11.exe'; reason='service binary path'; administratorDrift=$false }
        @{ field='process_id'; value=[int]4322; reason='PID'; administratorDrift=$true }
        @{ field='process_name'; value='other.exe'; reason='process name'; administratorDrift=$false }
        @{ field='process_path'; value='C:\Other\wsctrl11.exe'; reason='process path'; administratorDrift=$true }
        @{ field='process_start_time_utc'; value='2026-08-24T01:02:04.0000000Z'; reason='start time'; administratorDrift=$true }
    ) {
        param($field, $value, $reason, $administratorDrift)
        $current = $script:currentIdentity.PSObject.Copy()
        $current.$field = $value
        Mock Get-CurrentServiceProcessIdentity { [pscustomobject]@{ Identity=$current; Reason='' } }

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'skipped'
        $result.result_reason | Should -Match $reason
        if ($administratorDrift) { $result.failure_stage | Should -BeExactly 'authorization' }
        else { $result.failure_stage | Should -BeNullOrEmpty }
        [string]::IsNullOrWhiteSpace([string]$result.result_reason) | Should -BeFalse
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'skips missing or non-unique current service/process identities and requests rescan' -TestCases @(
        @{ mode='missing-service' }
        @{ mode='multiple-service' }
        @{ mode='missing-process' }
        @{ mode='multiple-process' }
        @{ mode='service-drift' }
    ) {
        param($mode)
        Mock Get-CurrentServiceProcessIdentity { [pscustomobject]@{ Identity=$null; Reason=("$mode current identity is not stable; rescan required") } }

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'skipped'
        $result.result_reason | Should -Match 'rescan'
        $result.failure_stage | Should -BeNullOrEmpty
        [string]::IsNullOrWhiteSpace([string]$result.result_reason) | Should -BeFalse
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'does not persist the trusted inventory source marker as execution authorization' {
        $upstream = $script:pendingStop.PSObject.Copy()
        $upstream | Add-Member -NotePropertyName ProcessIdentitySource -NotePropertyValue 'trusted_inventory_v2'
        $policy = [pscustomobject]@{
            execution_class='manual_impact'; necessity='optional'; default_selected=$false; requires_confirmation=$true
            impact_cn='只结束当前实例'; cleanup_reason_cn='减少当前后台'
        }

        $persisted = New-PendingPersistedHit -Hit $upstream -Policy $policy -Status 'pending'
        $json = ConvertTo-Json -InputObject ([pscustomobject]@{
            pending_schema_version=3; actions=@($persisted); resolved=@(); observations=@(); suspicious=@()
        }) -Depth 8

        $upstream.ProcessIdentitySource | Should -BeExactly 'trusted_inventory_v2'
        $persisted.PSObject.Properties.Name | Should -Not -Contain 'ProcessIdentitySource'
        $persisted.service_name | Should -BeExactly 'HRWSCCtrl'
        foreach ($field in @('service_binary_path','process_id','process_name','process_path','process_start_time_utc')) {
            $persisted.PSObject.Properties.Name | Should -Contain $field
        }
        $json | Should -Not -Match 'ProcessIdentitySource|trusted_inventory_v2'
    }

    It 'records a sanitized mutation failure when Stop-Process is denied' {
        $denied = New-HRWSCTestProcess
        $denied.PSObject.Members.Remove('Kill')
        $denied | Add-Member ScriptMethod Kill { throw 'Access denied for C:\secret\command line --token=abc' }
        Mock Get-Process { $denied }

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'failed'
        $result.result_reason | Should -Match 'denied|权限|拒绝'
        $result.result_reason | Should -Not -Match 'token=abc'
        $result.failure_stage | Should -BeExactly 'mutation'
    }

    It 'terminates and waits through the exact handle-bound Process object without a reusable PID lookup' {
        $script:boundProcess = New-HRWSCTestProcess -Token 'handle-bound-original'
        $script:reusedProcess = New-HRWSCTestProcess -Token 'reused-pid-substitute'
        $script:getProcessCalls = 0
        Mock Get-Process {
            $script:getProcessCalls++
            if ($script:getProcessCalls -eq 1) { return $script:boundProcess }
            return $script:reusedProcess
        } -ParameterFilter { $Id -eq 4321 }

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'success' -Because $result.result_reason
        $script:boundKillToken | Should -BeExactly 'handle-bound-original'
        $script:boundWaitToken | Should -BeExactly 'handle-bound-original'
        Should -Invoke Get-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4321 }
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'skips if the service binding changes after the process handle is opened' {
        Mock Get-CurrentServiceExecutionSnapshot {
            [pscustomobject]@{
                Name='HRWSCCtrl'; State='Running'; ProcessId=[int]9999
                PathName=$script:servicePathName; BinaryPath=$script:binary
            }
        }

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'skipped'
        $result.result_reason | Should -Match 'service binding|rescan'
        $script:boundKillToken | Should -BeNullOrEmpty
    }

    It 'fails verification when the original PID remains alive' {
        $notExited = New-HRWSCTestProcess
        $notExited.PSObject.Members.Remove('WaitForExit')
        $notExited | Add-Member ScriptMethod WaitForExit { param($TimeoutMilliseconds) return $false }
        Mock Get-Process { $notExited } -ParameterFilter { $Id -eq 4321 }

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'failed'
        $result.result_reason | Should -Match 'bounded wait|未退出|did not exit'
        $result.failure_stage | Should -BeExactly 'verification'
    }

    It 'fails verification and records the replacement PID when the service restarts' {
        Mock Get-CimInstance {
            [pscustomobject]@{ Name='HRWSCCtrl'; State='Running'; ProcessId=[int]9876; PathName=$script:servicePathName }
        } -ParameterFilter { $ClassName -ceq 'Win32_Service' }

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'failed'
        $result.result_reason | Should -Match 'restarted|重新拉起|重启'
        $result.result_reason | Should -Match '9876'
        $result.failure_stage | Should -BeExactly 'verification'
    }

    It 'fails verification for any positive replacement PID even when service state is not Running' -TestCases @(
        @{ state='Start Pending'; replacementPid=[int]9877 }
        @{ state='Stop Pending'; replacementPid=[int]9878 }
        @{ state='Stopped'; replacementPid=[int]9879 }
    ) {
        param($state, $replacementPid)
        Mock Get-CimInstance {
            [pscustomobject]@{ Name='HRWSCCtrl'; State=$state; ProcessId=$replacementPid; PathName=$script:servicePathName }
        } -ParameterFilter { $ClassName -ceq 'Win32_Service' }

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'failed'
        $result.result_reason | Should -Match ([string]$replacementPid)
        $result.failure_stage | Should -BeExactly 'verification'
    }

    It 'fails when a replacement PID appears after an initially clear service sample' {
        $script:serviceSamples = 0
        Mock Get-CimInstance {
            $script:serviceSamples++
            if ($script:serviceSamples -eq 1) {
                return [pscustomobject]@{ Name='HRWSCCtrl'; State='Stopped'; ProcessId=[int]0; PathName=$script:servicePathName }
            }
            return [pscustomobject]@{ Name='HRWSCCtrl'; State='Start Pending'; ProcessId=[int]9880; PathName=$script:servicePathName }
        } -ParameterFilter { $ClassName -ceq 'Win32_Service' }
        $script:clockReads = 0
        Mock Get-ServiceProcessVerificationTimeMilliseconds {
            $script:clockReads++
            if ($script:clockReads -eq 1) { return [int64]0 }
            if ($script:clockReads -eq 2) { return [int64]2500 }
            return [int64]5000
        }
        Mock Start-ServiceProcessVerificationDelay {}

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'failed'
        $result.result_reason | Should -Match '9880'
        $result.failure_stage | Should -BeExactly 'verification'
        $script:serviceSamples | Should -BeGreaterThan 1
    }

    It 'requires exact PID-zero service identity for the complete bounded stabilization window' {
        $script:serviceSamples = 0
        Mock Get-CimInstance {
            $script:serviceSamples++
            [pscustomobject]@{ Name='HRWSCCtrl'; State='Stopped'; ProcessId=[int]0; PathName=$script:servicePathName }
        } -ParameterFilter { $ClassName -ceq 'Win32_Service' }
        $script:clockReads = 0
        Mock Get-ServiceProcessVerificationTimeMilliseconds {
            $script:clockReads++
            if ($script:clockReads -eq 1) { return [int64]0 }
            if ($script:clockReads -eq 2) { return [int64]2500 }
            return [int64]5000
        }
        Mock Start-ServiceProcessVerificationDelay {}

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'success'
        $script:serviceSamples | Should -Be 2
        Should -Invoke Start-ServiceProcessVerificationDelay -Times 1 -Exactly
    }

    It 'fails verification when any stabilization sample is missing multiple or unreadable' -TestCases @(
        @{ mode='missing' }
        @{ mode='multiple' }
        @{ mode='unreadable' }
    ) {
        param($mode)
        $script:serviceSamples = 0
        Mock Get-CimInstance {
            $script:serviceSamples++
            if ($script:serviceSamples -eq 1) {
                return [pscustomobject]@{ Name='HRWSCCtrl'; State='Stopped'; ProcessId=[int]0; PathName=$script:servicePathName }
            }
            if ($mode -ceq 'missing') { return @() }
            if ($mode -ceq 'multiple') {
                return @(
                    [pscustomobject]@{ Name='HRWSCCtrl'; State='Stopped'; ProcessId=[int]0 },
                    [pscustomobject]@{ Name='HRWSCCtrl'; State='Stopped'; ProcessId=[int]0 }
                )
            }
            throw 'unreadable service state'
        } -ParameterFilter { $ClassName -ceq 'Win32_Service' }
        $script:clockReads = 0
        Mock Get-ServiceProcessVerificationTimeMilliseconds {
            $script:clockReads++
            if ($script:clockReads -eq 1) { return [int64]0 }
            if ($script:clockReads -eq 2) { return [int64]2500 }
            return [int64]5000
        }
        Mock Start-ServiceProcessVerificationDelay {}

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'failed'
        $result.failure_stage | Should -BeExactly 'verification'
        $script:serviceSamples | Should -Be 2
    }

    It 'succeeds only when the old PID is absent and no replacement PID is bound' {
        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'success'
        [string]::IsNullOrWhiteSpace([string]$result.result_reason) | Should -BeFalse
        $result.failure_stage | Should -BeNullOrEmpty
        $script:boundKillToken | Should -BeExactly 'original'
        $script:boundWaitToken | Should -BeExactly 'original'
        Should -Invoke Stop-Process -Times 0 -Exactly
    }
}

Describe 'HRWSCCtrl stable identity capture primitive' {
    BeforeEach {
        $projectRoot = if ($PSScriptRoot) { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent } else { (Get-Location).Path }
        $src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
        $idx = $src.IndexOf("switch (`$Mode)")
        $defs = $src.Substring(0, $idx).Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path', '$script:Root = $projectRoot')
        Invoke-Expression $defs
        $script:captureBinary = Join-Path $TestDrive 'wsctrl11.exe'
        [IO.File]::WriteAllBytes($script:captureBinary,[byte[]](1))
        Mock Get-CimInstance {
            [pscustomobject]@{
                Name='HRWSCCtrl'; State='Running'; ProcessId=[int]4321
                PathName=('"' + $script:captureBinary + '" -service')
            }
        } -ParameterFilter { $ClassName -ceq 'Win32_Service' }
        Mock Get-CimInstance {
            [pscustomobject]@{
                ProcessId=[int]4321; Name='wsctrl11.exe'; ExecutablePath=$script:captureBinary
                CreationDate=[datetimeoffset]::Parse('2026-08-24T01:02:03.0000000+00:00',[Globalization.CultureInfo]::InvariantCulture)
            }
        } -ParameterFilter { $ClassName -ceq 'Win32_Process' }
    }

    It 'reads service process service without replacing the strict capture helper' {
        $capture = Get-CurrentServiceProcessIdentity -ServiceName 'HRWSCCtrl'

        $capture.Identity.service_name | Should -BeExactly 'HRWSCCtrl'
        $capture.Identity.process_id | Should -Be 4321
        $capture.Identity.process_path | Should -BeExactly $script:captureBinary
        Should -Invoke Get-CimInstance -Times 2 -Exactly -ParameterFilter { $ClassName -ceq 'Win32_Service' }
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $ClassName -ceq 'Win32_Process' }
    }
}
