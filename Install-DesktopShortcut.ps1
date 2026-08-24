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
$shell = New-Object -ComObject WScript.Shell

try {
    $shortcut = $shell.CreateShortcut($temporaryPath)
    $shortcut.TargetPath = $powershellPath
    $shortcut.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $guiPath + '"'
    $shortcut.WorkingDirectory = $root
    $shortcut.IconLocation = $iconPath + ',0'
    $shortcut.Description = '安全识别并清理 OEM 后台组件和高 CPU 可疑进程'
    $shortcut.Save()
    if (-not [System.IO.File]::Exists($temporaryPath)) { throw '快捷方式临时文件创建失败。' }
    Move-Item -LiteralPath $temporaryPath -Destination $shortcutPath -Force
} finally {
    if ([System.IO.File]::Exists($temporaryPath)) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
}

Write-Host "桌面快捷方式已安装: $shortcutPath" -ForegroundColor Green
