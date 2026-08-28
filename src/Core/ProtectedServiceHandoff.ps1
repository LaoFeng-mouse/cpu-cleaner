# Shared fail-closed primitives for protected-service handoff evidence.

# 联想官方卸载证据只信任这两个注册表视图和明确的名称、发布者白名单。
$script:LenovoOfficialUninstallRegistryQueryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$script:LenovoOfficialUninstallRegistryRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$script:LenovoOfficialUninstallDisplayNamePrefixes = @('联想电脑管家')
$script:LenovoOfficialUninstallPublishers = @(
    '联想（北京）有限公司',
    '联想(北京)有限公司',
    'Lenovo (Beijing) Limited'
)

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

# 只允许普通本地盘符路径；拒绝设备路径、ADS、通配符和跨版本歧义字符。
function Test-StrictOfficialUninstallLocalDrivePath {
    param([string]$Path)

    if ($Path -cnotmatch '^[A-Za-z]:\\' -or
        $Path -cmatch '[/\*\?\[\]<>\|\p{Cc}]' -or
        $Path.Substring(2).Contains(':')) {
        return $false
    }
    return $true
}

# 只接受无参数、本地绝对路径的官方 EXE 命令，并返回规范化路径。
function ConvertFrom-StrictOfficialUninstallString {
    param([Parameter(Mandatory=$true)][string]$Command)

    $candidate = if ($Command -cmatch '^"([^"\r\n]+\.exe)"$') { $Matches[1] }
    elseif ($Command -cmatch '^([^"\r\n]+\.exe)$') { $Matches[1] }
    else { return $null }

    if (-not (Test-StrictOfficialUninstallLocalDrivePath -Path $candidate)) { return $null }

    try { $canonicalPath = [System.IO.Path]::GetFullPath($candidate) }
    catch { return $null }

    if (-not (Test-StrictOfficialUninstallLocalDrivePath -Path $canonicalPath)) { return $null }
    $fileName = [System.IO.Path]::GetFileName($canonicalPath).ToLowerInvariant()
    if (@('cmd.exe','powershell.exe','pwsh.exe','msiexec.exe','wscript.exe','cscript.exe') -ccontains $fileName) {
        return $null
    }
    return $canonicalPath
}

# 为所有发现失败返回固定字段顺序和固定空值。
function New-UnavailableLenovoOfficialUninstallEvidence {
    return [pscustomobject][ordered]@{
        UninstallEvidenceStatus  = 'unavailable'
        UninstallRegistryPath    = ''
        UninstallDisplayName     = ''
        UninstallPublisher       = ''
        UninstallDisplayVersion  = ''
        UninstallInstallLocation = ''
        UninstallString          = ''
        UninstallExecutablePath  = ''
    }
}

# 将注册表提供程序路径转换为可审阅的 HKLM 路径，并保留原始值类型供严格校验。
function Read-LenovoOfficialUninstallRegistryItems {
    param([Parameter(Mandatory=$true)][string[]]$Paths)

    $providerPrefix = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\'
    foreach ($path in $Paths) {
        foreach ($item in @(Get-ItemProperty -Path $path -ErrorAction Stop)) {
            $registryPath = ''
            if ($item.PSPath -is [string] -and
                $item.PSPath.StartsWith($providerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                $registryPath = 'HKLM:\' + $item.PSPath.Substring($providerPrefix.Length)
            }

            [pscustomobject]@{
                RegistryPath = $registryPath
                DisplayName = $item.DisplayName
                Publisher = $item.Publisher
                DisplayVersion = $item.DisplayVersion
                InstallLocation = $item.InstallLocation
                UninstallString = $item.UninstallString
            }
        }
    }
}

# 只接受标准 HKLM 卸载根下的一个直接子键。
function Test-LenovoOfficialUninstallRegistryPath {
    param([object]$RegistryPath)

    if ($RegistryPath -isnot [string] -or $RegistryPath.Length -eq 0) { return $false }
    foreach ($root in $script:LenovoOfficialUninstallRegistryRoots) {
        $prefix = $root + '\'
        if ($RegistryPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $subKey = $RegistryPath.Substring($prefix.Length)
            return ($subKey.Length -gt 0 -and $subKey.IndexOf('\') -lt 0)
        }
    }
    return $false
}

# 从两个标准 HKLM 卸载视图中提取唯一、完整且自洽的联想官方卸载快照。
function Get-LenovoOfficialUninstallEvidence {
    param([scriptblock]$RegistryReader)

    $unavailable = New-UnavailableLenovoOfficialUninstallEvidence
    try {
        if ($null -eq $RegistryReader) {
            $RegistryReader = { param($Paths) Read-LenovoOfficialUninstallRegistryItems -Paths $Paths }
        }

        $registryItems = @(& $RegistryReader $script:LenovoOfficialUninstallRegistryQueryPaths)
        $validCandidates = @(
            foreach ($item in $registryItems) {
                if ($null -eq $item -or
                    -not (Test-LenovoOfficialUninstallRegistryPath -RegistryPath $item.RegistryPath) -or
                    $item.DisplayName -isnot [string] -or
                    $item.Publisher -isnot [string] -or
                    $item.DisplayVersion -isnot [string] -or
                    $item.InstallLocation -isnot [string] -or
                    $item.UninstallString -isnot [string]) {
                    continue
                }

                $displayNameAllowed = $false
                foreach ($prefix in $script:LenovoOfficialUninstallDisplayNamePrefixes) {
                    if ($item.DisplayName.StartsWith($prefix, [StringComparison]::Ordinal)) {
                        $displayNameAllowed = $true
                        break
                    }
                }
                if (-not $displayNameAllowed -or
                    -not ($script:LenovoOfficialUninstallPublishers -ccontains $item.Publisher) -or
                    $item.InstallLocation.Length -eq 0 -or
                    $item.UninstallString.Length -eq 0 -or
                    -not (Test-StrictOfficialUninstallLocalDrivePath -Path $item.InstallLocation)) {
                    continue
                }

                try { $installLocation = [System.IO.Path]::GetFullPath($item.InstallLocation) }
                catch { continue }
                if (-not (Test-StrictOfficialUninstallLocalDrivePath -Path $installLocation) -or
                    -not $item.InstallLocation.Equals($installLocation, [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $executablePath = ConvertFrom-StrictOfficialUninstallString -Command $item.UninstallString
                if ($executablePath -isnot [string] -or $executablePath.Length -eq 0) { continue }

                $installRoot = $installLocation.TrimEnd('\') + '\'
                if (-not $executablePath.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                [pscustomobject][ordered]@{
                    UninstallEvidenceStatus  = 'complete'
                    UninstallRegistryPath    = $item.RegistryPath
                    UninstallDisplayName     = $item.DisplayName
                    UninstallPublisher       = $item.Publisher
                    UninstallDisplayVersion  = $item.DisplayVersion
                    UninstallInstallLocation = $installLocation
                    UninstallString          = $item.UninstallString
                    UninstallExecutablePath  = $executablePath
                }
            }
        )

        if ($validCandidates.Count -ne 1) { return $unavailable }
        return $validCandidates[0]
    }
    catch {
        return $unavailable
    }
}
