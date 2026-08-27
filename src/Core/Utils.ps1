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

# Read-only process identity fallback for protected processes whose WMI path is
# intentionally unavailable. The PowerShell wrappers keep the native boundary
# mockable and the public helper returns either one complete identity or null.
function Initialize-NativeProcessIdentityApi {
    $typeName = 'ShushuCleaner.ProcessIdentityNativeV1'
    $nativeType = $typeName -as [type]
    if ($null -eq $nativeType) {
        $source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace ShushuCleaner {
    public static class ProcessIdentityNativeV1 {
        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME {
            public uint Low;
            public uint High;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder path, ref uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessTimes(IntPtr process, out FILETIME creation, out FILETIME exit, out FILETIME kernel, out FILETIME user);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr handle);

        public static string QueryImagePath(IntPtr process) {
            StringBuilder path = new StringBuilder(32768);
            uint size = (uint)path.Capacity;
            return QueryFullProcessImageNameW(process, 0, path, ref size) ? path.ToString() : null;
        }

        public static long QueryCreationFileTime(IntPtr process) {
            FILETIME creation, exit, kernel, user;
            if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) return 0;
            ulong value = ((ulong)creation.High << 32) | creation.Low;
            return value == 0 || value > Int64.MaxValue ? 0 : (long)value;
        }
    }
}
'@
        try { Add-Type -TypeDefinition $source -ErrorAction Stop }
        catch {
            if ($null -eq ($typeName -as [type])) { throw }
        }
        $nativeType = $typeName -as [type]
    }
    if ($null -eq $nativeType -or
        $null -eq $nativeType.GetMethod('OpenProcess') -or
        $null -eq $nativeType.GetMethod('QueryImagePath') -or
        $null -eq $nativeType.GetMethod('QueryCreationFileTime') -or
        $null -eq $nativeType.GetMethod('CloseHandle')) {
        throw 'Native process identity API is unavailable.'
    }
}

function Invoke-NativeOpenProcessQueryLimited($ProcessId) {
    Initialize-NativeProcessIdentityApi
    return [ShushuCleaner.ProcessIdentityNativeV1]::OpenProcess([uint32]0x1000, $false, [uint32]$ProcessId)
}

function Invoke-NativeQueryFullProcessImageName($Handle) {
    Initialize-NativeProcessIdentityApi
    return [ShushuCleaner.ProcessIdentityNativeV1]::QueryImagePath([intptr]$Handle)
}

function Invoke-NativeGetProcessCreationTimeFileTime($Handle) {
    Initialize-NativeProcessIdentityApi
    return [ShushuCleaner.ProcessIdentityNativeV1]::QueryCreationFileTime([intptr]$Handle)
}

function Invoke-NativeCloseProcessHandle($Handle) {
    Initialize-NativeProcessIdentityApi
    return [ShushuCleaner.ProcessIdentityNativeV1]::CloseHandle([intptr]$Handle)
}

function Get-NativeIdentityStrictProcessId($Value) {
    if ($null -eq $Value) { return $null }
    if (@('System.Byte','System.SByte','System.Int16','System.UInt16','System.Int32','System.UInt32','System.Int64','System.UInt64') -cnotcontains $Value.GetType().FullName) {
        return $null
    }
    try {
        $numeric = [uint64]$Value
        if ($numeric -eq 0 -or $numeric -gt [int]::MaxValue) { return $null }
        return [int]$numeric
    } catch { return $null }
}

function Test-NativeIdentityFullyQualifiedWindowsPath($Value) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value -cne $Value.Trim()) { return $false }
    return $Value -cmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+\\)'
}

function Get-NativeProcessIdentity {
    param($ProcessId)

    $strictProcessId = Get-NativeIdentityStrictProcessId $ProcessId
    if ($null -eq $strictProcessId) { return $null }
    $handle = [intptr]::Zero
    $identity = $null
    $closed = $false
    try {
        $handle = Invoke-NativeOpenProcessQueryLimited -ProcessId $strictProcessId
        if ($handle -eq [intptr]::Zero -or $handle -eq [intptr](-1)) { return $null }
        $path = Invoke-NativeQueryFullProcessImageName -Handle $handle
        $creationFileTime = Invoke-NativeGetProcessCreationTimeFileTime -Handle $handle
        if (-not (Test-NativeIdentityFullyQualifiedWindowsPath $path) -or
            $creationFileTime -isnot [int64] -or $creationFileTime -le 0) {
            return $null
        }
        $path = [System.IO.Path]::GetFullPath([string]$path)
        if (-not [System.IO.File]::Exists($path)) { return $null }
        $name = [System.IO.Path]::GetFileName($path)
        if ([string]::IsNullOrWhiteSpace($name) -or $name -cne $name.Trim() -or
            [string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($name)) -or
            -not [string]::Equals([System.IO.Path]::GetFileName($name), $name, [System.StringComparison]::Ordinal)) {
            return $null
        }
        $start = [datetime]::FromFileTimeUtc([int64]$creationFileTime)
        if ($start.Year -lt 1970 -or $start -gt [datetime]::UtcNow) { return $null }
        $identity = [pscustomobject][ordered]@{
            PID = [int]$strictProcessId
            Name = $name
            Path = $path
            StartTimeUtc = $start.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        }
    } catch {
        $identity = $null
    } finally {
        if ($handle -ne [intptr]::Zero -and $handle -ne [intptr](-1)) {
            try { $closed = [bool](Invoke-NativeCloseProcessHandle -Handle $handle) } catch { $closed = $false }
        }
    }
    if (-not $closed) { return $null }
    return $identity
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

