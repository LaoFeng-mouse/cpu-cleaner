# 备份恢复 (v1.7.0 拆分): 单值备份/恢复
$script:TrustedBackupSystemSid = 'S-1-5-18'
$script:TrustedBackupAdministratorsSid = 'S-1-5-32-544'

function Get-SecureBackupRoot {
    $programData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($programData)) { throw '无法确定 ProgramData 安全备份根' }
    return [System.IO.Path]::Combine($programData, 'MouseCleaner', 'Backups')
}

function Get-BackupAclDescriptor($Path) {
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
            [pscustomobject]@{ Sid=$_.IdentityReference.Value; Type=$_.AccessControlType.ToString(); Rights=[int64]$_.FileSystemRights; Inherited=[bool]$_.IsInherited }
        })
        return [pscustomobject]@{ OwnerSid=$owner; Protected=[bool]$acl.AreAccessRulesProtected; Rules=$rules }
    } catch { throw ('ACL 读取失败: ' + $_.Exception.Message) }
}

function Test-TrustedBackupAclDescriptor($Descriptor, [bool]$RequireProtected = $true, [bool]$ParentOnly = $false) {
    if ($null -eq $Descriptor -or $Descriptor.OwnerSid -isnot [string] -or
        $Descriptor.OwnerSid -cnotin @($script:TrustedBackupSystemSid, $script:TrustedBackupAdministratorsSid)) { return $false }
    if ($RequireProtected -and ($Descriptor.Protected -isnot [bool] -or -not $Descriptor.Protected)) { return $false }
    $writeMask = if ($ParentOnly) {
        # 父目录只需拒绝可删除/改 ACL/夺取所有权的权限；仅 CreateDirectories 不足以替换已受保护的子目录。
        [int64]([System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [System.Security.AccessControl.FileSystemRights]::Delete -bor [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
    } else {
        [int64]([System.Security.AccessControl.FileSystemRights]::Write -bor [System.Security.AccessControl.FileSystemRights]::Modify -bor [System.Security.AccessControl.FileSystemRights]::FullControl -bor [System.Security.AccessControl.FileSystemRights]::Delete -bor [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
    }
    $trustedWriters = @{}
    foreach ($rule in @($Descriptor.Rules)) {
        if ($null -eq $rule -or $rule.Sid -isnot [string] -or $rule.Type -isnot [string] -or -not (Test-StrictInteger $rule.Rights)) { return $false }
        if ($RequireProtected -and $rule.Inherited -ne $false) { return $false }
        if ($rule.Type -ceq 'Allow' -and ([int64]$rule.Rights -band $writeMask) -ne 0) {
            if ($rule.Sid -cnotin @($script:TrustedBackupSystemSid, $script:TrustedBackupAdministratorsSid)) { return $false }
            $trustedWriters[$rule.Sid] = $true
        }
    }
    if (-not $ParentOnly -and (-not $trustedWriters.ContainsKey($script:TrustedBackupSystemSid) -or -not $trustedWriters.ContainsKey($script:TrustedBackupAdministratorsSid))) { return $false }
    return $true
}

function Assert-TrustedBackupPathAcl($Path, [bool]$RequireProtected = $true, [bool]$ParentOnly = $false) {
    $descriptor = Get-BackupAclDescriptor $Path
    if (-not (Test-TrustedBackupAclDescriptor -Descriptor $descriptor -RequireProtected $RequireProtected -ParentOnly $ParentOnly)) {
        throw (New-RestoreCandidateRejectedException "备份路径 owner/DACL 不可信: $Path")
    }
}

function New-ProtectedBackupSecurity([bool]$Directory = $true) {
    $security = if ($Directory) { New-Object System.Security.AccessControl.DirectorySecurity } else { New-Object System.Security.AccessControl.FileSecurity }
    $security.SetAccessRuleProtection($true, $false)
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier($script:TrustedBackupAdministratorsSid)
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier($script:TrustedBackupSystemSid)
    $security.SetOwner($adminSid)
    $inheritance = if ($Directory) { [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [System.Security.AccessControl.InheritanceFlags]::None }
    foreach ($sid in @($systemSid, $adminSid)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [System.Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $null = $security.AddAccessRule($rule)
    }
    return $security
}

function New-ProtectedBackupDirectory($Path) { return [System.IO.Directory]::CreateDirectory($Path, (New-ProtectedBackupSecurity -Directory $true)) }
function Set-BackupPathAcl($Path, $Acl) { Set-Acl -LiteralPath $Path -AclObject $Acl -ErrorAction Stop }

function Protect-BackupPathAcl($Path, [bool]$Directory = $false) {
    try {
        Set-BackupPathAcl -Path $Path -Acl (New-ProtectedBackupSecurity -Directory $Directory)
        Assert-TrustedBackupPathAcl -Path $Path -RequireProtected $true
    } catch { throw ('备份 ACL 加固失败: ' + $_.Exception.Message) }
}

function Protect-BackupPathIfSecure($Path, $BackupDir) {
    $root = [System.IO.Path]::GetFullPath((Get-SecureBackupRoot)).TrimEnd('\') + '\'
    $dir = [System.IO.Path]::GetFullPath($BackupDir).TrimEnd('\')
    if ($dir.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and $dir.Substring($root.Length) -notmatch '[\\/]') {
        Protect-BackupPathAcl -Path $Path
    }
}

function Assert-TrustedBackupPackagePath($BackupDir) {
    if ($BackupDir -isnot [string] -or [string]::IsNullOrWhiteSpace($BackupDir)) { throw (New-RestoreCandidateRejectedException '备份包路径无效') }
    $secureRoot = [System.IO.Path]::GetFullPath((Get-SecureBackupRoot)).TrimEnd('\')
    $package = [System.IO.Path]::GetFullPath($BackupDir).TrimEnd('\')
    $prefix = $secureRoot + '\'
    if (-not $package.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or $package.Substring($prefix.Length) -match '[\\/]') {
        throw (New-RestoreCandidateRejectedException '备份包不在受信任的安全备份根直属目录内')
    }
    $appRoot = Split-Path $secureRoot -Parent
    $programData = Split-Path $appRoot -Parent
    Assert-TrustedBackupPathAcl -Path $programData -RequireProtected $false -ParentOnly $true
    Assert-TrustedBackupPathAcl -Path $appRoot -RequireProtected $true
    Assert-TrustedBackupPathAcl -Path $secureRoot -RequireProtected $true
    Assert-TrustedBackupPathAcl -Path $package -RequireProtected $true
    return $package
}

function Initialize-ProtectedBackupDirectory($BackupDir) {
    $secureRoot = [System.IO.Path]::GetFullPath((Get-SecureBackupRoot)).TrimEnd('\')
    $package = [System.IO.Path]::GetFullPath($BackupDir).TrimEnd('\')
    if (-not $package.StartsWith($secureRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $package.Substring($secureRoot.Length + 1) -match '[\\/]') { throw '备份目录不在安全备份根直属目录内' }
    $appRoot = Split-Path $secureRoot -Parent
    $programData = Split-Path $appRoot -Parent
    Assert-TrustedBackupPathAcl -Path $programData -RequireProtected $false -ParentOnly $true
    foreach ($path in @($appRoot, $secureRoot)) {
        if ([System.IO.Directory]::Exists($path)) { Assert-TrustedBackupPathAcl -Path $path -RequireProtected $true }
        else { $null = New-ProtectedBackupDirectory $path; Assert-TrustedBackupPathAcl -Path $path -RequireProtected $true }
    }
    if ([System.IO.Directory]::Exists($package)) { throw '备份目录已存在，拒绝复用' }
    $null = New-ProtectedBackupDirectory $package
    $null = Assert-TrustedBackupPackagePath $package
    return $package
}

function Resolve-TrustedRestoreBackupDirectory($RequestedPath, $LegacyRoot = '') {
    if ($RequestedPath -isnot [string] -or [string]::IsNullOrWhiteSpace($RequestedPath)) { throw 'restore 备份目录参数无效' }
    $secureRoot = [System.IO.Path]::GetFullPath((Get-SecureBackupRoot)).TrimEnd('\')
    $requested = [System.IO.Path]::GetFullPath($RequestedPath).TrimEnd('\')
    $securePrefix = $secureRoot + '\'
    if ($requested.StartsWith($securePrefix, [System.StringComparison]::OrdinalIgnoreCase) -and $requested.Substring($securePrefix.Length) -notmatch '[\\/]') {
        $resolved = $requested
    } elseif ($LegacyRoot -is [string] -and -not [string]::IsNullOrWhiteSpace($LegacyRoot)) {
        $legacy = [System.IO.Path]::GetFullPath($LegacyRoot).TrimEnd('\') + '\'
        if (-not $requested.StartsWith($legacy, [System.StringComparison]::OrdinalIgnoreCase) -or $requested.Substring($legacy.Length) -match '[\\/]') { throw 'restore 路径既不属于安全根也不是受限旧路径' }
        $leaf = [System.IO.Path]::GetFileName($requested)
        if ($leaf -notmatch '^\d{8}_\d{6}$') { throw '旧 GUI restore 路径时间戳无效' }
        $resolved = Join-Path $secureRoot $leaf
    } else { throw 'restore 路径不属于安全备份根' }
    return Assert-TrustedBackupPackagePath $resolved
}

function Test-RegistryBackupFile($Path) {
    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path) -or
        -not [System.IO.File]::Exists($Path) -or (Get-Item -LiteralPath $Path).Length -le 0) {
        return $false
    }
    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return ($content -match '^(Windows Registry Editor Version 5\.00|REGEDIT4)(\r?\n)') -and
            ($content -match '(?m)^\[HKEY_[A-Z_]+\\[^\]]+\]\s*$')
    } catch { return $false }
}

function Get-FileSha256Hex($Path) {
    if ($Path -isnot [string] -or -not [System.IO.File]::Exists($Path) -or (Get-Item -LiteralPath $Path).Length -le 0) {
        throw '备份文件不存在或为空'
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Get-BytesSha256Hex([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -le 0) { throw '备份字节为空' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Open-LockedBackupArtifact($Path) {
    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path)) { throw (New-RestoreCandidateRejectedException '备份文件路径无效') }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        if ($stream.Length -le 0 -or $stream.Length -gt 10MB) { throw (New-RestoreCandidateRejectedException '备份文件为空或过大') }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw '备份文件读取不完整' }
            $offset += $read
        }
        if ($stream.Length -ne $bytes.Length) { throw '备份文件读取期间长度变化' }
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $start = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $encoding = New-Object System.Text.UnicodeEncoding($false, $true, $true)
            $start = 2
        }
        try {
            $text = $encoding.GetString($bytes, $start, $bytes.Length - $start)
        } catch [System.Text.DecoderFallbackException] {
            throw (New-RestoreCandidateRejectedException -Message '备份文件文本编码无效' -InnerException $_.Exception)
        }
        return [pscustomobject]@{ Path=$Path; Stream=$stream; Bytes=$bytes; Text=$text; Sha256=(Get-BytesSha256Hex $bytes) }
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
}

function Close-BackupArtifact($Artifact) {
    if ($null -ne $Artifact -and $null -ne $Artifact.Stream) { $Artifact.Stream.Dispose() }
}

function Read-BackupManifestEntries($ManifestFile) {
    if (-not [System.IO.File]::Exists($ManifestFile)) { return @() }
    $raw = Get-Content -LiteralPath $ManifestFile -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { throw (New-RestoreCandidateRejectedException 'manifest 文件为空') }
    try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch [System.ArgumentException] { throw (New-RestoreCandidateRejectedException -Message ('manifest JSON 语法无效: ' + $_.Exception.Message) -InnerException $_.Exception) }
    Assert-JsonPropertyNamesUnique $raw
    $entries = @($parsed | ForEach-Object { $_ })
    if ($entries.Count -eq 0) { return @() }
    foreach ($entry in $entries) {
        if ($null -eq $entry -or $entry.entry_id -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.entry_id)) {
            throw (New-RestoreCandidateRejectedException 'manifest 条目缺少 entry_id')
        }
    }
    return $entries
}

function Confirm-BackupManifestFile($Path, $ExpectedCount, $ExpectedHash) {
    if ($ExpectedHash -isnot [string] -or $ExpectedHash -cnotmatch '^[0-9A-F]{64}$') { throw 'manifest 预期哈希无效' }
    if ((Get-FileSha256Hex $Path) -cne $ExpectedHash) { throw 'manifest 哈希验证失败' }
    $verified = @(Read-BackupManifestEntries $Path)
    if ($verified.Count -ne $ExpectedCount) { throw 'manifest 条目计数验证失败' }
    return $true
}

function Write-BackupManifestAtomic($BackupDir, $Entries) {
    if ($BackupDir -isnot [string] -or [string]::IsNullOrWhiteSpace($BackupDir)) { throw '备份目录无效' }
    if (-not [System.IO.Directory]::Exists($BackupDir)) { [System.IO.Directory]::CreateDirectory($BackupDir) | Out-Null }
    $manifestFile = Join-Path $BackupDir 'manifest.json'
    $tempFile = Join-Path $BackupDir ('.manifest.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $previousFile = Join-Path $BackupDir 'manifest.previous'
    $failedFile = Join-Path $BackupDir 'manifest.failed'
    $stream = $null
    $writer = $null
    $hadExisting = [System.IO.File]::Exists($manifestFile)
    $committed = $false
    try {
        if ([System.IO.File]::Exists($previousFile)) { throw '发现未处理的 manifest.previous，拒绝覆盖' }
        $json = ConvertTo-Json -InputObject @($Entries) -Depth 100
        $stream = [System.IO.File]::Open($tempFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($true)))
        $writer.Write($json)
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose(); $writer = $null
        $stream.Dispose(); $stream = $null

        Protect-BackupPathIfSecure -Path $tempFile -BackupDir $BackupDir
        $tempHash = Get-FileSha256Hex $tempFile
        $null = Confirm-BackupManifestFile $tempFile @($Entries).Count $tempHash
        if ($hadExisting) {
            [System.IO.File]::Replace($tempFile, $manifestFile, $previousFile)
        } else {
            [System.IO.File]::Move($tempFile, $manifestFile)
        }
        $committed = $true
        Protect-BackupPathIfSecure -Path $manifestFile -BackupDir $BackupDir
        $null = Confirm-BackupManifestFile $manifestFile @($Entries).Count $tempHash
        if ([System.IO.File]::Exists($previousFile)) { [System.IO.File]::Delete($previousFile) }
        return $manifestFile
    } catch {
        $failure = $_
        if ($committed) {
            try {
                if ($hadExisting -and [System.IO.File]::Exists($previousFile)) {
                    if ([System.IO.File]::Exists($failedFile)) { [System.IO.File]::Delete($failedFile) }
                    [System.IO.File]::Replace($previousFile, $manifestFile, $failedFile)
                    if ([System.IO.File]::Exists($failedFile)) { [System.IO.File]::Delete($failedFile) }
                } elseif (-not $hadExisting -and [System.IO.File]::Exists($manifestFile)) {
                    if ([System.IO.File]::Exists($failedFile)) { [System.IO.File]::Delete($failedFile) }
                    [System.IO.File]::Move($manifestFile, $failedFile)
                }
            } catch {
                throw ('manifest 提交失败且回滚失败；请检查 manifest.previous/manifest.failed: ' + $failure.Exception.Message + '; ' + $_.Exception.Message)
            }
        }
        throw $failure
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ([System.IO.File]::Exists($tempFile)) { [System.IO.File]::Delete($tempFile) }
    }
}

function Add-BackupManifestEntryAtomic($BackupDir, $Entry) {
    if ($null -eq $Entry -or $Entry.entry_id -isnot [string] -or [string]::IsNullOrWhiteSpace($Entry.entry_id)) {
        throw '待持久化 manifest 条目缺少 entry_id'
    }
    $manifestFile = Join-Path $BackupDir 'manifest.json'
    $entries = @(Read-BackupManifestEntries $manifestFile)
    if (@($entries | Where-Object { $_.entry_id -ceq $Entry.entry_id }).Count -gt 0) { throw 'manifest entry_id 重复' }
    $entries += $Entry
    $null = Write-BackupManifestAtomic -BackupDir $BackupDir -Entries $entries
    $saved = @(Read-BackupManifestEntries $manifestFile | Where-Object { $_.entry_id -ceq $Entry.entry_id })
    if ($saved.Count -ne 1) { throw 'manifest write-ahead 条目验证失败' }
    return $manifestFile
}

function Update-BackupManifestEntryAtomic($BackupDir, $EntryId, $ExecutionStatus, $Verified) {
    $manifestFile = Join-Path $BackupDir 'manifest.json'
    $entries = @(Read-BackupManifestEntries $manifestFile)
    $matches = @($entries | Where-Object { $_.entry_id -ceq $EntryId })
    if ($matches.Count -ne 1) { throw 'manifest 状态更新目标不唯一' }
    $matches[0].execution_status = $ExecutionStatus
    $matches[0].verified = [bool]$Verified
    $null = Write-BackupManifestAtomic -BackupDir $BackupDir -Entries $entries
    return $manifestFile
}

function Backup-RegistryKey($keyPath, $backupDir, $tag) {
    $regPath = $keyPath -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU'
    $out = Join-Path $backupDir ("$tag.reg")
    if ([System.IO.File]::Exists($out)) { [System.IO.File]::Delete($out) }
    reg export $regPath $out /y 2>$null | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "注册表备份导出失败 (exit=$exitCode): $regPath" }
    if (-not (Test-RegistryBackupFile $out)) {
        throw "注册表备份文件格式无效: $out"
    }
    Protect-BackupPathIfSecure -Path $out -BackupDir $backupDir
    return $out
}

# v1.5.4 P0: 自启项单 Value 备份/恢复 — 恢复粒度必须等于修改粒度
# 旧实现 reg export 整个 Run 键 + reg import: 备份与恢复的范围远大于"删除一个值",
# 期间用户新增/修改的同键其他值会被旧备份覆盖。改为只备份被删 Value 的 Name/Type/Data,
# restore 只写回这一项, 同键其他值完全不动。
function Get-AutostartValueInfo($keyPath, $name) {
    $root = $null; $subPath = $null
    if ($keyPath -match '^HKLM:\\(.*)$') { $root = [Microsoft.Win32.Registry]::LocalMachine; $subPath = $matches[1] }
    elseif ($keyPath -match '^HKCU:\\(.*)$') { $root = [Microsoft.Win32.Registry]::CurrentUser; $subPath = $matches[1] }
    else { return $null }
    $sub = $root.OpenSubKey($subPath)
    if (-not $sub) { return $null }
    try {
        # DoNotExpandEnvironmentNames: 保留 %VAR% 原始形式, 不展开
        $v = $sub.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $v) { return $null }
        return [pscustomobject]@{
            key        = $keyPath
            name       = $name
            value_type = $sub.GetValueKind($name).ToString()
            value      = $v
        }
    } finally { $sub.Close() }
}

function Backup-AutostartValue($keyPath, $name, $backupDir, $tag) {
    $info = Get-AutostartValueInfo $keyPath $name
    if (-not $info) { return $null }
    $out = Join-Path $backupDir ("$tag.autostart.json")
    [System.IO.File]::WriteAllText($out, (ConvertTo-Json -InputObject $info -Depth 100), (New-Object System.Text.UTF8Encoding($true)))
    Protect-BackupPathIfSecure -Path $out -BackupDir $backupDir
    return $out
}

function Write-AutostartValueBackup($Info, $BackupDir, $Tag) {
    if ($null -eq $Info) { return $null }
    $out = Join-Path $BackupDir ("$Tag.autostart.json")
    $json = ConvertTo-Json -InputObject $Info -Depth 100
    [System.IO.File]::WriteAllText($out, $json, (New-Object System.Text.UTF8Encoding($true)))
    if (-not [System.IO.File]::Exists($out) -or (Get-Item -LiteralPath $out).Length -le 0) {
        throw '单值备份文件写入失败'
    }
    Protect-BackupPathIfSecure -Path $out -BackupDir $BackupDir
    return $out
}

function Restore-AutostartValue($info) {
    $propType = switch ($info.value_type) {
        'ExpandString' { 'ExpandString' }
        'DWord'        { 'DWord' }
        'QWord'        { 'QWord' }
        'Binary'       { 'Binary' }
        'MultiString'  { 'MultiString' }
        'String'       { 'String' }
        default        { throw '自启动备份 value_type 不受支持' }
    }
    # v1.5.6: JSON 往返后类型还原 — ConvertTo-Json/ConvertFrom-Json 会把 byte[]/string[] 变成 object[],
    # 直接写注册表会类型错乱 (Binary 尤其明显), 必须强转回原类型
    $val = $info.value
    if ($propType -eq 'Binary') { $val = [byte[]]$info.value }
    elseif ($propType -eq 'MultiString') { $val = [string[]]$info.value }
    New-ItemProperty -Path $info.key -Name $info.name -Value $val -PropertyType $propType -Force | Out-Null
}

