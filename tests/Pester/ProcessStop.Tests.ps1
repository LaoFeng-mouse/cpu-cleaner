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
    }

    It 'skips when the PID now belongs to a different path' {
        Mock Get-CurrentProcessIdentity { [pscustomobject]@{PID=4242;Name='suspect';Path='C:\Other\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'} }
        Mock Stop-Process {}
        $result = Invoke-OneTimeProcessStop $script:selectedRow
        $result.status | Should -BeExactly 'skipped'
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'stops only an exact four-field identity and confirms exit' {
        $script:afterStop = $false
        Mock Get-CurrentProcessIdentity {
            if ($script:afterStop) { return $null }
            [pscustomobject]@{PID=4242;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'}
        }
        Mock Stop-Process { $script:afterStop = $true }
        $result = Invoke-OneTimeProcessStop $script:selectedRow
        $result.status | Should -BeExactly 'success'
        Should -Invoke Stop-Process -Times 1 -Exactly
    }

    It 'skips name or start-time mismatches' {
        foreach ($identity in @(
            [pscustomobject]@{PID=4242;Name='other';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'},
            [pscustomobject]@{PID=4242;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:01.0000000Z'}
        )) {
            Mock Get-CurrentProcessIdentity { $identity }
            Mock Stop-Process {}
            (Invoke-OneTimeProcessStop $script:selectedRow).status | Should -BeExactly 'skipped'
            Should -Invoke Stop-Process -Times 0 -Exactly
        }
    }

    It 'never stops a protected process name or the current Pester PID' {
        Mock Get-CurrentProcessIdentity { throw 'must not inspect protected target' }
        Mock Stop-Process {}
        $protected = $script:selectedRow.PSObject.Copy(); $protected.Name='lsass'
        (Invoke-OneTimeProcessStop $protected).status | Should -BeExactly 'skipped'
        $self = $script:selectedRow.PSObject.Copy(); $self.PID=$PID
        (Invoke-OneTimeProcessStop $self).status | Should -BeExactly 'skipped'
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'skips when the PID has disappeared' {
        Mock Get-CurrentProcessIdentity { $null }
        Mock Stop-Process {}
        (Invoke-OneTimeProcessStop $script:selectedRow).status | Should -BeExactly 'skipped'
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'fails when stop throws or the process remains present' {
        Mock Get-CurrentProcessIdentity { [pscustomobject]@{PID=4242;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'} }
        Mock Stop-Process { throw 'access denied' }
        (Invoke-OneTimeProcessStop $script:selectedRow).status | Should -BeExactly 'failed'
        Mock Stop-Process {}
        (Invoke-OneTimeProcessStop $script:selectedRow).status | Should -BeExactly 'failed'
    }

    It 'allows a short bounded exit delay after Stop-Process returns' {
        $script:identityReads = 0
        Mock Get-CurrentProcessIdentity {
            $script:identityReads++
            if ($script:identityReads -le 2) {
                return [pscustomobject]@{PID=4242;Name='suspect';Path='C:\Temp\suspect.exe';StartTimeUtc='2026-08-11T00:00:00.0000000Z'}
            }
            return $null
        }
        Mock Stop-Process {}
        Mock Start-Sleep {}

        (Invoke-OneTimeProcessStop $script:selectedRow).status | Should -BeExactly 'success'
        Should -Invoke Start-Sleep -Times 1 -Exactly
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
}
