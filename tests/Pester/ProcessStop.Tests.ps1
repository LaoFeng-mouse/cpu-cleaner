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
        $script:currentIdentity = [pscustomobject]@{
            service_name='HRWSCCtrl'; service_binary_path=$script:binary; process_id=[int]4321
            process_name='wsctrl11.exe'; process_path=$script:binary
            process_start_time_utc='2026-08-24T01:02:03.0000000Z'
        }
        Mock Get-CurrentServiceProcessIdentity { [pscustomobject]@{ Identity=$script:currentIdentity; Reason='' } }
        Mock Stop-Process {}
        Mock Get-Process { $null }
        Mock Get-CimInstance {
            [pscustomobject]@{ Name='HRWSCCtrl'; State='Stopped'; ProcessId=[int]0; PathName=$script:servicePathName }
        } -ParameterFilter { $ClassName -ceq 'Win32_Service' }
    }

    It 'skips every recorded identity drift without mutation' -TestCases @(
        @{ field='service_name'; value='OtherSvc'; reason='service name' }
        @{ field='service_binary_path'; value='C:\Other\wsctrl11.exe'; reason='service binary path' }
        @{ field='process_id'; value=[int]4322; reason='PID' }
        @{ field='process_name'; value='other.exe'; reason='process name' }
        @{ field='process_path'; value='C:\Other\wsctrl11.exe'; reason='process path' }
        @{ field='process_start_time_utc'; value='2026-08-24T01:02:04.0000000Z'; reason='start time' }
    ) {
        param($field, $value, $reason)
        $current = $script:currentIdentity.PSObject.Copy()
        $current.$field = $value
        Mock Get-CurrentServiceProcessIdentity { [pscustomobject]@{ Identity=$current; Reason='' } }

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'skipped'
        $result.result_reason | Should -Match $reason
        $result.failure_stage | Should -BeNullOrEmpty
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
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'records a sanitized mutation failure when Stop-Process is denied' {
        Mock Stop-Process { throw 'Access denied for C:\secret\command line --token=abc' }

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'failed'
        $result.result_reason | Should -Match 'denied|权限|拒绝'
        $result.result_reason | Should -Not -Match 'token=abc'
        $result.failure_stage | Should -BeExactly 'mutation'
    }

    It 'fails verification when the original PID remains alive' {
        Mock Get-Process { [pscustomobject]@{ Id=[int]4321 } } -ParameterFilter { $Id -eq 4321 }

        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'failed'
        $result.result_reason | Should -Match 'old PID|原 PID|仍'
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

    It 'succeeds only when the old PID is absent and no replacement PID is bound' {
        $result = Invoke-ServiceProcessStopAction -Pending $script:pendingStop

        $result.status | Should -BeExactly 'success'
        [string]::IsNullOrWhiteSpace([string]$result.result_reason) | Should -BeFalse
        $result.failure_stage | Should -BeNullOrEmpty
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter {
            $Id -eq 4321 -and $Force -eq $true -and $ErrorAction -eq 'Stop'
        }
    }
}
