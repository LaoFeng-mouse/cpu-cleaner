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
$script:LenovoUninstallerValidationCodes = @(
    'reviewed_action_invalid',
    'registry_revalidation_failed',
    'registry_binding_changed',
    'file_revalidation_failed',
    'signature_invalid',
    'signer_certificate_missing',
    'signer_organization_invalid',
    'file_identity_changed',
    'security_revalidation_failed'
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

# 显式读取 64/32 位 HKLM 视图，避免注册表提供程序随进程位数重映射。
function Read-LenovoOfficialUninstallRegistryItems {
    param([scriptblock]$OpenBaseKey)

    if ($null -eq $OpenBaseKey) {
        $OpenBaseKey = {
            param($View)
            [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine,
                $View)
        }
    }

    $relativePath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $valueOptions = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    $viewSpecs = @(
        [pscustomobject]@{
            View = [Microsoft.Win32.RegistryView]::Registry64
            SourceRoot = $script:LenovoOfficialUninstallRegistryRoots[0]
        },
        [pscustomobject]@{
            View = [Microsoft.Win32.RegistryView]::Registry32
            SourceRoot = $script:LenovoOfficialUninstallRegistryRoots[1]
        }
    )

    foreach ($viewSpec in $viewSpecs) {
        $baseKey = $null
        $uninstallKey = $null
        try {
            $baseKey = & $OpenBaseKey $viewSpec.View
            if ($null -eq $baseKey) { throw 'Registry base key is unavailable.' }

            $uninstallKey = $baseKey.OpenSubKey($relativePath, $false)
            if ($null -eq $uninstallKey) { continue }

            foreach ($subKeyName in @($uninstallKey.GetSubKeyNames())) {
                $childKey = $null
                try {
                    $childKey = $uninstallKey.OpenSubKey($subKeyName, $false)
                    if ($null -eq $childKey) { continue }

                    [pscustomobject]@{
                        RegistryPath = $viewSpec.SourceRoot + '\' + $subKeyName
                        DisplayName = $childKey.GetValue('DisplayName', $null, $valueOptions)
                        Publisher = $childKey.GetValue('Publisher', $null, $valueOptions)
                        DisplayVersion = $childKey.GetValue('DisplayVersion', $null, $valueOptions)
                        InstallLocation = $childKey.GetValue('InstallLocation', $null, $valueOptions)
                        UninstallString = $childKey.GetValue('UninstallString', $null, $valueOptions)
                    }
                }
                finally {
                    if ($null -ne $childKey) { $childKey.Dispose() }
                }
            }
        }
        finally {
            try {
                if ($null -ne $uninstallKey) { $uninstallKey.Dispose() }
            }
            finally {
                if ($null -ne $baseKey) { $baseKey.Dispose() }
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

# 将已审核来源精确映射为显式注册表视图及该视图下的逻辑子键路径。
function Resolve-LenovoOfficialUninstallExactRegistrySource {
    param([Parameter(Mandatory=$true)][string]$RegistryPath)

    $relativeRoot = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    $specs = @(
        [pscustomobject]@{
            SourceRoot = $script:LenovoOfficialUninstallRegistryRoots[0]
            View = [Microsoft.Win32.RegistryView]::Registry64
        },
        [pscustomobject]@{
            SourceRoot = $script:LenovoOfficialUninstallRegistryRoots[1]
            View = [Microsoft.Win32.RegistryView]::Registry32
        }
    )
    foreach ($spec in $specs) {
        $prefix = $spec.SourceRoot + '\'
        if (-not $RegistryPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $subKeyName = $RegistryPath.Substring($prefix.Length)
        if ($subKeyName.Length -eq 0 -or $subKeyName.IndexOf('\') -ge 0) { return $null }
        return [pscustomobject][ordered]@{
            View = $spec.View
            SubKeyPath = $relativeRoot + '\' + $subKeyName
            SourcePath = $spec.SourceRoot + '\' + $subKeyName
        }
    }
    return $null
}

# 通过显式视图只打开已审核的一个卸载子键并读取绑定字段，不枚举卸载根。
function Read-LenovoOfficialUninstallRegistryItemExact {
    param(
        [Parameter(Mandatory=$true)][Microsoft.Win32.RegistryView]$View,
        [Parameter(Mandatory=$true)][string]$SubKeyPath,
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [scriptblock]$OpenBaseKey
    )

    if ($null -eq $OpenBaseKey) {
        $OpenBaseKey = {
            param($RegistryView)
            [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine,
                $RegistryView)
        }
    }
    $valueOptions = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    $baseKey = $null
    $exactKey = $null
    try {
        $baseKey = & $OpenBaseKey $View
        if ($null -eq $baseKey) { throw 'Registry base key is unavailable.' }
        $exactKey = $baseKey.OpenSubKey($SubKeyPath, $false)
        if ($null -eq $exactKey) { return $null }
        return [pscustomobject]@{
            RegistryPath = $SourcePath
            DisplayName = $exactKey.GetValue('DisplayName', $null, $valueOptions)
            Publisher = $exactKey.GetValue('Publisher', $null, $valueOptions)
            DisplayVersion = $exactKey.GetValue('DisplayVersion', $null, $valueOptions)
            InstallLocation = $exactKey.GetValue('InstallLocation', $null, $valueOptions)
            UninstallString = $exactKey.GetValue('UninstallString', $null, $valueOptions)
        }
    }
    finally {
        try { if ($null -ne $exactKey) { $exactKey.Dispose() } }
        finally { if ($null -ne $baseKey) { $baseKey.Dispose() } }
    }
}

# 从两个标准 HKLM 卸载视图中提取唯一、完整且自洽的联想官方卸载快照。
function Get-LenovoOfficialUninstallEvidence {
    param([scriptblock]$RegistryReader)

    $unavailable = New-UnavailableLenovoOfficialUninstallEvidence
    try {
        if ($null -eq $RegistryReader) {
            $RegistryReader = { param($Paths) Read-LenovoOfficialUninstallRegistryItems }
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
                $installRootPath = [System.IO.Path]::GetPathRoot($installLocation)
                if ($installLocation.Equals($installRootPath, [StringComparison]::OrdinalIgnoreCase)) { continue }

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

# 构造严格且净化后的启动前验证结果；拒绝任意非白名单代码或字段组合。
function ConvertTo-LenovoUninstallerValidationResult {
    param(
        [ValidateSet('validated','skipped')][string]$Status,
        [string]$ExecutablePath = '',
        [string]$Code = ''
    )

    if ($Status -ceq 'validated') {
        if ([string]::IsNullOrEmpty($ExecutablePath) -or $Code.Length -ne 0) { throw 'Invalid validated result.' }
    }
    elseif ($ExecutablePath.Length -ne 0 -or $script:LenovoUninstallerValidationCodes -cnotcontains $Code) {
        throw 'Invalid skipped result.'
    }
    return [pscustomobject][ordered]@{
        Status = $Status
        ExecutablePath = $ExecutablePath
        Code = $Code
    }
}

# 初始化稳定文件身份读取所需的 Win32 API；重复调用保持幂等。
function Initialize-LenovoUninstallerFileNativeApi {
    $typeName = 'ShushuCleaner.LenovoUninstallerFileNativeV1'
    if ($null -ne ($typeName -as [type])) { return }

    $source = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ShushuCleaner {
    public sealed class LenovoUninstallerFileSnapshotV1 {
        public UInt32 VolumeSerialNumber { get; set; }
        public UInt32 FileIndexHigh { get; set; }
        public UInt32 FileIndexLow { get; set; }
        public UInt32 NumberOfLinks { get; set; }
        public Int64 Length { get; set; }
        public DateTime LastWriteTimeUtc { get; set; }
        public string FinalPath { get; set; }
        public string Sha256 { get; set; }
    }

    public static class LenovoUninstallerFileNativeV1 {
        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME_NATIVE { public UInt32 Low; public UInt32 High; }

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION {
            public UInt32 FileAttributes;
            public FILETIME_NATIVE CreationTime;
            public FILETIME_NATIVE LastAccessTime;
            public FILETIME_NATIVE LastWriteTime;
            public UInt32 VolumeSerialNumber;
            public UInt32 FileSizeHigh;
            public UInt32 FileSizeLow;
            public UInt32 NumberOfLinks;
            public UInt32 FileIndexHigh;
            public UInt32 FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file, out BY_HANDLE_FILE_INFORMATION information);

        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern UInt32 GetFinalPathNameByHandleW(
            SafeFileHandle file, StringBuilder path, UInt32 pathLength, UInt32 flags);

        private static string NormalizeFinalDosPath(SafeFileHandle handle) {
            UInt32 capacity = 512;
            for (int attempt = 0; attempt < 3; attempt++) {
                StringBuilder buffer = new StringBuilder((int)capacity);
                UInt32 length = GetFinalPathNameByHandleW(handle, buffer, capacity, 0);
                if (length == 0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                if (length < capacity) {
                    string result = buffer.ToString();
                    if (result.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
                        throw new IOException("UNC final paths are not allowed.");
                    if (result.StartsWith(@"\\?\", StringComparison.Ordinal)) result = result.Substring(4);
                    if (result.Length < 3 || !Char.IsLetter(result[0]) || result[1] != ':' || result[2] != '\\')
                        throw new IOException("Final path is not a DOS drive path.");
                    return Path.GetFullPath(result);
                }
                capacity = length + 1;
            }
            throw new IOException("Final path is unavailable.");
        }

        private static void RejectReparseComponents(string fullPath) {
            string root = Path.GetPathRoot(fullPath);
            if (String.IsNullOrEmpty(root)) throw new IOException("Path root is unavailable.");
            string current = root;
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("A reparse component is not allowed.");
            string remainder = fullPath.Substring(root.Length);
            foreach (string component in remainder.Split(new char[] {'\\'}, StringSplitOptions.RemoveEmptyEntries)) {
                current = Path.Combine(current, component);
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("A reparse component is not allowed.");
            }
        }

        public static LenovoUninstallerFileSnapshotV1 Capture(string path) {
            if (String.IsNullOrEmpty(path)) throw new ArgumentException("Path is required.", "path");
            string fullPath = Path.GetFullPath(path);
            if (fullPath.Length < 3 || !Char.IsLetter(fullPath[0]) || fullPath[1] != ':' || fullPath[2] != '\\')
                throw new IOException("Only DOS drive paths are allowed.");
            RejectReparseComponents(fullPath);
            if ((File.GetAttributes(fullPath) & FileAttributes.Directory) != 0)
                throw new IOException("Directories are not allowed.");

            using (FileStream stream = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                BY_HANDLE_FILE_INFORMATION info;
                if (!GetFileInformationByHandle(stream.SafeFileHandle, out info))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                if ((info.FileAttributes & (UInt32)FileAttributes.Directory) != 0)
                    throw new IOException("Directories are not allowed.");
                if ((info.FileAttributes & (UInt32)FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Reparse files are not allowed.");
                if (info.NumberOfLinks != 1) throw new IOException("File link count is not one.");

                string finalPath = NormalizeFinalDosPath(stream.SafeFileHandle);
                Int64 length = ((Int64)info.FileSizeHigh << 32) | info.FileSizeLow;
                Int64 writeFileTime = ((Int64)info.LastWriteTime.High << 32) | info.LastWriteTime.Low;
                stream.Position = 0;
                byte[] digest;
                using (SHA256 sha = SHA256.Create()) { digest = sha.ComputeHash(stream); }

                return new LenovoUninstallerFileSnapshotV1 {
                    VolumeSerialNumber = info.VolumeSerialNumber,
                    FileIndexHigh = info.FileIndexHigh,
                    FileIndexLow = info.FileIndexLow,
                    NumberOfLinks = info.NumberOfLinks,
                    Length = length,
                    LastWriteTimeUtc = DateTime.FromFileTimeUtc(writeFileTime),
                    FinalPath = finalPath,
                    Sha256 = BitConverter.ToString(digest).Replace("-", String.Empty)
                };
            }
        }
    }
}
'@
    try { Add-Type -TypeDefinition $source -ErrorAction Stop }
    catch { if ($null -eq ($typeName -as [type])) { throw } }
}

# 从同一个只读共享句柄捕获文件身份、元数据、最终路径和 SHA256。
function Get-StableLenovoUninstallerFileSnapshot {
    param([Parameter(Mandatory=$true)][string]$Path)

    Initialize-LenovoUninstallerFileNativeApi
    return [ShushuCleaner.LenovoUninstallerFileNativeV1]::Capture($Path)
}

# 读取一个严格 DER TLV；拒绝不定长、非最短长度及越界数据。
function Read-LenovoSignerDerElement {
    param([byte[]]$Data, [int]$Offset, [int]$End)

    if ($null -eq $Data -or $Offset -lt 0 -or $End -gt $Data.Length -or $Offset + 2 -gt $End) {
        throw 'Invalid DER element.'
    }
    $tag = [int]$Data[$Offset]
    $cursor = $Offset + 1
    $firstLength = [int]$Data[$cursor]
    $cursor++
    if (($firstLength -band 0x80) -eq 0) {
        $length = $firstLength
    }
    else {
        $lengthBytes = $firstLength -band 0x7F
        if ($lengthBytes -eq 0 -or $lengthBytes -gt 4 -or $cursor + $lengthBytes -gt $End -or
            $Data[$cursor] -eq 0) { throw 'Invalid DER length.' }
        [uint64]$wideLength = 0
        for ($i = 0; $i -lt $lengthBytes; $i++) {
            $wideLength = ($wideLength -shl 8) -bor [uint64]$Data[$cursor + $i]
        }
        if ($wideLength -lt 128 -or $wideLength -gt [int]::MaxValue) { throw 'Invalid DER length.' }
        $length = [int]$wideLength
        $cursor += $lengthBytes
    }
    if ($length -lt 0 -or $cursor + $length -gt $End) { throw 'Truncated DER element.' }
    return [pscustomobject][ordered]@{
        Tag = $tag
        ContentOffset = $cursor
        ContentLength = $length
        NextOffset = $cursor + $length
    }
}

# 从编码后的 X.500 RDNSequence 中提取唯一的 Organization OID 2.5.4.10。
function Get-X500OrganizationAttributeFromRawData {
    param([Parameter(Mandatory=$true)][byte[]]$RawData)

    if ($RawData.Length -eq 0 -or $RawData.Length -gt 16384) { return @() }
    try {
        $outer = Read-LenovoSignerDerElement $RawData 0 $RawData.Length
        if ($outer.Tag -ne 0x30 -or $outer.NextOffset -ne $RawData.Length) { return @() }
        $organizations = [System.Collections.Generic.List[string]]::new()
        $rdnOffset = $outer.ContentOffset
        while ($rdnOffset -lt $outer.NextOffset) {
            $set = Read-LenovoSignerDerElement $RawData $rdnOffset $outer.NextOffset
            if ($set.Tag -ne 0x31) { return @() }
            $attributeOffset = $set.ContentOffset
            while ($attributeOffset -lt $set.NextOffset) {
                $attribute = Read-LenovoSignerDerElement $RawData $attributeOffset $set.NextOffset
                if ($attribute.Tag -ne 0x30) { return @() }
                $oid = Read-LenovoSignerDerElement $RawData $attribute.ContentOffset $attribute.NextOffset
                if ($oid.Tag -ne 0x06) { return @() }
                $value = Read-LenovoSignerDerElement $RawData $oid.NextOffset $attribute.NextOffset
                if ($value.NextOffset -ne $attribute.NextOffset) { return @() }
                $isOrganization = ($oid.ContentLength -eq 3 -and
                    $RawData[$oid.ContentOffset] -eq 0x55 -and
                    $RawData[$oid.ContentOffset + 1] -eq 0x04 -and
                    $RawData[$oid.ContentOffset + 2] -eq 0x0A)
                if ($isOrganization) {
                    $bytes = [byte[]]::new($value.ContentLength)
                    [Array]::Copy($RawData, $value.ContentOffset, $bytes, 0, $value.ContentLength)
                    switch ($value.Tag) {
                        0x0C { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
                        0x13 {
                            foreach ($b in $bytes) { if ($b -lt 0x20 -or $b -gt 0x7E) { throw 'Invalid PrintableString.' } }
                            $text = [System.Text.Encoding]::ASCII.GetString($bytes)
                        }
                        0x1E {
                            if (($bytes.Length % 2) -ne 0) { throw 'Invalid BMPString.' }
                            $text = [System.Text.UnicodeEncoding]::new($true, $false, $true).GetString($bytes)
                        }
                        default { return @() }
                    }
                    $organizations.Add($text)
                    if ($organizations.Count -gt 1) { return @() }
                }
                $attributeOffset = $attribute.NextOffset
            }
            if ($attributeOffset -ne $set.NextOffset) { return @() }
            $rdnOffset = $set.NextOffset
        }
        if ($rdnOffset -ne $outer.NextOffset) { return @() }
        return $organizations.ToArray()
    }
    catch { return @() }
}

# 只允许明确列出的联想北京签名组织名。
function Test-LenovoSignerOrganization {
    param([Parameter(Mandatory=$true)]$Certificate)

    try {
        $rawData = $Certificate.SubjectName.RawData
        if ($Certificate.PSObject.Properties.Name -cnotcontains 'SubjectName' -or
            $null -eq $Certificate.SubjectName -or
            $Certificate.SubjectName.PSObject.Properties.Name -cnotcontains 'RawData' -or
            $null -eq $rawData) { return $false }
        if ($rawData -isnot [byte[]]) {
            if (($rawData -is [System.Collections.IEnumerable]) -and -not ($rawData -is [string])) {
                try { $rawData = [byte[]]$rawData }
                catch { return $false }
            } else {
                return $false
            }
        }
        $organizations = @(Get-X500OrganizationAttributeFromRawData -RawData $rawData)
        if ($organizations.Count -ne 1) { return $false }
        $organization = $organizations[0].Trim()
        if ($organization -ceq '联想（北京）有限公司') { return $true }
        return ($organization.Equals('LENOVO (BEIJING) LIMITED', [StringComparison]::OrdinalIgnoreCase) -or
            $organization.Equals('Lenovo (Beijing) Limited', [StringComparison]::OrdinalIgnoreCase))
    }
    catch { return $false }
}

# 验证单份文件快照结构、单链接约束及最终路径安装根边界。
function Test-StableLenovoUninstallerSnapshot {
    param($Snapshot, [Parameter(Mandatory=$true)][string]$ReviewedInstallRoot)

    $required = @('VolumeSerialNumber','FileIndexHigh','FileIndexLow','NumberOfLinks','Length','LastWriteTimeUtc','FinalPath','Sha256')
    if ($null -eq $Snapshot) { return $false }
    foreach ($name in $required) {
        if ($Snapshot.PSObject.Properties.Name -cnotcontains $name) { return $false }
    }
    if ([uint64]$Snapshot.NumberOfLinks -ne 1 -or $Snapshot.Length -isnot [long] -or
        $Snapshot.LastWriteTimeUtc -isnot [datetime] -or $Snapshot.FinalPath -isnot [string] -or
        $Snapshot.Sha256 -isnot [string] -or $Snapshot.Sha256 -cnotmatch '^[0-9A-F]{64}$') { return $false }

    try {
        $root = [System.IO.Path]::GetFullPath($ReviewedInstallRoot).TrimEnd('\') + '\'
        $finalPath = [System.IO.Path]::GetFullPath($Snapshot.FinalPath)
    }
    catch { return $false }
    return $finalPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

# 比较两次快照的稳定文件身份、元数据、最终路径和摘要。
function Test-LenovoUninstallerSnapshotMatch {
    param($Before, $After)

    return ([uint64]$Before.VolumeSerialNumber -eq [uint64]$After.VolumeSerialNumber -and
        [uint64]$Before.FileIndexHigh -eq [uint64]$After.FileIndexHigh -and
        [uint64]$Before.FileIndexLow -eq [uint64]$After.FileIndexLow -and
        [int64]$Before.Length -eq [int64]$After.Length -and
        $Before.LastWriteTimeUtc.ToUniversalTime().Ticks -eq $After.LastWriteTimeUtc.ToUniversalTime().Ticks -and
        $Before.FinalPath.Equals($After.FinalPath, [StringComparison]::OrdinalIgnoreCase) -and
        $Before.Sha256.Equals($After.Sha256, [StringComparison]::Ordinal))
}

# 执行共享的启动前失败关闭验证，并可向 handoff 返回最后一份可信快照。
function Invoke-ReviewedLenovoUninstallerValidationCore {
    param(
        [Parameter(Mandatory=$true)]$Action,
        [scriptblock]$RegistryReader,
        [scriptblock]$FileSnapshotReader,
        [scriptblock]$SignatureReader,
        [ref]$ValidatedSnapshot
    )

    $skip = { param($Code) ConvertTo-LenovoUninstallerValidationResult -Status skipped -Code $Code }
    try {
        $requiredFields = @(
            'action','uninstall_evidence_status','uninstall_registry_path','uninstall_display_name',
            'uninstall_publisher','uninstall_display_version','uninstall_install_location',
            'uninstall_string','uninstall_executable_path'
        )
        if ($null -eq $Action) { return & $skip 'reviewed_action_invalid' }
        foreach ($field in $requiredFields) {
            if ($Action.PSObject.Properties.Name -cnotcontains $field -or $Action.$field -isnot [string]) {
                return & $skip 'reviewed_action_invalid'
            }
        }
        if ($Action.action -cne 'open_official_uninstaller' -or $Action.uninstall_evidence_status -cne 'complete') {
            return & $skip 'reviewed_action_invalid'
        }

        $exactSource = Resolve-LenovoOfficialUninstallExactRegistrySource -RegistryPath $Action.uninstall_registry_path
        if ($null -eq $exactSource) { return & $skip 'registry_revalidation_failed' }
        if ($null -eq $RegistryReader) {
            $RegistryReader = {
                param($View, $SubKeyPath, $SourcePath)
                Read-LenovoOfficialUninstallRegistryItemExact `
                    -View $View -SubKeyPath $SubKeyPath -SourcePath $SourcePath
            }
        }
        $reviewedSourceItems = @(& $RegistryReader $exactSource.View $exactSource.SubKeyPath $exactSource.SourcePath)
        if ($reviewedSourceItems.Count -ne 1) { return & $skip 'registry_revalidation_failed' }
        $current = Get-LenovoOfficialUninstallEvidence -RegistryReader {
            param($Paths)
            $null = $Paths
            $reviewedSourceItems[0]
        }.GetNewClosure()
        if ($current.UninstallEvidenceStatus -cne 'complete') { return & $skip 'registry_revalidation_failed' }
        $pathBindings = @(
            @($Action.uninstall_registry_path, $current.UninstallRegistryPath),
            @($Action.uninstall_install_location, $current.UninstallInstallLocation),
            @($Action.uninstall_executable_path, $current.UninstallExecutablePath)
        )
        foreach ($binding in $pathBindings) {
            if (-not $binding[0].Equals($binding[1], [StringComparison]::OrdinalIgnoreCase)) {
                return & $skip 'registry_binding_changed'
            }
        }
        $valueBindings = @(
            @($Action.uninstall_display_name, $current.UninstallDisplayName),
            @($Action.uninstall_publisher, $current.UninstallPublisher),
            @($Action.uninstall_display_version, $current.UninstallDisplayVersion),
            @($Action.uninstall_string, $current.UninstallString)
        )
        foreach ($binding in $valueBindings) {
            if (-not $binding[0].Equals($binding[1], [StringComparison]::Ordinal)) {
                return & $skip 'registry_binding_changed'
            }
        }

        if ($null -eq $FileSnapshotReader) {
            $FileSnapshotReader = { param($Path) Get-StableLenovoUninstallerFileSnapshot -Path $Path }
        }
        $before = & $FileSnapshotReader $current.UninstallExecutablePath
        if (-not (Test-StableLenovoUninstallerSnapshot $before $current.UninstallInstallLocation)) {
            return & $skip 'file_revalidation_failed'
        }

        if ($null -eq $SignatureReader) {
            $SignatureReader = { param($Path) Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop }
        }
        $signature = & $SignatureReader $current.UninstallExecutablePath
        if ($null -eq $signature -or $signature.PSObject.Properties.Name -cnotcontains 'Status' -or
            $signature.Status.ToString() -cne 'Valid') { return & $skip 'signature_invalid' }
        if ($signature.PSObject.Properties.Name -cnotcontains 'SignerCertificate' -or
            $null -eq $signature.SignerCertificate) { return & $skip 'signer_certificate_missing' }
        if (-not (Test-LenovoSignerOrganization $signature.SignerCertificate)) {
            return & $skip 'signer_organization_invalid'
        }

        $after = & $FileSnapshotReader $current.UninstallExecutablePath
        if (-not (Test-StableLenovoUninstallerSnapshot $after $current.UninstallInstallLocation) -or
            -not (Test-LenovoUninstallerSnapshotMatch $before $after)) {
            return & $skip 'file_identity_changed'
        }
        if ($null -ne $ValidatedSnapshot) { $ValidatedSnapshot.Value = $after }
        return ConvertTo-LenovoUninstallerValidationResult -Status validated -ExecutablePath $after.FinalPath
    }
    catch {
        return & $skip 'security_revalidation_failed'
    }
}

# 公开验证接缝：仅返回 validated/canonical path 或 skipped/固定代码。
function Test-ReviewedLenovoUninstaller {
    param(
        [Parameter(Mandatory=$true)]$Action,
        [scriptblock]$RegistryReader,
        [scriptblock]$FileSnapshotReader,
        [scriptblock]$SignatureReader
    )

    return Invoke-ReviewedLenovoUninstallerValidationCore -Action $Action -RegistryReader $RegistryReader `
        -FileSnapshotReader $FileSnapshotReader -SignatureReader $SignatureReader
}

# 构造不含原始路径或异常的终态 handoff 结果。
function ConvertTo-LenovoUninstallerHandoffResult {
    param(
        [ValidateSet('manual_required','skipped','failed')][string]$Status,
        [Parameter(Mandatory=$true)][string]$Reason,
        [string]$FailureStage = ''
    )
    return [pscustomobject][ordered]@{
        status = $Status
        result_reason = $Reason
        failure_stage = $FailureStage
    }
}

# 通过第三次即时快照后仅打开已验证路径，并净化所有终态结果。
function Invoke-ReviewedLenovoUninstallerHandoff {
    param(
        [Parameter(Mandatory=$true)]$Action,
        [scriptblock]$RegistryReader,
        [scriptblock]$FileSnapshotReader,
        [scriptblock]$SignatureReader,
        [scriptblock]$Launcher
    )

    $validatedSnapshot = $null
    $validated = Invoke-ReviewedLenovoUninstallerValidationCore -Action $Action -RegistryReader $RegistryReader `
        -FileSnapshotReader $FileSnapshotReader -SignatureReader $SignatureReader `
        -ValidatedSnapshot ([ref]$validatedSnapshot)
    if ($validated.Status -cne 'validated') {
        return ConvertTo-LenovoUninstallerHandoffResult -Status skipped -Reason '启动前安全复核失败，请重新扫描后再试'
    }

    try {
        if ($null -eq $FileSnapshotReader) {
            $FileSnapshotReader = { param($Path) Get-StableLenovoUninstallerFileSnapshot -Path $Path }
        }
        $finalSnapshot = & $FileSnapshotReader $validated.ExecutablePath
        if (-not (Test-StableLenovoUninstallerSnapshot $finalSnapshot $Action.uninstall_install_location) -or
            -not (Test-LenovoUninstallerSnapshotMatch $validatedSnapshot $finalSnapshot)) {
            return ConvertTo-LenovoUninstallerHandoffResult -Status skipped -Reason '启动前安全复核失败，请重新扫描后再试'
        }
    }
    catch {
        return ConvertTo-LenovoUninstallerHandoffResult -Status skipped -Reason '启动前安全复核失败，请重新扫描后再试'
    }

    try {
        if ($null -eq $Launcher) {
            $null = Start-Process -FilePath $validated.ExecutablePath -PassThru -ErrorAction Stop
        }
        else {
            $null = & $Launcher $validated.ExecutablePath
        }
        return ConvertTo-LenovoUninstallerHandoffResult -Status manual_required `
            -Reason '联想官方卸载程序已打开，请在其中确认或取消'
    }
    catch {
        return ConvertTo-LenovoUninstallerHandoffResult -Status failed `
            -Reason '无法启动联想官方卸载程序' -FailureStage launch
    }
}
