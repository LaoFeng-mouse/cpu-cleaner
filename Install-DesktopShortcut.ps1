param(
    [string]$DesktopPath = [Environment]::GetFolderPath('Desktop')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$guiPath = Join-Path $root 'gui-cleaner.ps1'
$iconPath = Join-Path $root 'assets\shushu.ico'

if (-not [System.IO.Directory]::Exists($DesktopPath)) { throw "桌面目录不存在: $DesktopPath" }
if (-not [System.IO.File]::Exists($guiPath)) { throw "GUI 入口不存在: $guiPath" }
if (-not [System.IO.File]::Exists($iconPath)) { throw "鼠鼠图标不存在: $iconPath" }

$powershellPath = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
$shortcutPath = Join-Path $DesktopPath '鼠鼠 Cleaner.lnk'
$temporaryPath = Join-Path $DesktopPath ('.shushu-cleaner-' + [guid]::NewGuid().ToString('N') + '.lnk')
$expectedArguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $guiPath + '"'
$expectedDescription = '安全识别并清理 OEM 后台组件和高 CPU 可疑进程'
$shell = New-Object -ComObject WScript.Shell
$backupPath = $null

# 回读快捷方式的关键字段，确保幂等判断和安装后验证使用同一套标准。
function Test-CleanerShortcut {
    param([Parameter(Mandatory=$true)]$Shortcut)
    return ([string]$Shortcut.TargetPath -match '(?i)\\WindowsPowerShell\\v1\.0\\powershell\.exe$') -and
        [string]::Equals([string]$Shortcut.Arguments, $expectedArguments, [StringComparison]::Ordinal) -and
        [string]::Equals([string]$Shortcut.WorkingDirectory, $root, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$Shortcut.IconLocation, ($iconPath + ',0'), [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$Shortcut.Description, $expectedDescription, [StringComparison]::Ordinal)
}

try {
    $shortcut = $shell.CreateShortcut($temporaryPath)
    $shortcut.TargetPath = $powershellPath
    $shortcut.Arguments = $expectedArguments
    $shortcut.WorkingDirectory = $root
    $shortcut.IconLocation = $iconPath + ',0'
    $shortcut.Description = $expectedDescription
    $shortcut.Save()
    if (-not [System.IO.File]::Exists($temporaryPath)) { throw '快捷方式临时文件创建失败。' }

    if ([System.IO.File]::Exists($shortcutPath)) {
        if (Test-CleanerShortcut $shell.CreateShortcut($shortcutPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force
        } else {
            $backupPath = Join-Path $DesktopPath ('鼠鼠 Cleaner.previous-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.lnk')
            Move-Item -LiteralPath $shortcutPath -Destination $backupPath
        }
    }
    if ([System.IO.File]::Exists($temporaryPath)) {
        Move-Item -LiteralPath $temporaryPath -Destination $shortcutPath
    }
    if (-not [System.IO.File]::Exists($shortcutPath) -or -not (Test-CleanerShortcut $shell.CreateShortcut($shortcutPath))) {
        throw '快捷方式安装后验证失败。'
    }
} catch {
    if ($null -ne $backupPath -and [System.IO.File]::Exists($backupPath)) {
        if ([System.IO.File]::Exists($shortcutPath)) { Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $backupPath -Destination $shortcutPath -ErrorAction SilentlyContinue
    }
    throw
} finally {
    if ([System.IO.File]::Exists($temporaryPath)) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
}

Write-Host "桌面快捷方式已安装: $shortcutPath" -ForegroundColor Green
