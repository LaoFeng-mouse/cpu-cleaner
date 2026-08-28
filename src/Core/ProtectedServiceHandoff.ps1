# Shared fail-closed primitives for protected-service handoff evidence.

# 初始化只读 SCM LaunchProtected 查询接口；重复调用不会重复定义类型。
function Initialize-ServiceProtectionNativeApi {
    $typeName = 'ShushuCleaner.ServiceProtectionNativeV1'
    $nativeType = $typeName -as [type]
    if ($null -eq $nativeType) {
        $source = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ShushuCleaner {
    public static class ServiceProtectionNativeV1 {
        private const uint SC_MANAGER_CONNECT = 0x0001;
        private const uint SERVICE_QUERY_CONFIG = 0x0001;
        private const uint SERVICE_CONFIG_LAUNCH_PROTECTED = 12;

        private sealed class SafeScManagerHandle : SafeHandleZeroOrMinusOneIsInvalid {
            private SafeScManagerHandle() : base(true) { }

            protected override bool ReleaseHandle() {
                return CloseServiceHandle(handle);
            }
        }

        private sealed class SafeServiceHandle : SafeHandleZeroOrMinusOneIsInvalid {
            private SafeServiceHandle() : base(true) { }

            protected override bool ReleaseHandle() {
                return CloseServiceHandle(handle);
            }
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeScManagerHandle OpenSCManagerW(
            string machineName,
            string databaseName,
            uint desiredAccess);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeServiceHandle OpenServiceW(
            SafeScManagerHandle scm,
            string serviceName,
            uint desiredAccess);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryServiceConfig2W(
            SafeServiceHandle service,
            uint infoLevel,
            IntPtr buffer,
            uint bufferSize,
            out uint bytesNeeded);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseServiceHandle(IntPtr handle);

        public static int QueryLaunchProtected(string serviceName) {
            if (String.IsNullOrEmpty(serviceName)) return -1;

            try {
                using (SafeScManagerHandle scm = OpenSCManagerW(null, null, SC_MANAGER_CONNECT)) {
                    if (scm == null || scm.IsInvalid) return -1;

                    using (SafeServiceHandle service = OpenServiceW(scm, serviceName, SERVICE_QUERY_CONFIG)) {
                        if (service == null || service.IsInvalid) return -1;

                        IntPtr buffer = Marshal.AllocHGlobal(sizeof(uint));
                        try {
                            Marshal.WriteInt32(buffer, 0);
                            uint bytesNeeded;
                            if (!QueryServiceConfig2W(
                                    service,
                                    SERVICE_CONFIG_LAUNCH_PROTECTED,
                                    buffer,
                                    sizeof(uint),
                                    out bytesNeeded)) {
                                return -1;
                            }
                            return Marshal.ReadInt32(buffer);
                        }
                        finally {
                            Marshal.FreeHGlobal(buffer);
                        }
                    }
                }
            }
            catch {
                return -1;
            }
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

    if ($null -eq $nativeType -or $null -eq $nativeType.GetMethod('QueryLaunchProtected')) {
        throw 'Native service protection API is unavailable.'
    }
}

# 调用原生边界并仅返回保护级别或失败哨兵值。
function Invoke-ServiceProtectionNativeQuery {
    param([Parameter(Mandatory=$true)][string]$ServiceName)

    Initialize-ServiceProtectionNativeApi
    return [ShushuCleaner.ServiceProtectionNativeV1]::QueryLaunchProtected($ServiceName)
}

# 将所有原生结果收窄为 complete/0..3 或 unavailable/-1。
function Get-ServiceLaunchProtectedState {
    param(
        [Parameter(Mandatory=$true)][string]$ServiceName,
        [scriptblock]$NativeQuery
    )

    $unavailable = [pscustomobject][ordered]@{ Status = 'unavailable'; Level = [int]-1 }
    try {
        if ($null -eq $NativeQuery) {
            $NativeQuery = { param($Name) Invoke-ServiceProtectionNativeQuery -ServiceName $Name }
        }
        $nativeOutput = @(& $NativeQuery $ServiceName)
        if ($nativeOutput.Count -ne 1) { return $unavailable }

        $level = $nativeOutput[0]
        if ($level -isnot [int] -or $level -lt 0 -or $level -gt 3) { return $unavailable }
        return [pscustomobject][ordered]@{ Status = 'complete'; Level = [int]$level }
    }
    catch {
        return $unavailable
    }
}

# 在 PS5.1 缺少 IsPathFullyQualified 时按盘符或 UNC 语法判断绝对路径。
function Test-StrictOfficialUninstallPathFullyQualified {
    param([string]$Path)

    try {
        $method = [System.IO.Path].GetMethod('IsPathFullyQualified', [type[]]@([string]))
        if ($null -ne $method) {
            return [bool]$method.Invoke($null, @($Path))
        }
    }
    catch {
        return $false
    }
    return $Path -cmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$))'
}

# 只接受无参数、本地绝对路径的官方 EXE 命令，并返回规范化路径。
function ConvertFrom-StrictOfficialUninstallString {
    param([Parameter(Mandatory=$true)][string]$Command)

    $candidate = if ($Command -cmatch '^"([^"\r\n]+\.exe)"$') { $Matches[1] }
    elseif ($Command -cmatch '^([^"\r\n]+\.exe)$') { $Matches[1] }
    else { return $null }

    if (-not (Test-StrictOfficialUninstallPathFullyQualified -Path $candidate) -or
        $candidate -cmatch '^\\\\') {
        return $null
    }

    try { $canonicalPath = [System.IO.Path]::GetFullPath($candidate) }
    catch { return $null }

    if ($canonicalPath -cmatch '^\\\\') { return $null }
    $fileName = [System.IO.Path]::GetFileName($canonicalPath).ToLowerInvariant()
    if (@('cmd.exe','powershell.exe','pwsh.exe','msiexec.exe','wscript.exe','cscript.exe') -ccontains $fileName) {
        return $null
    }
    return $canonicalPath
}
