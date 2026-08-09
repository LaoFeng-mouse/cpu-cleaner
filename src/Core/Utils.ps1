# 通用工具 (v1.7.0 从 cpu-cleaner.ps1 拆分)
# Read-Utf8Json / Normalize-ProcessName — 跨域共用
function Read-Utf8Json($path) {
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    return $raw | ConvertFrom-Json
}

function Normalize-ProcessName($name) {
    if (-not $name) { return '' }
    return ([System.IO.Path]::GetFileNameWithoutExtension($name)).ToLowerInvariant()
}

