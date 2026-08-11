# 备份恢复 (v1.7.0 拆分): 单值备份/恢复
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
    return $out
}

function Restore-AutostartValue($info) {
    $propType = switch ($info.value_type) {
        'ExpandString' { 'ExpandString' }
        'DWord'        { 'DWord' }
        'QWord'        { 'QWord' }
        'Binary'       { 'Binary' }
        'MultiString'  { 'MultiString' }
        default        { 'String' }
    }
    # v1.5.6: JSON 往返后类型还原 — ConvertTo-Json/ConvertFrom-Json 会把 byte[]/string[] 变成 object[],
    # 直接写注册表会类型错乱 (Binary 尤其明显), 必须强转回原类型
    $val = $info.value
    if ($propType -eq 'Binary') { $val = [byte[]]$info.value }
    elseif ($propType -eq 'MultiString') { $val = [string[]]$info.value }
    New-ItemProperty -Path $info.key -Name $info.name -Value $val -PropertyType $propType -Force | Out-Null
}

