# 动作引擎 (v1.7.0 拆分): 待办清单/授权验证/clean/restore/update
$script:AllowedAutostartRegistrySources = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
)
$script:MaxPendingJsonBytes = 5MB
$script:MaxPendingJsonDepth = 64

# ---------- 9. 待办清单 (v1.2: safe 强制规则 + status 状态机; v1.3: 同 id 去重) ----------
function Test-HitMatcherEvidenceShape {
    param($Hit, [string[]]$AllowedMatchTypes = @('exact','path'))
    if (-not $Hit) { return $false }
    if ($Hit.PSObject.Properties.Name -notcontains 'hit_type' -or
        $Hit.hit_type -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Hit.hit_type) -or
        $Hit.hit_type -notin @('service','autostart','task','process')) {
        return $false
    }
    foreach ($propertyName in @('matched_pattern','matched_type','matched_field')) {
        if ($Hit.PSObject.Properties.Name -notcontains $propertyName) { return $false }
        $value = $Hit.$propertyName
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { return $false }
    }
    if ($Hit.matched_type -notin $AllowedMatchTypes) { return $false }
    $allowedFields = switch ($Hit.hit_type) {
        'service'   { @('service_name','service_display_name') }
        'autostart' { @('autostart_name','autostart_value') }
        'task'      { @('task_name','task_path') }
        'process'   { @('process_name','process_path') }
        default     { @() }
    }
    if ($Hit.matched_field -notin $allowedFields) { return $false }
    if ($Hit.matched_type -eq 'path' -and $Hit.matched_field -notin @('autostart_value','task_path','process_path')) {
        return $false
    }
    return $true
}

function Test-ActionMatchesHitType($Action, $HitType) {
    if ($Action -isnot [string] -or $HitType -isnot [string]) { return $false }
    if ($Action -ceq 'uninstall') {
        return @('service','process','autostart','task') -ccontains $HitType
    }
    switch -CaseSensitive ($HitType) {
        'service'   { return $Action -ceq 'disable_service' }
        'autostart' { return $Action -ceq 'remove_autostart' }
        'task'      { return $Action -ceq 'disable_task' }
        default     { return $false }
    }
}

function Get-StrictNonBlankStringProperty($Object, [string]$PropertyName) {
    if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $PropertyName) { return $null }
    $value = $Object.$PropertyName
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function Test-PositiveScalarProcessId($Value) {
    $integerTypes = @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64])
    $isInteger = $false
    foreach ($integerType in $integerTypes) {
        if ($Value -is $integerType) { $isInteger = $true; break }
    }
    if (-not $isInteger) { return $false }
    return ([int64]$Value -gt 0 -and [int64]$Value -le [int32]::MaxValue)
}

function Test-AllowedAutostartRegistrySource($Source) {
    if ($Source -isnot [string] -or [string]::IsNullOrWhiteSpace($Source)) { return $false }
    foreach ($allowedSource in $script:AllowedAutostartRegistrySources) {
        if ([string]::Equals($Source, $allowedSource, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Remove-LiteralRegistryValueFromKey {
    param($RegistryKey, $Name)
    if ($null -eq $RegistryKey) { throw '注册表键未打开' }
    if ($Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Name)) { throw '注册表值名称无效' }
    $RegistryKey.DeleteValue($Name, $false)
}

function Remove-LiteralAutostartValue {
    param($Source, $Name)
    if (-not (Test-AllowedAutostartRegistrySource $Source)) { throw '自启注册表路径不在白名单' }
    if ($Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Name)) { throw '自启值名称无效' }

    $hive = $null
    $relativePath = $null
    if ($Source.StartsWith('HKCU:\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $hive = [Microsoft.Win32.RegistryHive]::CurrentUser
        $relativePath = $Source.Substring(6)
    } elseif ($Source.StartsWith('HKLM:\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $hive = [Microsoft.Win32.RegistryHive]::LocalMachine
        $relativePath = $Source.Substring(6)
    } else {
        throw '自启注册表 hive 无效'
    }

    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
        $key = $baseKey.OpenSubKey($relativePath, $true)
        if ($null -eq $key) { return $false }
        Remove-LiteralRegistryValueFromKey -RegistryKey $key -Name $Name
        return $true
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function New-AutostartRemovalResult($Status, $Reason, $Backup = '', $Manifest = $null) {
    return [pscustomobject]@{ status=$Status; reason=$Reason; backup=$Backup; manifest=$Manifest }
}

function Invoke-LiteralAutostartRemovalFromKey {
    param($RegistryKey, $Source, $Name, $ExpectedValue, $BackupDir, $Tag, [bool]$RequireArtifactIdentity = $false)
    $artifact = $null
    try {
    if ($null -eq $RegistryKey) { return New-AutostartRemovalResult 'failed' '注册表键未打开' }
    if ($Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Name) -or
        $ExpectedValue -isnot [string] -or [string]::IsNullOrWhiteSpace($ExpectedValue)) {
        return New-AutostartRemovalResult 'skipped' 'pending 自启名称或原始 Value 无效'
    }

    try {
        $matchingNames = @($RegistryKey.GetValueNames() | Where-Object {
            $_ -is [string] -and [string]::Equals($_, $Name, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($matchingNames.Count -ne 1) { return New-AutostartRemovalResult 'skipped' '自启项已不存在或名称不唯一' }
        $literalName = [string]$matchingNames[0]
        $currentValue = $RegistryKey.GetValue($literalName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($currentValue -isnot [string] -or [string]::IsNullOrWhiteSpace($currentValue) -or
            -not [string]::Equals($currentValue, $ExpectedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
            return New-AutostartRemovalResult 'skipped' '自启 Value 已变化，拒绝删除'
        }
        $valueKind = $RegistryKey.GetValueKind($literalName)
    } catch {
        return New-AutostartRemovalResult 'failed' ('读取当前自启值失败: ' + $_.Exception.Message)
    }

    $backupInfo = [pscustomobject]@{
        key = $Source
        name = $literalName
        value_type = $valueKind.ToString()
        value = $currentValue
    }
    try {
        $backup = Write-AutostartValueBackup -Info $backupInfo -BackupDir $BackupDir -Tag $Tag
    } catch {
        return New-AutostartRemovalResult 'failed' ('单值备份失败: ' + $_.Exception.Message)
    }
    if ($backup -isnot [string] -or [string]::IsNullOrWhiteSpace($backup) -or
        -not [System.IO.File]::Exists($backup) -or (Get-Item -LiteralPath $backup).Length -le 0) {
        return New-AutostartRemovalResult 'failed' '单值备份未成功写入有效文件'
    }
    if ($RequireArtifactIdentity) {
        try {
            $backup = Resolve-ValidatedBackupPath $BackupDir $backup
            $artifact = Open-LockedBackupArtifact $backup
            $null = Assert-BackupArtifactIdentity -Type 'autostart' -Artifact $artifact -Key $Source -Name $literalName -ExpectedValue $currentValue
        } catch {
            return New-AutostartRemovalResult 'failed' ('单值备份身份验证失败: ' + $_.Exception.Message) $backup
        }
    }

    $manifestEntry = [pscustomobject]@{
        backup_format_version=1; entry_id=$Tag; type='autostart'; key=$Source; name=$literalName
        target_identity=($Source + '|' + $literalName); backup=$backup
        backup_verified=$true; backup_sha256=$(if ($null -ne $artifact) { $artifact.Sha256 } else { Get-FileSha256Hex $backup })
        execution_status='prepared'; verified=$false; note='restore: 单值恢复'
    }
    try {
        $null = Add-BackupManifestEntryAtomic -BackupDir $BackupDir -Entry $manifestEntry
    } catch {
        return New-AutostartRemovalResult 'failed' ('manifest write-ahead 失败: ' + $_.Exception.Message) $backup
    }
    if ($RequireArtifactIdentity) {
        try { $null = Assert-TrustedBackupPackagePath $BackupDir; Assert-TrustedBackupPathAcl $backup; Assert-TrustedBackupPathAcl (Join-Path $BackupDir 'manifest.json') } catch {
            return New-AutostartRemovalResult 'failed' ('mutation 前备份 ACL 复验失败: ' + $_.Exception.Message) $backup $manifestEntry
        }
    }

    try {
        $matchingNamesAfterBackup = @($RegistryKey.GetValueNames() | Where-Object {
            $_ -is [string] -and [string]::Equals($_, $literalName, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($matchingNamesAfterBackup.Count -ne 1) {
            try { $null = Update-BackupManifestEntryAtomic $BackupDir $Tag 'skipped' $false } catch {}
            return New-AutostartRemovalResult 'skipped' '备份后自启项身份变化，拒绝删除' $backup $manifestEntry
        }
        $valueAfterBackup = $RegistryKey.GetValue($literalName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($valueAfterBackup -isnot [string] -or
            -not [string]::Equals($valueAfterBackup, $ExpectedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
            try { $null = Update-BackupManifestEntryAtomic $BackupDir $Tag 'skipped' $false } catch {}
            return New-AutostartRemovalResult 'skipped' '备份后自启 Value 已变化，拒绝删除' $backup $manifestEntry
        }
        Remove-LiteralRegistryValueFromKey -RegistryKey $RegistryKey -Name $literalName
        $stillPresent = @($RegistryKey.GetValueNames() | Where-Object {
            $_ -is [string] -and [string]::Equals($_, $literalName, [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if ($stillPresent) {
            try { $null = Update-BackupManifestEntryAtomic $BackupDir $Tag 'failed' $false } catch {}
            return New-AutostartRemovalResult 'failed' '字面删除后自启项仍存在' $backup $manifestEntry
        }
        try {
            $null = Update-BackupManifestEntryAtomic $BackupDir $Tag 'success' $true
            $manifestEntry.execution_status = 'success'; $manifestEntry.verified = $true
        } catch {
            return New-AutostartRemovalResult 'failed' ('自启项已删除，但 manifest 状态更新失败: ' + $_.Exception.Message) $backup $manifestEntry
        }
        return New-AutostartRemovalResult 'success' '自启项已完成单值备份并删除' $backup $manifestEntry
    } catch {
        try { $null = Update-BackupManifestEntryAtomic $BackupDir $Tag 'failed' $false } catch {}
        return New-AutostartRemovalResult 'failed' ('字面删除或验证失败: ' + $_.Exception.Message) $backup $manifestEntry
    }
    } finally { Close-BackupArtifact $artifact }
}

function Test-StrictUtcProcessStartTime($Value) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or -not $Value.EndsWith('Z', [System.StringComparison]::Ordinal)) {
        return $false
    }
    $parsed = [datetime]::MinValue
    return [datetime]::TryParseExact(
        $Value,
        'o',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    ) -and $parsed.Kind -eq [System.DateTimeKind]::Utc
}

function Assert-SuspiciousPendingRow {
    param($Row, [switch]$RequireStoppable)
    if ($null -eq $Row) { throw '可疑进程行为空' }
    if ($Row.PSObject.Properties.Name -notcontains 'PID' -or -not (Test-PositiveScalarProcessId $Row.PID)) { throw '可疑进程 PID 必须是正整数标量' }
    $name = Get-StrictNonBlankStringProperty $Row 'Name'
    if ($null -eq $name) { throw '可疑进程 Name 缺失或无效' }
    $path = Get-StrictNonBlankStringProperty $Row 'Path'
    if ($null -eq $path -or -not [System.IO.Path]::IsPathRooted($path)) { throw '可疑进程 Path 缺失或不是绝对路径' }
    $startTimeUtc = Get-StrictNonBlankStringProperty $Row 'StartTimeUtc'
    if ($null -eq $startTimeUtc -or -not (Test-StrictUtcProcessStartTime $startTimeUtc)) { throw '可疑进程 StartTimeUtc 缺失或不是严格 UTC 时间' }
    $status = Get-StrictNonBlankStringProperty $Row 'status'
    if ($null -eq $status -or $status -cnotin @('pending','success','failed','skipped')) { throw '可疑进程 status 无效' }
    if ($Row.PSObject.Properties.Name -notcontains 'CanStop' -or $Row.CanStop -isnot [bool]) { throw '可疑进程 CanStop 必须是 Boolean' }
    if ($RequireStoppable -and $Row.CanStop -ne $true) { throw '可疑进程 CanStop=false，不能加入停止子集' }
    return $true
}

function Build-SuspiciousSubsetPayload($Rows) {
    $selected = @()
    foreach ($row in @($Rows)) {
        $null = Assert-SuspiciousPendingRow $row -RequireStoppable
        if ($row.status -cnotin @('pending','failed')) { throw '仅 pending/failed 可疑进程可以重试停止' }
        $selected += [pscustomobject]@{
            PID=[int]$row.PID; Name=[string]$row.Name; Path=[string]$row.Path; StartTimeUtc=[string]$row.StartTimeUtc
            CanStop=$true; StopBlockReason=''; status=[string]$row.status; Reason=[string]$row.Reason
            'CPU%'=$row.'CPU%'; MemMB=$row.MemMB
        }
    }
    return [pscustomobject]@{
        pending_schema_version=2
        generated=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        actions=@()
        observations=@()
        suspicious=@($selected)
    }
}

function Invoke-LiteralAutostartRemoval {
    param($Source, $Name, $ExpectedValue, $BackupDir, $Tag)
    try { $null = Assert-TrustedBackupPackagePath $BackupDir } catch {
        return New-AutostartRemovalResult 'failed' ('备份 ACL 信任验证失败: ' + $_.Exception.Message)
    }
    if (-not (Test-AllowedAutostartRegistrySource $Source)) {
        return New-AutostartRemovalResult 'skipped' '自启注册表路径不在白名单'
    }
    $hive = $null
    $relativePath = $null
    if ($Source.StartsWith('HKCU:\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $hive = [Microsoft.Win32.RegistryHive]::CurrentUser
        $relativePath = $Source.Substring(6)
    } elseif ($Source.StartsWith('HKLM:\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $hive = [Microsoft.Win32.RegistryHive]::LocalMachine
        $relativePath = $Source.Substring(6)
    } else {
        return New-AutostartRemovalResult 'skipped' '自启注册表 hive 无效'
    }

    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Default)
        $key = $baseKey.OpenSubKey($relativePath, $true)
        if ($null -eq $key) { return New-AutostartRemovalResult 'skipped' '自启注册表键不存在' }
        return Invoke-LiteralAutostartRemovalFromKey -RegistryKey $key -Source $Source -Name $Name -ExpectedValue $ExpectedValue -BackupDir $BackupDir -Tag $Tag -RequireArtifactIdentity $true
    } catch {
        return New-AutostartRemovalResult 'failed' ('打开或处理自启注册表键失败: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Skip-JsonWhitespace([string]$Json, [ref]$Index) {
    while ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -in @([char]0x20,[char]0x09,[char]0x0A,[char]0x0D)) {
        $Index.Value++
    }
}

function Read-JsonStringToken([string]$Json, [ref]$Index) {
    if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne '"') { throw 'JSON 字符串缺少开引号' }
    $Index.Value++
    $builder = New-Object System.Text.StringBuilder
    while ($Index.Value -lt $Json.Length) {
        $character = $Json[$Index.Value]
        $Index.Value++
        if ($character -eq '"') { return $builder.ToString() }
        if ([int]$character -lt 0x20) { throw 'JSON 字符串包含未转义控制字符' }
        if ($character -ne '\') {
            $null = $builder.Append($character)
            continue
        }
        if ($Index.Value -ge $Json.Length) { throw 'JSON 字符串转义不完整' }
        $escaped = $Json[$Index.Value]
        $Index.Value++
        switch ($escaped) {
            '"' { $null = $builder.Append('"') }
            '\' { $null = $builder.Append('\') }
            '/' { $null = $builder.Append('/') }
            'b' { $null = $builder.Append([char]0x08) }
            'f' { $null = $builder.Append([char]0x0C) }
            'n' { $null = $builder.Append([char]0x0A) }
            'r' { $null = $builder.Append([char]0x0D) }
            't' { $null = $builder.Append([char]0x09) }
            'u' {
                if (($Index.Value + 4) -gt $Json.Length) { throw 'JSON Unicode 转义不完整' }
                $hex = $Json.Substring($Index.Value, 4)
                foreach ($hexCharacter in $hex.ToCharArray()) {
                    if ('0123456789abcdefABCDEF'.IndexOf($hexCharacter) -lt 0) { throw 'JSON Unicode 转义无效' }
                }
                $null = $builder.Append([char][Convert]::ToInt32($hex, 16))
                $Index.Value += 4
            }
            default { throw 'JSON 字符串包含未知转义' }
        }
    }
    throw 'JSON 字符串缺少闭引号'
}

function Read-JsonNumberToken([string]$Json, [ref]$Index) {
    if ($Json[$Index.Value] -eq '-') {
        $Index.Value++
        if ($Index.Value -ge $Json.Length) { throw 'JSON 数字不完整' }
    }
    if ($Json[$Index.Value] -eq '0') {
        $Index.Value++
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ge '0' -and $Json[$Index.Value] -le '9') { throw 'JSON 数字包含前导零' }
    } elseif ($Json[$Index.Value] -ge '1' -and $Json[$Index.Value] -le '9') {
        while ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ge '0' -and $Json[$Index.Value] -le '9') { $Index.Value++ }
    } else {
        throw 'JSON 数字无效'
    }
    if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq '.') {
        $Index.Value++
        $fractionStart = $Index.Value
        while ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ge '0' -and $Json[$Index.Value] -le '9') { $Index.Value++ }
        if ($Index.Value -eq $fractionStart) { throw 'JSON 小数部分无效' }
    }
    if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -in @('e','E')) {
        $Index.Value++
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -in @('+','-')) { $Index.Value++ }
        $exponentStart = $Index.Value
        while ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ge '0' -and $Json[$Index.Value] -le '9') { $Index.Value++ }
        if ($Index.Value -eq $exponentStart) { throw 'JSON 指数部分无效' }
    }
}

function Read-JsonValueAndValidatePropertyNames([string]$Json, [ref]$Index, [int]$Depth) {
    Skip-JsonWhitespace $Json $Index
    if ($Index.Value -ge $Json.Length) { throw 'JSON 值缺失' }
    $token = $Json[$Index.Value]
    if ($token -eq '{') {
        $containerDepth = $Depth + 1
        if ($containerDepth -gt $script:MaxPendingJsonDepth) { throw "JSON 容器深度超过上限 $script:MaxPendingJsonDepth" }
        $Index.Value++
        $propertyNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Skip-JsonWhitespace $Json $Index
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq '}') { $Index.Value++; return }
        while ($true) {
            Skip-JsonWhitespace $Json $Index
            $propertyName = Read-JsonStringToken $Json $Index
            if (-not $propertyNames.Add($propertyName)) { throw (New-RestoreCandidateRejectedException "JSON 对象包含重复属性: $propertyName") }
            Skip-JsonWhitespace $Json $Index
            if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne ':') { throw 'JSON 属性缺少冒号' }
            $Index.Value++
            Read-JsonValueAndValidatePropertyNames -Json $Json -Index $Index -Depth $containerDepth
            Skip-JsonWhitespace $Json $Index
            if ($Index.Value -ge $Json.Length) { throw 'JSON 对象未闭合' }
            if ($Json[$Index.Value] -eq '}') { $Index.Value++; return }
            if ($Json[$Index.Value] -ne ',') { throw 'JSON 对象属性之间缺少逗号' }
            $Index.Value++
        }
    }
    if ($token -eq '[') {
        $containerDepth = $Depth + 1
        if ($containerDepth -gt $script:MaxPendingJsonDepth) { throw "JSON 容器深度超过上限 $script:MaxPendingJsonDepth" }
        $Index.Value++
        Skip-JsonWhitespace $Json $Index
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq ']') { $Index.Value++; return }
        while ($true) {
            Read-JsonValueAndValidatePropertyNames -Json $Json -Index $Index -Depth $containerDepth
            Skip-JsonWhitespace $Json $Index
            if ($Index.Value -ge $Json.Length) { throw 'JSON 数组未闭合' }
            if ($Json[$Index.Value] -eq ']') { $Index.Value++; return }
            if ($Json[$Index.Value] -ne ',') { throw 'JSON 数组元素之间缺少逗号' }
            $Index.Value++
        }
    }
    if ($token -eq '"') { $null = Read-JsonStringToken $Json $Index; return }
    if ($token -eq '-' -or ($token -ge '0' -and $token -le '9')) { Read-JsonNumberToken $Json $Index; return }
    foreach ($literal in @('true','false','null')) {
        if (($Index.Value + $literal.Length) -le $Json.Length -and $Json.Substring($Index.Value, $literal.Length) -ceq $literal) {
            $Index.Value += $literal.Length
            return
        }
    }
    throw 'JSON 值 token 无效'
}

function Assert-JsonPropertyNamesUnique([string]$Json) {
    if ([string]::IsNullOrWhiteSpace($Json)) { throw 'JSON 文本为空' }
    $index = 0
    Read-JsonValueAndValidatePropertyNames -Json $Json -Index ([ref]$index) -Depth 0
    Skip-JsonWhitespace $Json ([ref]$index)
    if ($index -ne $Json.Length) { throw 'JSON 根值之后存在多余 token' }
}

function Test-JsonPropertyNamesUnique($Json) {
    if ($Json -isnot [string]) { return $false }
    try {
        Assert-JsonPropertyNamesUnique $Json
        return $true
    } catch {
        return $false
    }
}

function ConvertFrom-StrictPendingJson($Json) {
    if ($Json -isnot [string]) { throw 'pending JSON 必须是字符串' }
    Assert-JsonPropertyNamesUnique $Json
    $convertCommand = Get-Command ConvertFrom-Json -ErrorAction Stop
    if ($convertCommand.Parameters.ContainsKey('DateKind')) {
        return $Json | ConvertFrom-Json -DateKind String -ErrorAction Stop
    }
    return $Json | ConvertFrom-Json -ErrorAction Stop
}

function Test-PendingSchemaSupported($Pending) {
    if ($null -eq $Pending) { return $false }
    $schemaProperty = $null
    foreach ($property in $Pending.PSObject.Properties) {
        if ([string]::Equals($property.Name, 'pending_schema_version', [System.StringComparison]::Ordinal)) {
            $schemaProperty = $property
            break
        }
    }
    if ($null -eq $schemaProperty) { return $false }
    $version = $schemaProperty.Value
    if ($version -isnot [int32] -and $version -isnot [int64]) { return $false }
    return ([int64]2).Equals([int64]$version)
}

function Test-PendingJsonFileLength($Length) {
    $integerTypes = @([byte],[uint16],[uint32],[int16],[int32],[int64])
    $isInteger = $false
    foreach ($integerType in $integerTypes) {
        if ($Length -is $integerType) { $isInteger = $true; break }
    }
    if (-not $isInteger) { return $false }
    return ([int64]$Length -ge 0 -and [int64]$Length -le [int64]$script:MaxPendingJsonBytes)
}

function Assert-PendingPathIsNotReparsePoint($Path) {
    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path)) { throw 'pending 文件路径无效' }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $current = $root
    $relative = $fullPath.Substring($root.Length)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $current = [System.IO.Path]::Combine($current, $segment)
        $attributes = [System.IO.File]::GetAttributes($current)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'pending 文件路径不能包含 reparse point'
        }
    }
}

function Initialize-PendingFileIdentityNativeApi {
    $nativeType = [System.Management.Automation.PSTypeName]'ShushuCleaner.PendingFileIdentityNative'
    if ($null -ne $nativeType.Type) { return }
    $typeDefinition = @'
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ShushuCleaner
{
    public static class PendingFileIdentityNative
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct BY_HANDLE_FILE_INFORMATION
        {
            public uint dwFileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
            public uint dwVolumeSerialNumber;
            public uint nFileSizeHigh;
            public uint nFileSizeLow;
            public uint nNumberOfLinks;
            public uint nFileIndexHigh;
            public uint nFileIndexLow;
        }

        public const uint FILE_NAME_NORMALIZED = 0x0;
        public const uint VOLUME_NAME_DOS = 0x0;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle hFile,
            StringBuilder lpszFilePath,
            uint cchFilePath,
            uint dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandle(
            SafeFileHandle hFile,
            out BY_HANDLE_FILE_INFORMATION lpFileInformation);
    }
}
'@
    $null = Add-Type -TypeDefinition $typeDefinition -ErrorAction Stop
}

function Invoke-GetFinalPathNameByHandleNative {
    param($SafeFileHandle, $Builder, $Capacity, $Flags)
    return [ShushuCleaner.PendingFileIdentityNative]::GetFinalPathNameByHandleW(
        $SafeFileHandle,
        $Builder,
        [uint32]$Capacity,
        [uint32]$Flags
    )
}

function Invoke-GetFileInformationByHandleNative($SafeFileHandle) {
    $information = New-Object ShushuCleaner.PendingFileIdentityNative+BY_HANDLE_FILE_INFORMATION
    $success = [ShushuCleaner.PendingFileIdentityNative]::GetFileInformationByHandle($SafeFileHandle, [ref]$information)
    return [pscustomobject]@{
        success = [bool]$success
        nNumberOfLinks = [uint32]$information.nNumberOfLinks
    }
}

function Get-NormalizedFinalPathFromHandle($Stream) {
    if ($Stream -isnot [System.IO.FileStream] -or $null -eq $Stream.SafeFileHandle -or $Stream.SafeFileHandle.IsInvalid -or $Stream.SafeFileHandle.IsClosed) {
        throw 'pending 文件句柄无效'
    }
    Initialize-PendingFileIdentityNativeApi

    $capacity = 512
    $rawPath = $null
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        $builder = New-Object System.Text.StringBuilder($capacity)
        $length = Invoke-GetFinalPathNameByHandleNative `
            -SafeFileHandle $Stream.SafeFileHandle `
            -Builder $builder `
            -Capacity $builder.Capacity `
            -Flags ([ShushuCleaner.PendingFileIdentityNative]::FILE_NAME_NORMALIZED -bor [ShushuCleaner.PendingFileIdentityNative]::VOLUME_NAME_DOS)
        if ($length -eq 0) {
            throw (New-Object System.ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
        }
        if ($length -lt $builder.Capacity) {
            $rawPath = $builder.ToString()
            break
        }
        if ($length -gt 32767) { throw 'pending 文件最终路径过长' }
        $capacity = [int]$length + 1
    }
    if ([string]::IsNullOrWhiteSpace($rawPath)) { throw '无法读取 pending 文件最终路径' }

    $dosPath = $null
    if ($rawPath.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $dosPath = '\\' + $rawPath.Substring(8)
    } elseif ($rawPath -match '^\\\\\?\\[A-Za-z]:\\') {
        $dosPath = $rawPath.Substring(4)
    } else {
        throw 'pending 文件最终路径不是可安全验证的本地 DOS/UNC 形式'
    }
    $normalized = [System.IO.Path]::GetFullPath($dosPath)
    if ($normalized -notmatch '^[A-Za-z]:\\' -and $normalized -notmatch '^\\\\[^\\]+\\[^\\]+\\') {
        throw 'pending 文件最终路径不是可安全验证的本地 DOS/UNC 形式'
    }
    return $normalized
}

function Test-OpenedPendingFileIdentity {
    param($Stream, $Path)
    try {
        if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
        $expectedPath = [System.IO.Path]::GetFullPath($Path)
        if ($expectedPath -notmatch '^[A-Za-z]:\\' -and $expectedPath -notmatch '^\\\\[^\\]+\\[^\\]+\\') { return $false }
        $actualPath = Get-NormalizedFinalPathFromHandle $Stream
        return [string]::Equals($actualPath, $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-OpenedPendingFileHasSingleLink($Stream) {
    try {
        if ($Stream -isnot [System.IO.FileStream] -or $null -eq $Stream.SafeFileHandle -or $Stream.SafeFileHandle.IsInvalid -or $Stream.SafeFileHandle.IsClosed) {
            return $false
        }
        Initialize-PendingFileIdentityNativeApi
        $result = Invoke-GetFileInformationByHandleNative $Stream.SafeFileHandle
        if ($null -eq $result -or $result.success -isnot [bool] -or -not $result.success) { return $false }
        if ($result.nNumberOfLinks -isnot [uint32] -and $result.nNumberOfLinks -isnot [int32] -and $result.nNumberOfLinks -isnot [int64]) { return $false }
        return ([uint64]$result.nNumberOfLinks -eq [uint64]1)
    } catch {
        return $false
    }
}

function Open-LockedPendingFile($Path) {
    Assert-PendingPathIsNotReparsePoint $Path
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::Read
        )
        if (-not (Test-OpenedPendingFileIdentity -Stream $stream -Path $Path)) {
            throw 'pending 文件句柄身份验证失败，拒绝读取或写回'
        }
        if (-not (Test-OpenedPendingFileHasSingleLink -Stream $stream)) {
            throw 'pending 文件硬链接计数无效，拒绝读取或写回'
        }
        Assert-PendingPathIsNotReparsePoint $Path
        return $stream
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
}

function Open-PendingJsonReadStream($Path) {
    return Open-LockedPendingFile $Path
}

function Read-LimitedPendingJsonStream($Stream) {
    if ($null -eq $Stream -or -not $Stream.CanRead -or -not $Stream.CanSeek) { throw 'pending 文件流不可读或不可定位' }
    $reader = $null
    try {
        $Stream.Position = 0
        $initialLength = $Stream.Length
        if (-not (Test-PendingJsonFileLength $initialLength)) {
            throw "pending 文件过大或长度无效 (上限 $script:MaxPendingJsonBytes 字节)"
        }

        $bomLength = 0
        if ($initialLength -ge 3) {
            $prefix = New-Object byte[] 3
            $prefixRead = $Stream.Read($prefix, 0, 3)
            if ($prefixRead -eq 3 -and $prefix[0] -eq 0xEF -and $prefix[1] -eq 0xBB -and $prefix[2] -eq 0xBF) {
                $bomLength = 3
            } else {
                $Stream.Position = 0
            }
        }

        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $reader = [System.IO.StreamReader]::new($Stream, $utf8, $false, 4096, $true)
        $json = $reader.ReadToEnd()
        $reader.Dispose()
        $reader = $null

        if ($Stream.Length -ne $initialLength -or
            ([System.Text.Encoding]::UTF8.GetByteCount($json) + $bomLength) -ne $initialLength) {
            throw 'pending 文件读取期间长度或内容不一致'
        }
        return $json
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
    }
}

function Get-PendingStreamSha256($Stream) {
    if ($null -eq $Stream -or -not $Stream.CanRead -or -not $Stream.CanSeek) { throw 'pending 文件流不可用于 SHA-256 校验' }
    $sha = $null
    try {
        $Stream.Position = 0
        $initialLength = $Stream.Length
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha.ComputeHash($Stream)
        if ($Stream.Length -ne $initialLength) { throw 'pending 文件 SHA-256 校验期间长度变化' }
        $Stream.Position = 0
        return ([System.BitConverter]::ToString($hashBytes) -replace '-', '')
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
    }
}

function Read-LimitedPendingJsonFile($Path) {
    $stream = $null
    try {
        $stream = Open-LockedPendingFile $Path
        return Read-LimitedPendingJsonStream $stream
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-StrictPendingJsonFile($Path) {
    return ConvertFrom-StrictPendingJson (Read-LimitedPendingJsonFile $Path)
}

function Build-PendingV2Payload {
    param($Source, $Actions, $Observations, $Suspicious)
    $sourceActions = @()
    $sourceObservations = @()
    $sourceSuspicious = @()
    if ($Source -and $Source.actions) { $sourceActions = @($Source.actions) }
    if ($Source -and $Source.observations) { $sourceObservations = @($Source.observations) }
    if ($Source -and $Source.suspicious) { $sourceSuspicious = @($Source.suspicious) }
    if ($PSBoundParameters.ContainsKey('Actions')) { $sourceActions = @($Actions) }
    if ($PSBoundParameters.ContainsKey('Observations')) { $sourceObservations = @($Observations) }
    if ($PSBoundParameters.ContainsKey('Suspicious')) { $sourceSuspicious = @($Suspicious) }

    $generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ($Source -and $Source.PSObject.Properties.Name -contains 'generated') { $generated = $Source.generated }
    $properties = [ordered]@{
        pending_schema_version = 2
        generated = $generated
        actions = @($sourceActions)
        observations = @($sourceObservations)
        suspicious = @($sourceSuspicious)
    }
    if ($Source) {
        foreach ($property in $Source.PSObject.Properties) {
            if ($property.Name -notin @('pending_schema_version','generated','actions','observations','suspicious')) {
                $properties[$property.Name] = $property.Value
            }
        }
    }
    return [pscustomobject]$properties
}

function Write-PendingToLockedStream {
    param($Stream, $Pending)
    if ($null -eq $Stream -or -not $Stream.CanWrite -or -not $Stream.CanSeek) { throw 'pending 文件流不可写或不可定位' }
    $json = ConvertTo-Json -InputObject $Pending -Depth 100
    $bytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($json)
    $null = $Stream.Seek(0, [System.IO.SeekOrigin]::Begin)
    $Stream.SetLength(0)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush($true)
}

function Get-CurrentPendingMatchValue($Pending) {
    $hitType = Get-StrictNonBlankStringProperty $Pending 'hit_type'
    $matchedField = Get-StrictNonBlankStringProperty $Pending 'matched_field'
    if ($null -eq $hitType -or $null -eq $matchedField) { return $null }

    switch ($hitType) {
        'service' {
            $serviceName = Get-StrictNonBlankStringProperty $Pending 'service_name'
            if ($null -eq $serviceName) { return $null }
            try { $services = @(Get-Service -Name $serviceName -ErrorAction SilentlyContinue) } catch { return $null }
            if ($services.Count -ne 1 -or $null -eq $services[0]) { return $null }
            $currentName = Get-StrictNonBlankStringProperty $services[0] 'Name'
            if ($null -eq $currentName -or -not [string]::Equals($currentName, $serviceName, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
            if ($matchedField -eq 'service_name') { return $currentName }
            if ($matchedField -eq 'service_display_name') { return Get-StrictNonBlankStringProperty $services[0] 'DisplayName' }
            return $null
        }
        'autostart' {
            $source = Get-StrictNonBlankStringProperty $Pending 'autostart_source'
            $name = Get-StrictNonBlankStringProperty $Pending 'autostart_name'
            if ($null -eq $source -or $null -eq $name -or -not (Test-AllowedAutostartRegistrySource $source)) { return $null }
            try { $keys = @(Get-ItemProperty -Path $source -ErrorAction SilentlyContinue) } catch { return $null }
            if ($keys.Count -ne 1 -or $null -eq $keys[0]) { return $null }
            $properties = @($keys[0].PSObject.Properties | Where-Object {
                $_.Name -is [string] -and [string]::Equals($_.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)
            })
            if ($properties.Count -ne 1) { return $null }
            $currentName = [string]$properties[0].Name
            $storedValue = Get-StrictNonBlankStringProperty $Pending 'autostart_value'
            if ($null -eq $storedValue) { return $null }
            try { $currentValue = $properties[0].Value } catch { return $null }
            if ($currentValue -isnot [string] -or [string]::IsNullOrWhiteSpace($currentValue)) { return $null }
            if (-not [string]::Equals($currentValue, $storedValue, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
            if ($matchedField -eq 'autostart_name') { return $currentName }
            if ($matchedField -eq 'autostart_value') { return $currentValue }
            return $null
        }
        'task' {
            $fullTaskPath = Get-StrictNonBlankStringProperty $Pending 'task_path'
            if ($null -eq $fullTaskPath -or -not $fullTaskPath.StartsWith('\')) { return $null }
            $lastSeparator = $fullTaskPath.LastIndexOf('\')
            if ($lastSeparator -lt 0 -or $lastSeparator -ge ($fullTaskPath.Length - 1)) { return $null }
            $taskFolder = $fullTaskPath.Substring(0, $lastSeparator + 1)
            $taskName = $fullTaskPath.Substring($lastSeparator + 1)
            if ([string]::IsNullOrWhiteSpace($taskFolder) -or [string]::IsNullOrWhiteSpace($taskName)) { return $null }
            try { $tasks = @(Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue) } catch { return $null }
            if ($tasks.Count -ne 1 -or $null -eq $tasks[0]) { return $null }
            $currentName = Get-StrictNonBlankStringProperty $tasks[0] 'TaskName'
            $currentFolder = Get-StrictNonBlankStringProperty $tasks[0] 'TaskPath'
            if ($null -eq $currentName -or $null -eq $currentFolder) { return $null }
            $currentFullPath = $currentFolder + $currentName
            if (-not [string]::Equals($currentFullPath, $fullTaskPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
            if ($matchedField -eq 'task_name') { return $currentName }
            if ($matchedField -eq 'task_path') { return $currentFullPath }
            return $null
        }
        'process' {
            if ($Pending.PSObject.Properties.Name -notcontains 'process_id' -or -not (Test-PositiveScalarProcessId $Pending.process_id)) { return $null }
            $processId = [int]$Pending.process_id
            try { $processes = @(Get-Process -Id $processId -ErrorAction SilentlyContinue) } catch { return $null }
            if ($processes.Count -ne 1 -or $null -eq $processes[0]) { return $null }
            if ($processes[0].PSObject.Properties.Name -notcontains 'Id' -or
                -not (Test-PositiveScalarProcessId $processes[0].Id) -or
                [int]$processes[0].Id -ne $processId) { return $null }
            $storedPath = Get-StrictNonBlankStringProperty $Pending 'process_path'
            if ($null -eq $storedPath) { return $null }
            try { $currentPath = $processes[0].Path } catch { return $null }
            if ($currentPath -isnot [string] -or [string]::IsNullOrWhiteSpace($currentPath)) { return $null }
            if (-not [string]::Equals($currentPath, $storedPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
            if ($matchedField -eq 'process_name') {
                $storedName = Get-StrictNonBlankStringProperty $Pending 'process_name'
                $currentName = Get-StrictNonBlankStringProperty $processes[0] 'Name'
                if ($null -eq $storedName -or $null -eq $currentName) { return $null }
                if (-not [string]::Equals((Normalize-ProcessName $currentName), (Normalize-ProcessName $storedName), [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
                return $currentName
            }
            if ($matchedField -eq 'process_path') {
                return $currentPath
            }
            return $null
        }
        default { return $null }
    }
}

function Get-PendingIdentityKey($Item) {
    $identity = [ordered]@{
        id                   = $Item.id
        hit_type             = $Item.hit_type
        action               = $Item.action
        service_name         = $Item.service_name
        service_display_name = $Item.service_display_name
        autostart_source     = $Item.autostart_source
        autostart_name       = $Item.autostart_name
        autostart_value      = $Item.autostart_value
        task_name            = $Item.task_name
        task_path            = $Item.task_path
        process_name         = $Item.process_name
        process_id           = $Item.process_id
        process_path         = $Item.process_path
        matched_pattern      = $Item.matched_pattern
        matched_type         = $Item.matched_type
        matched_field        = $Item.matched_field
    }
    return ConvertTo-Json -InputObject $identity -Compress -Depth 4
}

function Save-PendingActions($Hits, $Suspicious, $ScanHealth = $script:ScanHealth, $ScanWarnings = $script:ScanWarnings) {
    $actions = @()
    $observations = @()
    $seenActionIds = @{}
    $seenObservationIds = @{}
    foreach ($h in $Hits) {
        # v1.5.6 数据模型: actions(可执行) / observations(仅观察) 分流
        # 可执行 = 危险动作 + Boolean true safe/tested + 窄匹配证据; 其余一律进 observations
        $safeAllowed = ($h.safe -is [bool]) -and ($h.safe -eq $true)
        $testedAllowed = $h.evidence -and
            ($h.evidence.PSObject.Properties.Name -contains 'tested') -and
            ($h.evidence.tested -is [bool]) -and
            ($h.evidence.tested -eq $true)
        $actionAllowed = ($h.PSObject.Properties.Name -contains 'action') -and
            ($h.action -is [string]) -and
            (-not [string]::IsNullOrWhiteSpace($h.action)) -and
            ($h.action -in $script:DangerousActions)
        $hasNarrowEvidence = Test-HitMatcherEvidenceShape $h
        $hasBroadEvidence = Test-HitMatcherEvidenceShape $h -AllowedMatchTypes @('contains','regex')
        $actionHitTypeAllowed = Test-ActionMatchesHitType $h.action $h.hit_type
        $healthKey = if ($h.hit_type -is [string]) {
            switch -CaseSensitive ($h.hit_type) {
                'service' { 'services' }
                'task' { 'tasks' }
                default { '' }
            }
        } else { '' }
        $categoryComplete = [string]::IsNullOrEmpty($healthKey) -or
            ($ScanHealth -and [string]$ScanHealth.$healthKey -ceq 'complete')
        $executable = $actionAllowed -and
            $safeAllowed -and
            $testedAllowed -and
            $hasNarrowEvidence -and
            $actionHitTypeAllowed -and
            $categoryComplete

        # action / observation 分开去重, 防止宽匹配观察压制同目标的窄匹配动作
        $dedupeKey = Get-PendingIdentityKey $h
        $seenIds = if ($executable) { $seenActionIds } else { $seenObservationIds }
        if ($seenIds.ContainsKey($dedupeKey)) { continue }
        $seenIds[$dedupeKey] = $true

        if (-not $executable) {
            # v1.5.6: 观察条目 — 记录为什么不能自动处理 (GUI 展示为 disabled checkbox)
            $obsReason = if ($h.action -eq 'none' -or $h.action -eq 'investigate') { '动作仅观察/不处理' }
                elseif (-not $safeAllowed) { 'safe=false 或类型无效, 不允许自动处理' }
                elseif (-not $testedAllowed) { '未实测 (tested=false 或类型无效), 仅观察' }
                elseif ($actionAllowed -and $hasNarrowEvidence -and -not $actionHitTypeAllowed) { '动作与命中类型不匹配，禁止自动处理' }
                elseif (-not $categoryComplete) { '扫描信息不完整，禁止自动处理' }
                elseif ($actionAllowed -and $hasBroadEvidence) { '实际命中为宽匹配 (contains/regex)，禁止自动处理' }
                elseif ($actionAllowed -and -not $hasNarrowEvidence) { '匹配来源缺失或无效，禁止自动处理' }
                else { '动作不允许自动处理, 仅观察' }
            $observations += [pscustomobject]@{
                id        = $h.id
                vendor    = $h.vendor
                name_cn   = $h.name_cn
                action    = $h.action
                hit_type  = $h.hit_type
                detail    = $h.detail
                reason_cn = $h.reason_cn
                service_name      = $h.service_name
                autostart_source  = $h.autostart_source
                autostart_name    = $h.autostart_name
                autostart_value   = $h.autostart_value
                task_path         = $h.task_path
                process_name      = $h.process_name
                process_id        = $h.process_id
                process_path      = $h.process_path
                matched_pattern   = $h.matched_pattern
                matched_type      = $h.matched_type
                matched_field     = $h.matched_field
                safe      = $h.safe
                obs_reason = $obsReason
            }
            continue
        }

        # 跳过已经是目标状态的条目 (仅可执行条目需要, 观察条目不动系统状态)
        $skip = $false
        if ($h.action -eq 'disable_service' -and $h.service_name) {
            $svc = Get-Service -Name $h.service_name -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled' -and $svc.Status -eq 'Stopped') { $skip = $true }
        }
        elseif ($h.action -eq 'disable_task' -and $h.task_path) {
            $separator = $h.task_path.LastIndexOf('\')
            if ($separator -lt 0 -or $separator -ge ($h.task_path.Length - 1)) { continue }
            $taskName = $h.task_path.Substring($separator + 1)
            $taskFolder = if ($separator -eq 0) { '\' } else { $h.task_path.Substring(0, $separator + 1) }
            $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
            if ($task -and $task.State -eq 'Disabled') { $skip = $true }
        }
        elseif ($h.action -eq 'remove_autostart' -and $h.autostart_source -and $h.autostart_name) {
            $key = Get-ItemProperty $h.autostart_source -ErrorAction SilentlyContinue
            if (-not $key -or -not ($key.PSObject.Properties | Where-Object { $_.Name -eq $h.autostart_name })) { $skip = $true }
        }
        if ($skip) { continue }

        $actions += [pscustomobject]@{
            id        = $h.id
            vendor    = $h.vendor
            name_cn   = $h.name_cn
            action    = $h.action
            hit_type  = $h.hit_type
            detail    = $h.detail
            reason_cn = $h.reason_cn
            service_name      = $h.service_name
            autostart_source  = $h.autostart_source
            autostart_name    = $h.autostart_name
            autostart_value   = $h.autostart_value
            task_path         = $h.task_path
            process_name      = $h.process_name
            process_id        = $h.process_id
            process_path      = $h.process_path
            matched_pattern   = $h.matched_pattern
            matched_type      = $h.matched_type
            matched_field     = $h.matched_field
            safe      = $h.safe
            # v1.2 状态机: pending / success / failed / skipped / manual_required
            status    = 'pending'
        }
    }

    # 变量方式构造数组 (if/else 表达式输出空数组会被当成 $null, 序列化成 {} 而非 [])
    $suspArr = @()
    if ($Suspicious) {
        $suspArr = @($Suspicious | ForEach-Object {
            $canStop = ($_.CanStop -is [bool]) -and $_.CanStop
            $stopBlockReason = if ($_.StopBlockReason -is [string]) { $_.StopBlockReason } else { '' }
            [pscustomobject]@{
                PID=$_.PID; Name=$_.Name; 'CPU%'=$_.'CPU%'; MemMB=$_.MemMB; Path=$_.Path; Reason=$_.Reason
                StartTimeUtc=$_.StartTimeUtc; CanStop=[bool]$canStop; StopBlockReason=$stopBlockReason; status='pending'
            }
        })
    }
    $payload = [pscustomobject]@{
        pending_schema_version = 2
        generated     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        actions       = $actions
        observations  = $observations
        suspicious    = $suspArr
        scan_health   = $ScanHealth
        scan_warnings = @($ScanWarnings)
    }
    # 用 -InputObject 强制序列化, 避免管道展开导致空数组写空文件
    $json = ConvertTo-Json -InputObject $payload -Depth 100
    [System.IO.File]::WriteAllText($script:PendingFile, $json, (New-Object System.Text.UTF8Encoding($true)))
}

# ---------- 10. clean 模式 ----------
# v1.5.3 P0: 提权后重新验证授权动作 (不信任 pending_actions.json)
# pending_actions.json 在 scan 与管理员 clean 之间可能被人为修改,
# clean 必须按当前特征库重新确认: id 存在 / tested=true / safe=true / action 匹配 / target 匹配
function Test-PendingActionAuthorized($p, $profiles) {
    if ($null -eq $p -or $null -eq $profiles) { return $false }
    foreach ($propertyName in @('id','hit_type','action','status','matched_pattern','matched_type','matched_field')) {
        if ($null -eq (Get-StrictNonBlankStringProperty $p $propertyName)) { return $false }
    }
    if ($p.status -cnotin @('pending','failed')) { return $false }
    if ($p.action -cnotin $script:DangerousActions) { return $false }
    if (-not (Test-HitMatcherEvidenceShape $p)) { return $false }

    if ($profiles.PSObject.Properties.Name -notcontains 'profiles') { return $false }
    $rules = @($profiles.profiles | Where-Object {
        $_ -and $_.PSObject.Properties.Name -contains 'id' -and
        $_.id -is [string] -and -not [string]::IsNullOrWhiteSpace($_.id) -and $_.id -ceq $p.id
    })
    if ($rules.Count -ne 1) { return $false }
    $rule = $rules[0]

    if ($rule.PSObject.Properties.Name -notcontains 'safe' -or $rule.safe -isnot [bool] -or $rule.safe -ne $true) { return $false }
    if ($rule.PSObject.Properties.Name -notcontains 'evidence' -or $null -eq $rule.evidence) { return $false }
    if ($rule.evidence.PSObject.Properties.Name -notcontains 'tested' -or $rule.evidence.tested -isnot [bool] -or $rule.evidence.tested -ne $true) { return $false }

    $declaredAction = Get-ActionFor $rule.actions $p.hit_type
    if ($declaredAction -isnot [string] -or [string]::IsNullOrWhiteSpace($declaredAction)) { return $false }
    if ($declaredAction -cnotin $script:DangerousActions -or $p.action -cne $declaredAction) { return $false }

    if ($rule.PSObject.Properties.Name -notcontains 'detect' -or $null -eq $rule.detect) { return $false }
    $detectProperty = switch ($p.hit_type) {
        'service' { 'services' }
        'autostart' { 'autostarts' }
        'task' { 'tasks' }
        'process' { 'processes' }
        default { return $false }
    }
    if ($rule.detect.PSObject.Properties.Name -notcontains $detectProperty) { return $false }
    $sameMatchers = @($rule.detect.$detectProperty | Where-Object {
        $normalized = Normalize-DetectItem $_
        $normalized.match -is [string] -and $normalized.type -is [string] -and
        $normalized.match -ceq $p.matched_pattern -and $normalized.type -ceq $p.matched_type
    })
    if ($sameMatchers.Count -lt 1) { return $false }

    $currentValue = Get-CurrentPendingMatchValue $p
    if ($currentValue -isnot [string] -or [string]::IsNullOrWhiteSpace($currentValue)) { return $false }
    $savedMatcher = [pscustomobject]@{ match = $p.matched_pattern; type = $p.matched_type }
    if ($p.hit_type -eq 'process' -and $p.matched_field -eq 'process_name') {
        return [bool](Test-ProcessDetectMatch $currentValue $savedMatcher)
    }
    return [bool](Test-DetectMatch $currentValue $savedMatcher)
}

function Test-SelectedPendingActionAuthorized($Pending, $Profiles) {
    if (Test-PendingActionAuthorized $Pending $Profiles) { return $true }
    if ($null -ne $Pending) { $Pending.status = 'skipped' }
    Write-Host '  跳过: 执行前最终授权失败，当前系统状态或特征证据已变化。' -ForegroundColor Red
    return $false
}

# v1.2: 服务启动类型映射 (sc.exe 参数 vs StartType 枚举)
function Convert-StartTypeToSc($startType) {
    switch ($startType.ToString()) {
        'Automatic' { return 'auto' }
        'Manual'    { return 'demand' }
        'Disabled'  { return 'disabled' }
        'Boot'      { return 'boot' }
        'System'    { return 'system' }
        default     { return 'disabled' }
    }
}

# 旧 manifest 兼容: 数字枚举 0=Boot 1=System 2=Automatic 3=Manual 4=Disabled
function Convert-NumberToSc($n) {
    switch ([int]$n) {
        0 { return 'boot' }
        1 { return 'system' }
        2 { return 'auto' }
        3 { return 'demand' }
        4 { return 'disabled' }
        default { return 'disabled' }
    }
}

# 采集服务备份信息: 启动类型(sc 格式/显示格式) + 运行状态 + DelayedAutoStart
function Get-ServiceBackupInfo($srvName) {
    $svc = Get-Service -Name $srvName -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $startType = $svc.StartType.ToString()
    $delayed = 0
    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$srvName"
        $delayed = (Get-ItemProperty $regPath -Name DelayedAutostart -ErrorAction Stop).DelayedAutostart
    } catch { $delayed = 0 }
    return [pscustomobject]@{
        start_type_sc      = Convert-StartTypeToSc $startType
        start_type_display = $startType
        status             = $svc.Status.ToString()
        delayed_autostart  = $delayed
    }
}

function Test-ServiceBackupInfo($Info) {
    if ($null -eq $Info) { return $false }
    if ($Info.start_type_sc -isnot [string] -or $Info.start_type_sc -cnotin @('auto','demand','disabled','boot','system')) { return $false }
    if ($Info.start_type_display -isnot [string] -or [string]::IsNullOrWhiteSpace($Info.start_type_display)) { return $false }
    if ($Info.status -isnot [string] -or $Info.status -cnotin @('Running','Stopped')) { return $false }
    return $true
}

function Normalize-TaskPathIdentity($TaskPath) {
    if ($TaskPath -isnot [string] -or [string]::IsNullOrWhiteSpace($TaskPath)) { throw (New-RestoreCandidateRejectedException '任务目标身份无效') }
    $normalized = $TaskPath.Trim() -replace '/','\' -replace '\\+','\'
    if (-not $normalized.StartsWith('\')) { $normalized = '\' + $normalized }
    if ($normalized.Length -le 1 -or $normalized.EndsWith('\') -or $normalized -match '[\r\n]') { throw (New-RestoreCandidateRejectedException '任务目标身份无效') }
    return $normalized
}

function Assert-BackupArtifactIdentity {
    param($Type, $Path, $Artifact, $TargetIdentity, $Key = '', $Name = '', $ExpectedValue = $null)
    $ownedArtifact = $false
    if ($null -eq $Artifact) {
        $Artifact = Open-LockedBackupArtifact $Path
        $ownedArtifact = $true
    }
    try {
    $content = $Artifact.Text
    switch -CaseSensitive ($Type) {
        'service' {
            if ($TargetIdentity -isnot [string] -or $TargetIdentity -cnotmatch '^[A-Za-z0-9_.]+$' -or
                $content -notmatch '^(Windows Registry Editor Version 5\.00|REGEDIT4)(\r?\n)' -or
                $content -notmatch '(?m)^\[HKEY_[A-Z_]+\\[^\]]+\]\s*$') {
                throw (New-RestoreCandidateRejectedException '服务备份格式或目标身份无效')
            }
            $escapedName = [regex]::Escape($TargetIdentity)
            if ($content -notmatch "(?mi)^\[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\$escapedName\]\s*$") {
                throw (New-RestoreCandidateRejectedException '服务备份目标身份不匹配')
            }
            return [pscustomobject]@{ Type='service'; Info=$null; Xml=$null }
        }
        'task' {
            $normalizedTarget = Normalize-TaskPathIdentity $TargetIdentity
            $xmlDoc = New-Object System.Xml.XmlDocument
            try { $xmlDoc.LoadXml($content) } catch [System.Xml.XmlException] { throw (New-RestoreCandidateRejectedException -Message ('任务备份格式无效: ' + $_.Exception.Message) -InnerException $_.Exception) }
            if ($null -eq $xmlDoc.DocumentElement -or $xmlDoc.DocumentElement.LocalName -cne 'Task') { throw (New-RestoreCandidateRejectedException '任务备份格式无效') }
            $uriNode = $xmlDoc.SelectSingleNode("//*[local-name()='RegistrationInfo']/*[local-name()='URI']")
            if ($null -eq $uriNode -or
                -not [string]::Equals((Normalize-TaskPathIdentity $uriNode.InnerText), $normalizedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw (New-RestoreCandidateRejectedException '任务备份目标身份不匹配')
            }
            return [pscustomobject]@{ Type='task'; Info=$null; Xml=$xmlDoc.OuterXml; TaskFingerprint=(Get-TaskDefinitionFingerprint $xmlDoc.OuterXml) }
        }
        'autostart' {
            if ($Key -isnot [string] -or [string]::IsNullOrWhiteSpace($Key) -or $Name -isnot [string] -or [string]::IsNullOrWhiteSpace($Name)) {
                throw (New-RestoreCandidateRejectedException '自启动目标身份无效')
            }
            try { $info = $content | ConvertFrom-Json -ErrorAction Stop }
            catch [System.ArgumentException] { throw (New-RestoreCandidateRejectedException -Message ('自启动备份 JSON 语法无效: ' + $_.Exception.Message) -InnerException $_.Exception) }
            Assert-JsonPropertyNamesUnique $content
            Assert-AutostartArtifactSchema $info
            if (-not [string]::Equals($info.key, $Key, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($info.name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw (New-RestoreCandidateRejectedException '自启动备份目标身份不匹配')
            }
            if ($null -ne $ExpectedValue -and
                ($info.value -isnot [string] -or -not [string]::Equals($info.value, $ExpectedValue, [System.StringComparison]::OrdinalIgnoreCase))) {
                throw (New-RestoreCandidateRejectedException '自启动备份 Value 与目标不匹配')
            }
            return [pscustomobject]@{ Type='autostart'; Info=$info; Xml=$null }
        }
        default { throw (New-RestoreCandidateRejectedException '备份 artifact 类型不受支持') }
    }
    } finally {
        if ($ownedArtifact) { Close-BackupArtifact $Artifact }
    }
}

function Test-StrictInteger($Value) {
    return ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64])
}

function Assert-AutostartArtifactSchema($Info) {
    if ($null -eq $Info) { throw (New-RestoreCandidateRejectedException '自启动备份对象为空') }
    $allowed = @('key','name','value_type','value')
    foreach ($property in $Info.PSObject.Properties) { if ($property.Name -cnotin $allowed) { throw (New-RestoreCandidateRejectedException '自启动备份包含未知字段') } }
    foreach ($field in @('key','name','value_type')) {
        if ($Info.PSObject.Properties.Name -cnotcontains $field -or $Info.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($Info.$field)) {
            throw (New-RestoreCandidateRejectedException "自启动备份字段 $field 无效")
        }
    }
    if ($Info.PSObject.Properties.Name -cnotcontains 'value') { throw (New-RestoreCandidateRejectedException '自启动备份缺少 value') }
    if ($Info.value_type -cnotin @('String','ExpandString','DWord','QWord','Binary','MultiString')) { throw (New-RestoreCandidateRejectedException '自启动备份 value_type 不受支持') }
    switch -CaseSensitive ($Info.value_type) {
        { $_ -in @('String','ExpandString') } { if ($Info.value -isnot [string]) { throw (New-RestoreCandidateRejectedException '自启动字符串 value 类型无效') } }
        { $_ -in @('DWord','QWord') } { if (-not (Test-StrictInteger $Info.value)) { throw (New-RestoreCandidateRejectedException '自启动整数 value 类型无效') } }
        'Binary' { foreach ($item in @($Info.value)) { if (-not (Test-StrictInteger $item) -or [int64]$item -lt 0 -or [int64]$item -gt 255) { throw (New-RestoreCandidateRejectedException '自启动 Binary value 无效') } } }
        'MultiString' { foreach ($item in @($Info.value)) { if ($item -isnot [string]) { throw (New-RestoreCandidateRejectedException '自启动 MultiString value 无效') } } }
    }
}

function Get-TaskDefinitionFingerprint($Xml) {
    if ($Xml -isnot [string] -or [string]::IsNullOrWhiteSpace($Xml)) { throw (New-RestoreCandidateRejectedException '任务 XML 为空') }
    $doc = New-Object System.Xml.XmlDocument
    try { $doc.LoadXml($Xml) } catch [System.Xml.XmlException] { throw (New-RestoreCandidateRejectedException -Message '任务 XML 无效' -InnerException $_.Exception) }
    $uri = $doc.SelectSingleNode("//*[local-name()='RegistrationInfo']/*[local-name()='URI']")
    if ($null -eq $uri -or $null -eq $doc.DocumentElement -or $doc.DocumentElement.LocalName -cne 'Task') { throw (New-RestoreCandidateRejectedException '任务 XML 缺少关键定义') }
    $identity = (Normalize-TaskPathIdentity $uri.InnerText) + '|' + $doc.OuterXml
    return Get-BytesSha256Hex ((New-Object System.Text.UTF8Encoding($false)).GetBytes($identity))
}

function Test-AutostartValueEqual($Expected, $Actual) {
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    if ($Expected.value_type -cne $Actual.value_type -or
        -not [string]::Equals($Expected.key, $Actual.key, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($Expected.name, $Actual.name, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    return ((ConvertTo-Json -InputObject $Expected.value -Compress -Depth 20) -ceq (ConvertTo-Json -InputObject $Actual.value -Compress -Depth 20))
}

function Invoke-ServiceConfigDisable($ServiceName) {
    sc.exe config $ServiceName start= disabled | Out-Null
    sc.exe stop $ServiceName | Out-Null
}

function Invoke-ServiceDisableAction {
    param($Pending, $BackupDir, $Tag)
    $artifact = $null
    try {
    $srvName = $Pending.service_name
    if ($srvName -isnot [string] -or $srvName -cnotmatch '^[A-Za-z0-9_.]+$') {
        return [pscustomobject]@{ status='skipped'; reason='服务名无效'; backup=''; manifest=$null }
    }
    try { $null = Assert-TrustedBackupPackagePath $BackupDir } catch {
        return [pscustomobject]@{ status='failed'; reason=('备份 ACL 信任验证失败: ' + $_.Exception.Message); backup=''; manifest=$null }
    }
    try {
        $info = Get-ServiceBackupInfo $srvName
        if (-not (Test-ServiceBackupInfo $info)) { throw '服务原始配置不完整，无法安全备份' }
        $bak = Backup-RegistryKey "HKLM:\SYSTEM\CurrentControlSet\Services\$srvName" $BackupDir $Tag
        $bak = Resolve-ValidatedBackupPath $BackupDir $bak
        $artifact = Open-LockedBackupArtifact $bak
        $null = Assert-BackupArtifactIdentity -Type 'service' -Artifact $artifact -TargetIdentity $srvName
    } catch {
        return [pscustomobject]@{ status='failed'; reason=('服务备份失败: ' + $_.Exception.Message); backup=''; manifest=$null }
    }

    $manifest = [pscustomobject]@{
        backup_format_version=1; entry_id=$Tag; type='service'; name=$srvName; target_identity=$srvName
        backup=$bak; backup_verified=$true; backup_sha256=$artifact.Sha256
        start_type_sc=$info.start_type_sc; start_type_display=$info.start_type_display
        status=$info.status; delayed_autostart=$info.delayed_autostart
        execution_status='prepared'; verified=$false; note='restore: sc config <name> start= <start_type_sc>'
    }
    try { $null = Add-BackupManifestEntryAtomic -BackupDir $BackupDir -Entry $manifest } catch {
        return [pscustomobject]@{ status='failed'; reason=('manifest write-ahead 失败: ' + $_.Exception.Message); backup=$bak; manifest=$null }
    }
    try { $null = Assert-TrustedBackupPackagePath $BackupDir; Assert-TrustedBackupPathAcl $bak; Assert-TrustedBackupPathAcl (Join-Path $BackupDir 'manifest.json') } catch {
        return [pscustomobject]@{ status='failed'; reason=('mutation 前备份 ACL 复验失败: ' + $_.Exception.Message); backup=$bak; manifest=$manifest }
    }
    try {
        Invoke-ServiceConfigDisable -ServiceName $srvName
        $after = Get-Service -Name $srvName -ErrorAction SilentlyContinue
        if ($after -and $after.StartType -eq 'Disabled') {
            try { $null = Update-BackupManifestEntryAtomic $BackupDir $Tag 'success' $true } catch {
                return [pscustomobject]@{ status='failed'; reason=('服务已修改，但 manifest 状态更新失败: ' + $_.Exception.Message); backup=$bak; manifest=$manifest }
            }
            $manifest.execution_status = 'success'; $manifest.verified = $true
            $note = if ($after.Status -eq 'Running') { '已禁用但进程仍在运行(重启后消失)' } else { '已禁用并停止' }
            return [pscustomobject]@{ status='success'; reason=$note; backup=$bak; manifest=$manifest }
        }
        $actual = if ($after) { $after.StartType.ToString() } else { '服务不存在' }
        try { $null = Update-BackupManifestEntryAtomic $BackupDir $Tag 'failed' $false } catch {}
        return [pscustomobject]@{ status='failed'; reason="当前 StartType=$actual"; backup=$bak; manifest=$manifest }
    } catch {
        try { $null = Update-BackupManifestEntryAtomic $BackupDir $Tag 'failed' $false } catch {}
        return [pscustomobject]@{ status='failed'; reason=('服务修改或验证失败: ' + $_.Exception.Message); backup=$bak; manifest=$manifest }
    }
    } finally { Close-BackupArtifact $artifact }
}

function Write-TaskXmlBackup($Xml, $BackupDir, $Tag) {
    if ($Xml -isnot [string] -or [string]::IsNullOrWhiteSpace($Xml)) { throw '计划任务 XML 为空' }
    try { [xml]$parsed = $Xml } catch { throw ('计划任务 XML 无效: ' + $_.Exception.Message) }
    if ($null -eq $parsed.DocumentElement -or $parsed.DocumentElement.LocalName -cne 'Task') { throw '计划任务 XML 根节点无效' }
    $out = Join-Path $BackupDir ("$Tag.xml")
    [System.IO.File]::WriteAllText($out, $Xml, (New-Object System.Text.UTF8Encoding($true)))
    if (-not [System.IO.File]::Exists($out) -or (Get-Item -LiteralPath $out).Length -le 0) { throw '计划任务 XML 备份写入失败' }
    try { [xml]$verified = Get-Content -LiteralPath $out -Raw -Encoding UTF8 -ErrorAction Stop } catch { throw ('计划任务 XML 备份验证失败: ' + $_.Exception.Message) }
    if ($null -eq $verified.DocumentElement -or $verified.DocumentElement.LocalName -cne 'Task') { throw '计划任务 XML 备份内容无效' }
    Protect-BackupPathIfSecure -Path $out -BackupDir $BackupDir
    return $out
}

function Invoke-TaskDisableAction {
    param($Pending, $BackupDir, $Tag)
    $artifact = $null
    try {
    try { $null = Assert-TrustedBackupPackagePath $BackupDir } catch {
        return [pscustomobject]@{ status='failed'; reason=('备份 ACL 信任验证失败: ' + $_.Exception.Message); backup=''; manifest=$null }
    }
    try { $taskPath = Normalize-TaskPathIdentity $Pending.task_path } catch {
        return [pscustomobject]@{ status='skipped'; reason='计划任务路径无效'; backup=''; manifest=$null }
    }
    $taskName = $taskPath.Split('\')[-1]
    $taskFolder = if ($taskPath.Length -gt $taskName.Length) { $taskPath.Substring(0, $taskPath.Length - $taskName.Length) } else { '\' }
    try {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
        if (-not $task) { return [pscustomobject]@{ status='skipped'; reason='计划任务不存在'; backup=''; manifest=$null } }
        $xml = Export-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction Stop
        $bak = Write-TaskXmlBackup -Xml $xml -BackupDir $BackupDir -Tag $Tag
        $bak = Resolve-ValidatedBackupPath $BackupDir $bak
        $artifact = Open-LockedBackupArtifact $bak
        $null = Assert-BackupArtifactIdentity -Type 'task' -Artifact $artifact -TargetIdentity $taskPath
    } catch {
        return [pscustomobject]@{ status='failed'; reason=('计划任务备份失败: ' + $_.Exception.Message); backup=''; manifest=$null }
    }

    $manifest = [pscustomobject]@{
        backup_format_version=1; entry_id=$Tag; type='task'; name=$taskPath; target_identity=$taskPath
        backup=$bak; backup_verified=$true; backup_sha256=$artifact.Sha256
        execution_status='prepared'; verified=$false
        note='restore: Register-ScheduledTask -Xml <backup> -TaskName <name> -TaskPath <path> -Force'
    }
    try { $null = Add-BackupManifestEntryAtomic -BackupDir $BackupDir -Entry $manifest } catch {
        return [pscustomobject]@{ status='failed'; reason=('manifest write-ahead 失败: ' + $_.Exception.Message); backup=$bak; manifest=$null }
    }
    try { $null = Assert-TrustedBackupPackagePath $BackupDir; Assert-TrustedBackupPathAcl $bak; Assert-TrustedBackupPathAcl (Join-Path $BackupDir 'manifest.json') } catch {
        return [pscustomobject]@{ status='failed'; reason=('mutation 前备份 ACL 复验失败: ' + $_.Exception.Message); backup=$bak; manifest=$manifest }
    }
    try {
        Disable-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction Stop | Out-Null
        $taskAfter = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
        if ($taskAfter -and $taskAfter.State -eq 'Disabled') {
            try { $null = Update-BackupManifestEntryAtomic $BackupDir $Tag 'success' $true } catch {
                return [pscustomobject]@{ status='failed'; reason=('任务已禁用，但 manifest 状态更新失败: ' + $_.Exception.Message); backup=$bak; manifest=$manifest }
            }
            $manifest.execution_status = 'success'; $manifest.verified = $true
            return [pscustomobject]@{ status='success'; reason='计划任务已禁用'; backup=$bak; manifest=$manifest }
        }
        try { $null = Update-BackupManifestEntryAtomic $BackupDir $Tag 'failed' $false } catch {}
        $actualState = if ($taskAfter) { $taskAfter.State } else { '目标不存在' }
        return [pscustomobject]@{ status='failed'; reason=("任务状态=$actualState"); backup=$bak; manifest=$manifest }
    } catch {
        try { $null = Update-BackupManifestEntryAtomic $BackupDir $Tag 'failed' $false } catch {}
        return [pscustomobject]@{ status='failed'; reason=('计划任务禁用或验证失败: ' + $_.Exception.Message); backup=$bak; manifest=$manifest }
    }
    } finally { Close-BackupArtifact $artifact }
}

function Get-ServiceRestorePlan($Manifest) {
    if ($null -eq $Manifest) { throw (New-RestoreCandidateRejectedException '服务恢复 manifest 为空') }
    if ($Manifest.PSObject.Properties.Name -contains 'backup_verified' -and $Manifest.backup_verified -ne $true) {
        throw (New-RestoreCandidateRejectedException '服务恢复 manifest 未绑定验证过的备份')
    }
    $scVal = $null
    if ($Manifest.PSObject.Properties.Name -contains 'start_type_sc' -and $Manifest.start_type_sc) {
        $scVal = $Manifest.start_type_sc
    } elseif ($Manifest.before -match '^\d+$') {
        $scVal = Convert-NumberToSc $Manifest.before
    } elseif ($Manifest.before) {
        $scVal = Convert-StartTypeToSc $Manifest.before
    } else {
        $scVal = 'disabled'
    }
    if ($scVal -cnotin @('auto','demand','disabled','boot','system')) { throw (New-RestoreCandidateRejectedException '服务恢复启动类型无效') }
    if ($Manifest.status -isnot [string] -or $Manifest.status -cnotin @('Running','Stopped')) { throw (New-RestoreCandidateRejectedException '服务恢复只允许稳定 Running 或 Stopped 状态') }
    $expectedStatus = $Manifest.status
    $shouldStart = ($expectedStatus -ceq 'Running')
    if ($Manifest.PSObject.Properties.Name -contains 'restart_after_restore') {
        if ($Manifest.restart_after_restore -isnot [bool]) { throw (New-RestoreCandidateRejectedException 'restart_after_restore 必须是真正 Boolean') }
        if ($Manifest.restart_after_restore -ne $shouldStart) { throw (New-RestoreCandidateRejectedException 'restart_after_restore 与严格 ExpectedStatus 冲突') }
    }
    return [pscustomobject]@{ StartType=$scVal; ExpectedStatus=$expectedStatus; ShouldStart=$shouldStart }
}

function Get-BackupPathAttributes($Path) {
    return [System.IO.File]::GetAttributes($Path)
}

function Resolve-ValidatedBackupPath($BackupDir, $BackupPath) {
    if ($BackupDir -isnot [string] -or [string]::IsNullOrWhiteSpace($BackupDir) -or
        $BackupPath -isnot [string] -or [string]::IsNullOrWhiteSpace($BackupPath)) {
        throw (New-RestoreCandidateRejectedException '备份目录或文件路径无效')
    }
    $rootPath = [System.IO.Path]::GetFullPath($BackupDir).TrimEnd('\')
    if (-not [System.IO.Directory]::Exists($rootPath)) { throw (New-RestoreCandidateRejectedException '真实备份根目录不存在') }
    $root = $rootPath + '\'
    $candidate = if ([System.IO.Path]::IsPathRooted($BackupPath)) {
        [System.IO.Path]::GetFullPath($BackupPath)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $BackupDir $BackupPath))
    }
    if (-not $candidate.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { throw (New-RestoreCandidateRejectedException '备份文件不在指定备份目录内') }
    if (-not [System.IO.File]::Exists($candidate)) { throw (New-RestoreCandidateRejectedException '备份文件缺失') }
    if ((Get-Item -LiteralPath $candidate -ErrorAction Stop).Length -le 0) { throw (New-RestoreCandidateRejectedException '备份文件为空') }
    $current = $rootPath
    $pathsToCheck = @($rootPath)
    $relative = $candidate.Substring($root.Length)
    foreach ($segment in ($relative -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { throw (New-RestoreCandidateRejectedException '备份路径包含空层级') }
        $current = Join-Path $current $segment
        $pathsToCheck += $current
    }
    foreach ($path in $pathsToCheck) {
        $attributes = Get-BackupPathAttributes $path
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw (New-RestoreCandidateRejectedException "备份路径包含重解析点: $path") }
        Assert-TrustedBackupPathAcl -Path $path -RequireProtected $true
    }
    $finalPath = [System.IO.Path]::GetFullPath($current)
    if (-not [string]::Equals($finalPath, $candidate, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $finalPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-RestoreCandidateRejectedException '规范化最终备份路径不在真实根目录内')
    }
    return $finalPath
}

function Assert-NewManifestBackupBinding($Manifest, $Artifact, $ExpectedIdentity) {
    $version = if ($Manifest.PSObject.Properties.Name -contains 'backup_format_version') { $Manifest.backup_format_version } else { $null }
    if (($version -isnot [int32] -and $version -isnot [int64]) -or [int64]$version -ne 1) {
        throw (New-RestoreCandidateRejectedException 'manifest 缺少受支持的明确备份格式版本')
    }
    if ($Manifest.PSObject.Properties.Name -notcontains 'backup_verified' -or $Manifest.backup_verified -isnot [bool] -or -not $Manifest.backup_verified) {
        throw (New-RestoreCandidateRejectedException 'manifest 未标记验证过的备份')
    }
    if ($Manifest.target_identity -isnot [string] -or
        -not [string]::Equals($Manifest.target_identity, $ExpectedIdentity, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-RestoreCandidateRejectedException 'manifest 目标身份不匹配')
    }
    if ($Manifest.backup_sha256 -isnot [string] -or $Manifest.backup_sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
        -not [string]::Equals($Artifact.Sha256, $Manifest.backup_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-RestoreCandidateRejectedException '备份 SHA-256 验证失败')
    }
}

function Assert-RestoreManifestSchema($Manifest) {
    if ($null -eq $Manifest -or $Manifest.type -isnot [string] -or $Manifest.type -cnotin @('service','autostart','task','process')) { throw (New-RestoreCandidateRejectedException 'manifest 记录类型无效') }
    if ($Manifest.type -eq 'process') { return }
    $version = if ($Manifest.PSObject.Properties.Name -contains 'backup_format_version') { $Manifest.backup_format_version } else { $null }
    if (($version -isnot [int32] -and $version -isnot [int64]) -or [int64]$version -ne 1) { throw (New-RestoreCandidateRejectedException 'manifest 缺少受支持的明确备份格式版本') }
    if ($Manifest.PSObject.Properties.Name -notcontains 'backup_verified' -or $Manifest.backup_verified -isnot [bool] -or -not $Manifest.backup_verified) { throw (New-RestoreCandidateRejectedException 'manifest 未标记验证过的备份') }
    $common = @('backup_format_version','entry_id','type','name','target_identity','backup','backup_verified','backup_sha256','execution_status','verified','note')
    $specific = switch -CaseSensitive ($Manifest.type) {
        'service' { @('start_type_sc','start_type_display','status','delayed_autostart','restart_after_restore') }
        'autostart' { @('key') }
        'task' { @() }
    }
    foreach ($property in $Manifest.PSObject.Properties) { if ($property.Name -cnotin @($common + $specific)) { throw (New-RestoreCandidateRejectedException "manifest 包含未知字段: $($property.Name)") } }
    foreach ($field in @('entry_id','type','name','target_identity','backup','backup_sha256','execution_status')) {
        if ($Manifest.PSObject.Properties.Name -cnotcontains $field -or $Manifest.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($Manifest.$field)) { throw (New-RestoreCandidateRejectedException "manifest 字段 $field 必须是非空字符串") }
    }
    if ($Manifest.execution_status -cnotin @('prepared','success','failed')) { throw (New-RestoreCandidateRejectedException 'manifest 执行状态不允许恢复') }
    if ($Manifest.PSObject.Properties.Name -contains 'verified' -and $Manifest.verified -isnot [bool]) { throw (New-RestoreCandidateRejectedException 'manifest verified 必须是 Boolean') }
    if ($Manifest.PSObject.Properties.Name -contains 'note' -and $Manifest.note -isnot [string]) { throw (New-RestoreCandidateRejectedException 'manifest note 必须是字符串') }
    if ($Manifest.type -eq 'service') {
        if ($Manifest.start_type_sc -isnot [string] -or $Manifest.start_type_sc -cnotin @('auto','demand','disabled','boot','system')) { throw (New-RestoreCandidateRejectedException '服务启动类型无效') }
        if ($Manifest.PSObject.Properties.Name -contains 'start_type_display' -and ($Manifest.start_type_display -isnot [string] -or $Manifest.start_type_display -cnotin @('Automatic','Manual','Disabled','Boot','System'))) { throw (New-RestoreCandidateRejectedException '服务显示启动类型无效') }
        if ($Manifest.status -isnot [string] -or $Manifest.status -cnotin @('Running','Stopped')) { throw (New-RestoreCandidateRejectedException '服务状态必须是稳定 Running 或 Stopped') }
        if ($Manifest.PSObject.Properties.Name -contains 'delayed_autostart' -and (-not (Test-StrictInteger $Manifest.delayed_autostart) -or [int64]$Manifest.delayed_autostart -notin @(0,1))) { throw (New-RestoreCandidateRejectedException 'delayed_autostart 无效') }
        if ($Manifest.PSObject.Properties.Name -contains 'restart_after_restore' -and $Manifest.restart_after_restore -isnot [bool]) { throw (New-RestoreCandidateRejectedException 'restart_after_restore 必须是真正 Boolean') }
    }
    if ($Manifest.type -eq 'autostart' -and ($Manifest.key -isnot [string] -or [string]::IsNullOrWhiteSpace($Manifest.key))) { throw (New-RestoreCandidateRejectedException '自启动 key 必须是字符串') }
}

function Get-RestorePlan {
    param($Manifest, $BackupDir)
    Assert-RestoreManifestSchema $Manifest
    $artifact = $null
    try {
    switch -CaseSensitive ($Manifest.type) {
        'service' {
            if ($Manifest.name -isnot [string] -or $Manifest.name -cnotmatch '^[A-Za-z0-9_.]+$') { throw (New-RestoreCandidateRejectedException '服务目标身份无效') }
            $backupPath = Resolve-ValidatedBackupPath $BackupDir $Manifest.backup
            $artifact = Open-LockedBackupArtifact $backupPath
            Assert-NewManifestBackupBinding $Manifest $artifact $Manifest.name
            $null = Assert-BackupArtifactIdentity -Type 'service' -Artifact $artifact -TargetIdentity $Manifest.name
            $servicePlan = Get-ServiceRestorePlan $Manifest
            return [pscustomobject]@{
                Type='service'; Name=$Manifest.name; BackupPath=$backupPath
                StartType=$servicePlan.StartType; ExpectedStatus=$servicePlan.ExpectedStatus; ShouldStart=$servicePlan.ShouldStart
                HasDelayed=($Manifest.PSObject.Properties.Name -contains 'delayed_autostart')
                DelayedAutoStart=($(if ($Manifest.delayed_autostart -eq 1) { 1 } else { 0 })); Artifact=$artifact
            }
        }
        'autostart' {
            if (-not (Test-AllowedAutostartRegistrySource $Manifest.key) -or
                $Manifest.name -isnot [string] -or [string]::IsNullOrWhiteSpace($Manifest.name)) { throw (New-RestoreCandidateRejectedException '自启动目标身份无效') }
            $identity = $Manifest.key + '|' + $Manifest.name
            $backupPath = Resolve-ValidatedBackupPath $BackupDir $Manifest.backup
            $artifact = Open-LockedBackupArtifact $backupPath
            Assert-NewManifestBackupBinding $Manifest $artifact $identity
            if (-not $backupPath.EndsWith('.autostart.json', [System.StringComparison]::OrdinalIgnoreCase)) { throw (New-RestoreCandidateRejectedException '自启动备份扩展名无效') }
            $parsed = Assert-BackupArtifactIdentity -Type 'autostart' -Artifact $artifact -Key $Manifest.key -Name $Manifest.name
            return [pscustomobject]@{ Type='autostart'; Format='single_value'; Key=$Manifest.key; Name=$Manifest.name; BackupPath=$backupPath; Info=$parsed.Info; Artifact=$artifact }
        }
        'task' {
            $normalizedTaskName = Normalize-TaskPathIdentity $Manifest.name
            $backupPath = Resolve-ValidatedBackupPath $BackupDir $Manifest.backup
            $artifact = Open-LockedBackupArtifact $backupPath
            Assert-NewManifestBackupBinding $Manifest $artifact $normalizedTaskName
            $parsed = Assert-BackupArtifactIdentity -Type 'task' -Artifact $artifact -TargetIdentity $normalizedTaskName
            $taskName = $normalizedTaskName.Split('\')[-1]
            $taskFolder = $normalizedTaskName.Substring(0, $normalizedTaskName.Length - $taskName.Length)
            return [pscustomobject]@{ Type='task'; Name=$normalizedTaskName; TaskName=$taskName; TaskPath=$taskFolder; BackupPath=$backupPath; Xml=$parsed.Xml; TaskFingerprint=$parsed.TaskFingerprint; Artifact=$artifact }
        }
        'process' { return [pscustomobject]@{ Type='process'; Name=$Manifest.name; Path=$Manifest.path } }
        default { throw (New-RestoreCandidateRejectedException 'manifest 记录类型不受支持') }
    }
    } catch {
        Close-BackupArtifact $artifact
        throw
    }
}

function Invoke-ServiceControlCommand([string[]]$Arguments) {
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) { throw 'sc.exe 参数为空' }
    & sc.exe @Arguments | Out-Null
    return [int]$LASTEXITCODE
}

function Invoke-RestorePlanAction($Plan) {
    switch -CaseSensitive ($Plan.Type) {
        'service' {
            if ($Plan.ExpectedStatus -isnot [string] -or $Plan.ExpectedStatus -cnotin @('Running','Stopped')) {
                return [pscustomobject]@{success=$false;type='service';name=$Plan.Name;reason='服务恢复计划缺少稳定 ExpectedStatus'}
            }
            $configExit = Invoke-ServiceControlCommand -Arguments @('config', $Plan.Name, 'start=', $Plan.StartType)
            if ($configExit -ne 0) { return [pscustomobject]@{success=$false;type='service';name=$Plan.Name;reason="sc config 失败 (exit=$configExit)"} }
            try {
                if ($Plan.HasDelayed) {
                    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($Plan.Name)" -Name DelayedAutostart -PropertyType DWord -Value $Plan.DelayedAutoStart -Force -ErrorAction Stop | Out-Null
                }
            } catch { return [pscustomobject]@{success=$false;type='service';name=$Plan.Name;reason=('DelayedAutostart 写入失败: ' + $_.Exception.Message)} }
            if ($Plan.ExpectedStatus -ceq 'Running') {
                $startExit = Invoke-ServiceControlCommand -Arguments @('start', $Plan.Name)
                if ($startExit -ne 0) { return [pscustomobject]@{success=$false;type='service';name=$Plan.Name;reason="sc start 失败 (exit=$startExit)"} }
            }

            $after = Get-Service -Name $Plan.Name -ErrorAction SilentlyContinue
            if (-not $after) { return [pscustomobject]@{success=$false;type='service';name=$Plan.Name;reason='服务最终回读不存在'} }
            $actualStartType = Convert-StartTypeToSc $after.StartType.ToString()
            if ($actualStartType -cne $Plan.StartType) {
                return [pscustomobject]@{success=$false;type='service';name=$Plan.Name;reason="StartType 回读不一致: actual=$actualStartType expected=$($Plan.StartType)"}
            }
            if ($Plan.HasDelayed) {
                try { $actualDelayed = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($Plan.Name)" -Name DelayedAutostart -ErrorAction Stop).DelayedAutostart }
                catch { return [pscustomobject]@{success=$false;type='service';name=$Plan.Name;reason=('DelayedAutostart 回读失败: ' + $_.Exception.Message)} }
                if (-not (Test-StrictInteger $actualDelayed) -or [int64]$actualDelayed -ne [int64]$Plan.DelayedAutoStart) {
                    return [pscustomobject]@{success=$false;type='service';name=$Plan.Name;reason="DelayedAutostart 回读不一致: actual=$actualDelayed expected=$($Plan.DelayedAutoStart)"}
                }
            }
            $actualStatus = $after.Status.ToString()
            if ($actualStatus -cne $Plan.ExpectedStatus) {
                return [pscustomobject]@{success=$false;type='service';name=$Plan.Name;reason="运行状态回读不一致: actual=$actualStatus expected=$($Plan.ExpectedStatus)"}
            }
            return [pscustomobject]@{success=$true;type='service';name=$Plan.Name;reason='服务启动类型、延迟启动和运行状态回读一致'}
        }
        'autostart' {
            if ($Plan.Format -eq 'single_value') { Restore-AutostartValue $Plan.Info }
            else { throw '不允许从未绑定的旧式自启动备份自动恢复' }
            $actualInfo = Get-AutostartValueInfo $Plan.Key $Plan.Name
            $success = Test-AutostartValueEqual $Plan.Info $actualInfo
            return [pscustomobject]@{ success=[bool]$success; type='autostart'; name=$Plan.Name }
        }
        'task' {
            Register-ScheduledTask -Xml $Plan.Xml -TaskName $Plan.TaskName -TaskPath $Plan.TaskPath -Force -ErrorAction Stop | Out-Null
            $after = Get-ScheduledTask -TaskName $Plan.TaskName -TaskPath $Plan.TaskPath -ErrorAction SilentlyContinue
            $success = $false
            if ($after) {
                try {
                    $restoredXml = Export-ScheduledTask -TaskName $Plan.TaskName -TaskPath $Plan.TaskPath -ErrorAction Stop
                    $success = (Get-TaskDefinitionFingerprint $restoredXml) -ceq $Plan.TaskFingerprint
                } catch { $success = $false }
            }
            return [pscustomobject]@{ success=[bool]$success; type='task'; name=$Plan.Name }
        }
        'process' { return [pscustomobject]@{ success=$true; type='process'; name=$Plan.Name } }
        default { throw '恢复计划类型不受支持' }
    }
}

function Invoke-ValidatedRestoreManifest($Manifest, $BackupDir) {
    $BackupDir = Assert-TrustedBackupPackagePath $BackupDir
    $plans = @()
    try {
        foreach ($entry in @($Manifest)) { $plans += Get-RestorePlan -Manifest $entry -BackupDir $BackupDir }
    } catch {
        foreach ($openedPlan in $plans) { Close-BackupArtifact $openedPlan.Artifact }
        throw
    }
    try {
        # 所有 plan 已完成且尚未执行任何 mutation；此处再次验证信任链，封闭规划阶段 TOCTOU。
        $BackupDir = Assert-TrustedBackupPackagePath $BackupDir
        Assert-TrustedBackupPathAcl -Path (Join-Path $BackupDir 'manifest.json') -RequireProtected $true
        foreach ($plannedArtifact in @($plans | Where-Object { $_.PSObject.Properties.Name -contains 'BackupPath' })) {
            Assert-TrustedBackupPathAcl -Path $plannedArtifact.BackupPath -RequireProtected $true
        }
        $results = @()
        foreach ($plan in $plans) {
            try {
                $actionResult = Invoke-RestorePlanAction -Plan $plan
                if ($null -eq $actionResult -or $actionResult.success -isnot [bool]) { throw '恢复动作未返回明确 Boolean 结果' }
                $status = if ($actionResult.success) { 'success' } else { 'failed' }
                $reason = if ($actionResult.PSObject.Properties.Name -contains 'reason') { [string]$actionResult.reason } elseif ($actionResult.success) { '' } else { '恢复后回读验证失败' }
                $results += [pscustomobject]@{ success=$actionResult.success; status=$status; type=$actionResult.type; name=$actionResult.name; reason=$reason }
            } catch {
                $results += [pscustomobject]@{ success=$false; status='failed'; type=$plan.Type; name=$plan.Name; reason=$_.Exception.Message }
            }
        }
        return $results
    } finally {
        foreach ($plan in $plans) { Close-BackupArtifact $plan.Artifact }
    }
}

$script:RestoreResolutionExceptionKindKey = 'MouseCleaner.RestoreResolutionKind'

function New-RestoreResolutionException {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('CandidateRejected','NoTrustedBackup')][string]$Kind,
        [Parameter(Mandatory=$true)][string]$Message,
        [System.Exception]$InnerException = $null
    )
    $exception = if ($Kind -ceq 'CandidateRejected') {
        New-Object System.IO.InvalidDataException($Message, $InnerException)
    } else {
        New-Object System.IO.FileNotFoundException($Message, $InnerException)
    }
    $exception.Data[$script:RestoreResolutionExceptionKindKey] = $Kind
    return $exception
}

function New-RestoreCandidateRejectedException([string]$Message, [System.Exception]$InnerException = $null) {
    return New-RestoreResolutionException -Kind 'CandidateRejected' -Message $Message -InnerException $InnerException
}

function New-RestoreNoTrustedBackupException([string]$Message) {
    return New-RestoreResolutionException -Kind 'NoTrustedBackup' -Message $Message
}

function Test-RestoreResolutionExceptionKind($Exception, [string]$Kind) {
    if ($null -eq $Exception -or $Exception.Data -isnot [System.Collections.IDictionary]) { return $false }
    return [string]::Equals(
        [string]$Exception.Data[$script:RestoreResolutionExceptionKindKey],
        $Kind,
        [System.StringComparison]::Ordinal
    )
}

function Get-TrustedRestorePackage($BackupDir) {
    $resolvedBackupDir = Assert-TrustedBackupPackagePath $BackupDir
    $manifestFile = Join-Path $resolvedBackupDir 'manifest.json'
    $manifestExists = Test-Path -LiteralPath $manifestFile -PathType Leaf -ErrorAction Stop
    if ($manifestExists -isnot [bool]) { throw 'manifest 存在性检查未返回 Boolean 结果' }
    if (-not $manifestExists) { throw (New-RestoreCandidateRejectedException '可信备份缺少 manifest.json') }
    Assert-TrustedBackupPathAcl -Path $manifestFile -RequireProtected $true
    $manifest = @(Read-BackupManifestEntries $manifestFile)
    if ($manifest.Count -eq 0) { throw (New-RestoreCandidateRejectedException '可信备份清单为空') }

    $plans = @()
    try {
        foreach ($entry in $manifest) {
            $plans += Get-RestorePlan -Manifest $entry -BackupDir $resolvedBackupDir
        }
    } finally {
        foreach ($plan in $plans) { Close-BackupArtifact $plan.Artifact }
    }

    return [pscustomobject]@{
        BackupDir = $resolvedBackupDir
        Manifest = $manifest
    }
}

function Resolve-LatestTrustedRestorePackage {
    $secureRoot = Get-SecureBackupRoot
    if (-not [System.IO.Directory]::Exists($secureRoot)) { throw (New-RestoreNoTrustedBackupException '没有可用的可信备份') }
    Assert-TrustedBackupPathAcl -Path $secureRoot -RequireProtected $true
    $candidates = @(Get-ChildItem -LiteralPath $secureRoot -Directory -ErrorAction Stop |
        Where-Object { $_.Name -cmatch '^\d{8}_\d{6}$' } |
        Sort-Object Name -Descending)
    foreach ($candidate in $candidates) {
        try { return Get-TrustedRestorePackage -BackupDir $candidate.FullName } catch {
            if (Test-RestoreResolutionExceptionKind -Exception $_.Exception -Kind 'CandidateRejected') { continue }
            throw
        }
    }
    throw (New-RestoreNoTrustedBackupException '没有通过 owner、DACL、manifest、哈希和身份验证的可信备份')
}

function Get-CurrentProcessIdentity($ProcessId) {
    if (-not (Test-PositiveScalarProcessId $ProcessId)) { return $null }
    try { $processes = @(Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue) } catch { return $null }
    if ($processes.Count -ne 1 -or $null -eq $processes[0]) { return $null }
    $process = $processes[0]
    $path = ''
    $startTimeUtc = ''
    try { $path = [string]$process.Path } catch {}
    try { $startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o') } catch {}
    $name = ''
    try { $name = [string]$process.ProcessName } catch {}
    return [pscustomobject]@{ PID=[int]$process.Id; Name=$name; Path=$path; StartTimeUtc=$startTimeUtc }
}

function Get-BoundProcessTarget($ProcessId) {
    if (-not (Test-PositiveScalarProcessId $ProcessId)) { return $null }
    try { $processes = @(Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue) } catch { return $null }
    if ($processes.Count -ne 1 -or $null -eq $processes[0]) { return $null }
    $process = $processes[0]
    try { $null = $process.Handle } catch {
        try { $process.Dispose() } catch {}
        return $null
    }
    $path = ''
    $startTimeUtc = ''
    $name = ''
    try { $path = [string]$process.Path } catch {}
    try { $startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o') } catch {}
    try { $name = [string]$process.ProcessName } catch {}
    return [pscustomobject]@{
        Process = $process
        Identity = [pscustomobject]@{ PID=[int]$process.Id; Name=$name; Path=$path; StartTimeUtc=$startTimeUtc }
    }
}

function Stop-BoundProcessTarget {
    param([Parameter(Mandatory=$true)]$Target, [int]$TimeoutMilliseconds = 1000)
    $process = $Target.Process
    if ($null -eq $process) { throw '绑定的进程对象不可用' }
    $process.Kill()
    $waited = $process.WaitForExit($TimeoutMilliseconds)
    if ($waited -isnot [bool] -or -not $waited) { return $false }
    return $true
}

function Test-SameProcessIdentity($Expected, $Current) {
    if ($null -eq $Expected -or $null -eq $Current) { return $false }
    try {
        if (-not (Test-PositiveScalarProcessId $Expected.PID) -or -not (Test-PositiveScalarProcessId $Current.PID) -or
            [int]$Expected.PID -ne [int]$Current.PID) { return $false }
        $expectedName = Get-StrictNonBlankStringProperty $Expected 'Name'
        $currentName = Get-StrictNonBlankStringProperty $Current 'Name'
        $expectedPath = Get-StrictNonBlankStringProperty $Expected 'Path'
        $currentPath = Get-StrictNonBlankStringProperty $Current 'Path'
        $expectedStart = Get-StrictNonBlankStringProperty $Expected 'StartTimeUtc'
        $currentStart = Get-StrictNonBlankStringProperty $Current 'StartTimeUtc'
        if ($null -in @($expectedName,$currentName,$expectedPath,$currentPath,$expectedStart,$currentStart)) { return $false }
        return [string]::Equals((Normalize-ProcessName $expectedName),(Normalize-ProcessName $currentName),[System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([System.IO.Path]::GetFullPath($expectedPath),[System.IO.Path]::GetFullPath($currentPath),[System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($expectedStart,$currentStart,[System.StringComparison]::Ordinal)
    } catch { return $false }
}

function New-ProcessStopResult($Row, [string]$Status, [string]$Reason) {
    $copy = $Row.PSObject.Copy()
    $copy.status = $Status
    $copy | Add-Member NoteProperty result_reason $Reason -Force
    return $copy
}

function Wait-ProcessIdentityExit {
    param([int]$ProcessId, [int]$Attempts = 20, [int]$DelayMilliseconds = 50)
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        if ($null -eq (Get-CurrentProcessIdentity $ProcessId)) { return $true }
        if ($attempt -lt ($Attempts - 1)) { Start-Sleep -Milliseconds $DelayMilliseconds }
    }
    return $false
}

function Invoke-OneTimeProcessStop($Row) {
    try { $null = Assert-SuspiciousPendingRow $Row -RequireStoppable } catch {
        return New-ProcessStopResult $Row 'failed' ('身份结构无效: ' + $_.Exception.Message)
    }
    if ($Row.status -cnotin @('pending','failed')) { return New-ProcessStopResult $Row 'skipped' '该条目已是终态' }
    $protectedNames = @('system','system idle process','registry','smss','csrss','wininit','services','lsass','winlogon','svchost','fontdrvhost','dwm')
    $normalizedName = Normalize-ProcessName ([string]$Row.Name)
    if ($protectedNames -contains $normalizedName -or [int]$Row.PID -eq [int]$PID) {
        return New-ProcessStopResult $Row 'skipped' '受保护进程或当前执行进程，拒绝停止'
    }
    $target = Get-BoundProcessTarget ([int]$Row.PID)
    if ($null -eq $target) { return New-ProcessStopResult $Row 'skipped' 'PID 已退出或身份不可读取' }
    try {
        if (-not (Test-SameProcessIdentity $Row $target.Identity)) { return New-ProcessStopResult $Row 'skipped' 'PID 对应的名称、路径或启动时间已变化' }
        try { $exited = Stop-BoundProcessTarget -Target $target } catch {
            return New-ProcessStopResult $Row 'failed' ('停止进程失败: ' + $_.Exception.Message)
        }
        if (-not $exited) { return New-ProcessStopResult $Row 'failed' '等待退出超时，进程仍存在' }
        return New-ProcessStopResult $Row 'success' '已结束这一次进程实例'
    } finally {
        try { if ($null -ne $target.Process) { $target.Process.Dispose() } } catch {}
    }
}

function Invoke-StopProcessPending {
    param([string]$Path, [string]$ExpectedSha256)
    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path)) { throw 'stop_process 缺失 pending 文件路径' }
    if ($ExpectedSha256 -isnot [string] -or $ExpectedSha256 -cnotmatch '^[0-9a-fA-F]{64}$') { throw 'stop_process 缺失有效 SHA-256' }
    $stream = $null
    try {
        $stream = Open-LockedPendingFile $Path
        $actualHash = Get-PendingStreamSha256 $stream
        if (-not [string]::Equals($actualHash,$ExpectedSha256,[System.StringComparison]::OrdinalIgnoreCase)) { throw 'stop_process pending SHA-256 不匹配' }
        $pending = ConvertFrom-StrictPendingJson (Read-LimitedPendingJsonStream $stream)
        if (-not (Test-PendingSchemaSupported $pending)) { throw 'stop_process pending schema 不兼容' }
        foreach ($name in @('actions','observations','suspicious')) {
            if ($pending.PSObject.Properties.Name -notcontains $name -or $pending.$name -isnot [System.Array]) { throw "stop_process $name 必须是数组" }
        }
        if (@($pending.actions).Count -ne 0) { throw 'stop_process actions 必须为空' }
        if (@($pending.observations).Count -ne 0) { throw 'stop_process observations 必须为空' }
        $rows = @($pending.suspicious)
        if ($rows.Count -eq 0) { throw 'stop_process suspicious 不能为空' }
        foreach ($row in $rows) { $null = Assert-SuspiciousPendingRow $row -RequireStoppable }
        $results = @()
        foreach ($row in $rows) {
            if ($row.status -cin @('pending','failed')) { $results += Invoke-OneTimeProcessStop $row }
            else { $results += $row }
        }
        $payload = Build-PendingV2Payload -Source $pending -Actions @() -Observations @() -Suspicious @($results)
        Write-PendingToLockedStream -Stream $stream -Pending $payload
        $failed = @($results | Where-Object { $_.status -ceq 'failed' }).Count
        return [pscustomobject]@{ ExitCode=$(if ($failed -gt 0) { 2 } else { 0 }); Results=@($results) }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Invoke-Clean {
    if (-not (Is-Admin)) {
        Write-Host '错误: clean 模式需要管理员权限。请右键以管理员身份运行 PowerShell 再执行。' -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $script:PendingFile)) {
        Write-Host '未找到 pending_actions.json, 请先运行 scan 模式生成清单。' -ForegroundColor Red
        exit 1
    }
    $pendingStream = $null
    $pending = $null
    $pendingValidated = $false
    try {
    $pendingStream = Open-LockedPendingFile $script:PendingFile
    if ($script:RequirePendingSha256) {
        if ($script:PendingSha256 -isnot [string] -or $script:PendingSha256 -cnotmatch '^[0-9a-fA-F]{64}$') {
            throw '自定义 pending 文件缺失有效的 SHA-256 绑定，拒绝执行'
        }
        $actualPendingSha256 = Get-PendingStreamSha256 $pendingStream
        if (-not [string]::Equals($actualPendingSha256, $script:PendingSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw '自定义 pending 文件 SHA-256 不匹配，拒绝执行'
        }
    }
    $pendingRaw = Read-LimitedPendingJsonStream $pendingStream
    $pending = ConvertFrom-StrictPendingJson $pendingRaw
    if (-not (Test-PendingSchemaSupported $pending)) {
        Write-Host '错误: pending 清单版本旧或不兼容。请重新运行 scan 生成新清单。' -ForegroundColor Red
        exit 1
    }
    $pendingValidated = $true
    # null 防御: $pending.actions 为空/null 时不得产生 @($null) 元素 (管道展开陷阱)
    # v1.2 状态机: 只处理 pending(待办) 和 failed(可重试); success/skipped/manual_required 跳过
    $actions = @()
    if ($pending.actions) { $actions = @($pending.actions | Where-Object { $_ -and $_.status -in @('pending','failed') }) }
    $suspicious = @()
    if ($pending.suspicious) { $suspicious = @($pending.suspicious) }

    # v1.5.3 P0: 提权后重新验证 — 不信任 pending_actions.json, 按当前特征库授权
    try { $profiles = Load-Profiles } catch {
        Write-Host ('特征库校验失败, clean 中止 (安全第一): ' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    $authorized = @()
    $rejected = @()
    foreach ($a in $actions) {
        if (Test-PendingActionAuthorized $a $profiles) { $authorized += $a }
        else { $rejected += $a; $a.status = 'skipped' }
    }
    if ($rejected.Count -gt 0) {
        Write-Host ('拒绝 {0} 条未授权动作 (与当前特征库不一致, 清单可能被修改, 已标 skipped 不执行):' -f $rejected.Count) -ForegroundColor Red
        foreach ($r in $rejected) {
            $tgt = ($r.service_name + $r.autostart_name + $r.task_path + $r.process_name)
            Write-Host ('  拒绝: id={0} action={1} hit={2} target={3}' -f $r.id, $r.action, $r.hit_type, $tgt) -ForegroundColor Red
        }
    }
    $actions = $authorized

    if ($actions.Count -eq 0) {
        Write-Host '待办动作已全部完成或为空。' -ForegroundColor Green
    } else {
        Write-Step '以下动作将被处理, 每个动作都会先备份:'
        for ($i = 0; $i -lt $actions.Count; $i++) {
            $p = $actions[$i]
            Write-Host ('  [{0}] {1} | 动作: {2} | 命中: {3}' -f $i, $p.name_cn, $p.action, $p.hit_type) -ForegroundColor Yellow
            Write-Host ('      详情: {0}' -f $p.detail)
            Write-Host ('      原因: {0}' -f $p.reason_cn)
        }

        $sel = 'q'
        if ($YesToAll) { $sel = 'all' }
        else {
            Write-Host ''
            $sel = Read-Host '输入要处理的编号(逗号分隔), all=全部, q=退出'
        }
        if ($sel -eq 'q') { Write-Host '已取消。'; exit 0 }

        $indexes = @()
        if ($sel -eq 'all') { $indexes = 0..($actions.Count - 1) }
        else {
            foreach ($part in ($sel -split ',')) {
                $n = 0
                if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 0 -and $n -lt $actions.Count) { $indexes += $n }
            }
        }
        if ($indexes.Count -eq 0) { Write-Host '未选择有效条目, 已取消。'; exit 0 }

        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $secureBackupRoot = Get-SecureBackupRoot
        $backupDir = Join-Path $secureBackupRoot $stamp
        $backupDirReady = $false

        foreach ($idx in $indexes) {
            $p = $actions[$idx]
            $tag = ('{0}_{1}' -f $idx, ($p.id -replace '[^a-zA-Z0-9_-]', '_'))
            Write-Step ('处理: {0} ({1})' -f $p.name_cn, $p.action)

            # v1.2 强制规则: safe=false 即使被选中/YesToAll 也拒绝执行
            if (-not $p.safe) {
                Write-Host '  拒绝: safe=false 条目禁止自动执行, 只做人工调查。' -ForegroundColor Red
                $p.status = 'skipped'
                continue
            }

            # 用户作出最终选择后，在任何备份或系统变更前完整重读并重放保存的 matcher。
            if (-not (Test-SelectedPendingActionAuthorized $p $profiles)) { continue }
            # 安全顺序不变量：下方分支或其事务 helper 才能调用 Backup-RegistryKey、
            # sc.exe config、sc.exe stop、Disable-ScheduledTask 等 mutation 原语。
            if (-not $backupDirReady) {
                try { $backupDir = Initialize-ProtectedBackupDirectory $backupDir } catch {
                    Write-Host ('  安全备份目录创建/ACL 验证失败，拒绝执行任何 mutation: ' + $_.Exception.Message) -ForegroundColor Red
                    $p.status = 'failed'
                    continue
                }
                $backupDirReady = $true
            }

            switch ($p.action) {
                'disable_service' {
                    $serviceResult = Invoke-ServiceDisableAction -Pending $p -BackupDir $backupDir -Tag $tag
                    $p.status = $serviceResult.status
                    if ($serviceResult.status -eq 'success') { Write-Host "  验证通过: $($serviceResult.reason)" -ForegroundColor Green }
                    elseif ($serviceResult.status -eq 'skipped') { Write-Host "  跳过: $($serviceResult.reason)" -ForegroundColor DarkYellow }
                    else { Write-Host "  失败: $($serviceResult.reason)" -ForegroundColor Red }
                }
                'remove_autostart' {
                    $rp = $p.autostart_source
                    $nm = $p.autostart_name
                    $removal = Invoke-LiteralAutostartRemoval -Source $rp -Name $nm -ExpectedValue $p.autostart_value -BackupDir $backupDir -Tag $tag
                    $p.status = $removal.status
                    if ($removal.status -eq 'success') {
                        Write-Host "  验证通过: 自启项已删除: $nm (备份: $($removal.backup))" -ForegroundColor Green
                    } elseif ($removal.status -eq 'skipped') {
                        Write-Host "  跳过: $($removal.reason) ($nm)" -ForegroundColor DarkYellow
                    } else {
                        Write-Host "  失败: $($removal.reason) ($nm)" -ForegroundColor Red
                    }
                }
                'disable_task' {
                    $taskResult = Invoke-TaskDisableAction -Pending $p -BackupDir $backupDir -Tag $tag
                    $p.status = $taskResult.status
                    if ($taskResult.status -eq 'success') { Write-Host "  验证通过: 已禁用计划任务: $($p.task_path) (备份: $($taskResult.backup))" -ForegroundColor Green }
                    elseif ($taskResult.status -eq 'skipped') { Write-Host "  跳过: $($taskResult.reason)" -ForegroundColor DarkYellow }
                    else { Write-Host "  失败: $($taskResult.reason)" -ForegroundColor Red }
                }
                'uninstall' {
                    Write-Host '  uninstall 动作需要人工确认, 请到 设置 -> 应用 -> 已安装的应用 手动卸载。' -ForegroundColor Yellow
                    $p.status = 'manual_required'
                }
                default {
                    Write-Host "  未知动作: $($p.action), 跳过" -ForegroundColor DarkYellow
                    $p.status = 'skipped'
                }
            }
        }

        if ($backupDirReady) {
            Write-Step "动作处理完成。备份目录: $backupDir"
        } else {
            Write-Step '动作处理完成。没有已授权动作进入执行阶段，未创建备份目录。'
        }

    }

    # 可疑进程与持久化 OEM 清理严格分离。进程只能经 stop_process 的
    # hash-bound subset 和 PID/name/path/start-time 重验后执行一次性停止。
    if ($suspicious.Count -gt 0) {
        Write-Step '检测到可疑高占用进程（本次 clean 不会结束它们）:'
        foreach ($s in $suspicious) {
            Write-Host ('  PID {0}  {1}  CPU={2}%  {3}' -f $s.PID, $s.Name, $s.'CPU%', $s.Reason) -ForegroundColor Yellow
        }
        Write-Host '  如需结束，请在界面单独选择并使用“一次性结束进程”。' -ForegroundColor DarkYellow
    } else {
        Write-Host "`n无可疑高占用进程。" -ForegroundColor Green
    }

    Write-Step '完成。建议重启一次让所有禁用生效。'
    } finally {
        try {
            if ($pendingValidated -and $null -ne $pendingStream) {
                $payload = Build-PendingV2Payload -Source $pending -Actions @($pending.actions)
                Write-PendingToLockedStream -Stream $pendingStream -Pending $payload
            }
        } finally {
            if ($null -ne $pendingStream) { $pendingStream.Dispose() }
        }
    }
}

# ---------- 11. restore 模式 ----------
function Invoke-Restore {
    if (-not $BackupDir) {
        Write-Host '错误: 需要有效的 -BackupDir 参数。例: cpu-cleaner.ps1 -Mode restore -BackupDir "D:\CPU后台整理工具\backups\20260809_120000"' -ForegroundColor Red
        Write-Host '可用备份: ' -ForegroundColor Yellow -NoNewline
        $secureBackupRoot = Get-SecureBackupRoot
        if (Test-Path $secureBackupRoot) { Get-ChildItem $secureBackupRoot -Directory | ForEach-Object { Write-Host $_.Name -NoNewline; Write-Host '  ' -NoNewline } }
        Write-Host ''
        exit 1
    }
    if (-not (Is-Admin)) {
        Write-Host '错误: restore 模式需要管理员权限。' -ForegroundColor Red
        exit 1
    }
    $latestRequested = ($BackupDir -ceq 'latest')
    try {
        if ($latestRequested) {
            $package = Resolve-LatestTrustedRestorePackage
        } else {
            $resolvedBackupDir = Resolve-TrustedRestoreBackupDirectory -RequestedPath $BackupDir -LegacyRoot $script:BackupRoot
            $package = Get-TrustedRestorePackage -BackupDir $resolvedBackupDir
        }
        $BackupDir = $package.BackupDir
        $manifest = @($package.Manifest)
    } catch {
        Write-Host ('备份包信任验证失败，未执行任何系统修改: ' + $_.Exception.Message) -ForegroundColor Red
        if ($latestRequested -and (Test-RestoreResolutionExceptionKind -Exception $_.Exception -Kind 'NoTrustedBackup')) { exit 3 }
        exit 1
    }
    Write-Step "从备份恢复: $BackupDir"
    try {
        # 所有记录先统一生成并验证 plan；任一失败时不允许任何管理员 mutation。
        $restoreResults = @(Invoke-ValidatedRestoreManifest -Manifest @($manifest) -BackupDir $BackupDir)
    } catch {
        Write-Host ('恢复计划验证失败，未执行任何系统修改: ' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    if (@($restoreResults | Where-Object { -not $_.success }).Count -gt 0) {
        foreach ($failedRestore in @($restoreResults | Where-Object { -not $_.success })) {
            Write-Host ('恢复失败: {0} {1}: {2}' -f $failedRestore.type, $failedRestore.name, $failedRestore.reason) -ForegroundColor Red
        }
        Write-Step '恢复完成, 但存在验证失败的条目 (见上方红色提示)。'
        exit 2
    }
    Write-Step '恢复完成。'
    exit 0
}

# ---------- 12. 特征库更新 (C10) ----------
function Update-Profiles {
    if (-not $script:ProfileUrl) {
        Write-Host '未配置特征库更新地址。请编辑 cpu-cleaner.ps1 顶部的 $script:ProfileUrl 变量。' -ForegroundColor Red
        exit 1
    }
    Write-Step "从 $script:ProfileUrl 下载最新特征库..."
    try {
        $tmp = Join-Path $script:Root 'bloatware-profiles.json.tmp'
        Invoke-WebRequest -Uri $script:ProfileUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 30

        # v1.5.1 供应链安全: 配置了 SHA256 地址则先校验哈希, 不一致拒绝替换
        if ($script:ProfileSha256Url) {
            $shaTmp = Join-Path $script:Root 'bloatware-profiles.json.sha256.tmp'
            Invoke-WebRequest -Uri $script:ProfileSha256Url -OutFile $shaTmp -UseBasicParsing -TimeoutSec 30
            $expected = (Get-Content $shaTmp -Raw).Trim() -split '\s+' | Select-Object -First 1
            $actual = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
            Remove-Item $shaTmp -ErrorAction SilentlyContinue
            if ($expected -ne $actual) {
                Remove-Item $tmp -ErrorAction SilentlyContinue
                throw "SHA256 校验失败: 期望 $expected, 实际 $actual (更新地址可能被篡改, 已中止)"
            }
            Write-Host "  SHA256 校验通过: $actual" -ForegroundColor Green
        } else {
            Write-Host '  警告: 未配置 ProfileSha256Url, 跳过哈希校验 (建议配置以防供应链攻击)' -ForegroundColor DarkYellow
        }

        # v1.3: 用 Load-Profiles 完整校验 (schema_version / id / risk / action / detect / safe / tested 规则)
        $check = Load-Profiles -Path $tmp
        if ($check -and $check.profiles) {
            $bak = Join-Path $script:Root ('bloatware-profiles.json.bak.' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Copy-Item $script:ProfileFile $bak -Force
            Move-Item $tmp $script:ProfileFile -Force
            Write-Host "特征库已更新 (旧版备份: $bak)" -ForegroundColor Green
        } else {
            Write-Host '下载内容不是有效的特征库, 已放弃更新。' -ForegroundColor Red
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host ('更新失败: ' + $_.Exception.Message) -ForegroundColor Red
    }
}

