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

# Read and write Windows filesystem ACLs through the runtime API instead of the
# Microsoft.PowerShell.Security module. Desktop launchers can inherit a
# PSModulePath containing a Core-only copy of that module; Get-Acl/Set-Acl then
# fail before the cleaner can validate an otherwise valid protected inventory.
function Get-LocalFileSystemAcl($Path) {
    $fullPath = [System.IO.Path]::GetFullPath([string]$Path)
    $item = if ([System.IO.Directory]::Exists($fullPath)) {
        New-Object System.IO.DirectoryInfo($fullPath)
    } elseif ([System.IO.File]::Exists($fullPath)) {
        New-Object System.IO.FileInfo($fullPath)
    } else {
        throw "ACL path does not exist: $fullPath"
    }
    $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor
        [System.Security.AccessControl.AccessControlSections]::Owner
    if ($null -ne $item.PSObject.Methods['GetAccessControl']) {
        return $item.GetAccessControl($sections)
    }
    $extensions = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($null -eq $extensions) { throw 'Windows filesystem ACL API is unavailable.' }
    return $extensions::GetAccessControl($item, $sections)
}

function Set-LocalFileSystemAcl($Path, $Acl) {
    $fullPath = [System.IO.Path]::GetFullPath([string]$Path)
    $item = if ([System.IO.Directory]::Exists($fullPath)) {
        New-Object System.IO.DirectoryInfo($fullPath)
    } elseif ([System.IO.File]::Exists($fullPath)) {
        New-Object System.IO.FileInfo($fullPath)
    } else {
        throw "ACL path does not exist: $fullPath"
    }
    if ($null -ne $item.PSObject.Methods['SetAccessControl']) {
        $item.SetAccessControl($Acl)
        return
    }
    $extensions = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($null -eq $extensions) { throw 'Windows filesystem ACL API is unavailable.' }
    $extensions::SetAccessControl($item, $Acl)
}

