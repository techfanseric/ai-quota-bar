// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：Keychain（SecItem）→ Credential Manager（CredReadW/CredWriteW/CredDeleteW））
// 对应测试：windows/tests/AIQuotaBar.Platform.Tests/Credentials/CredentialStoreTests.cs
//
// P/Invoke 依据（Microsoft Learn，wincred.h）：
// - CREDENTIALW 字段顺序：Flags, Type, TargetName, Comment, LastWritten(FILETIME),
//   CredentialBlobSize, CredentialBlob, Persist, AttributeCount, Attributes, TargetAlias, UserName。
// - CRED_TYPE_GENERIC = 1；CRED_PERSIST_LOCAL_MACHINE = 2；
//   CredentialBlobSize ≤ CRED_MAX_CREDENTIAL_BLOB_SIZE（5*512 = 2560 字节）。
// - CredWriteW(cred, 0) / CredReadW(target, type, 0, &ptr) / CredDeleteW(target, type, 0)；
//   CredRead 的出参缓冲须用 CredFree 释放；目标不存在时 last error = ERROR_NOT_FOUND(1168)。

#nullable enable

using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace AIQuotaBar.Platform.Credentials;

/// <summary>
/// 基于 Windows Credential Manager（advapi32）的凭据存储，实现 <see cref="ICredentialStore"/>。
/// </summary>
/// <remarks>
/// macOS 端对应物：Keychain 中的 generic password（service + account 唯一定位一条 SecItem）。
/// 这里用 <c>AIQuotaBar:{service}:{account}</c> 作为 GENERIC 凭据的 TargetName（微软建议
/// 以产品名作前缀避免冲突，见 wincred.h TargetName 备注），账户另存入 UserName 字段，
/// 密钥以 UTF-8 字节存入 CredentialBlob，Persist 采用 CRED_PERSIST_LOCAL_MACHINE
/// （本机所有后续登录会话可用，不漫游）。
/// </remarks>
public sealed class CredentialStore : ICredentialStore
{
    /// <summary>TargetName 前缀，保证本应用凭据命名空间独立。</summary>
    public const string TargetNamePrefix = "AIQuotaBar";

    private const uint CredTypeGeneric = 1;
    private const uint CredPersistLocalMachine = 2;
    private const int MaxCredentialBlobSize = 5 * 512; // CRED_MAX_CREDENTIAL_BLOB_SIZE
    private const int ErrorNotFound = 1168;            // ERROR_NOT_FOUND

    /// <inheritdoc />
    public string? Read(string service, string account)
    {
        var targetName = BuildTargetName(service, account);
        if (!NativeMethods.CredReadW(targetName, CredTypeGeneric, 0, out var credentialPtr))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound)
            {
                return null; // 应然：未写入过（Swift SecItemCopyMatching errSecItemNotFound 的对应语义）
            }

            throw new Win32Exception(error, $"CredReadW 失败：{targetName}");
        }

        try
        {
            var credential = Marshal.PtrToStructure<NativeMethods.Credential>(credentialPtr);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
            {
                return string.Empty;
            }

            var blob = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, blob, 0, blob.Length);
            return Encoding.UTF8.GetString(blob);
        }
        finally
        {
            NativeMethods.CredFree(credentialPtr);
        }
    }

    /// <inheritdoc />
    public void Write(string service, string account, string secret)
    {
        ValidateSegments(service, account);
        var secretBytes = Encoding.UTF8.GetBytes(secret);
        if (secretBytes.Length > MaxCredentialBlobSize)
        {
            throw new ArgumentOutOfRangeException(
                nameof(secret),
                $"密钥 UTF-8 长度 {secretBytes.Length} 超过 Credential Manager 上限 {MaxCredentialBlobSize} 字节。");
        }

        var targetName = BuildTargetName(service, account);
        var blobPtr = IntPtr.Zero;
        try
        {
            if (secretBytes.Length > 0)
            {
                blobPtr = Marshal.AllocHGlobal(secretBytes.Length);
                Marshal.Copy(secretBytes, 0, blobPtr, secretBytes.Length);
            }

            var credential = new NativeMethods.Credential
            {
                Flags = 0,
                Type = CredTypeGeneric,
                TargetName = targetName,
                Comment = null,
                LastWritten = 0,           // 写入时忽略
                CredentialBlobSize = (uint)secretBytes.Length,
                CredentialBlob = blobPtr,
                Persist = CredPersistLocalMachine,
                AttributeCount = 0,
                Attributes = IntPtr.Zero,
                TargetAlias = null,
                UserName = account.Length == 0 ? null : account,
            };

            if (!NativeMethods.CredWriteW(ref credential, 0))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"CredWriteW 失败：{targetName}");
            }
        }
        finally
        {
            if (blobPtr != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(blobPtr);
            }
        }
    }

    /// <inheritdoc />
    public bool Delete(string service, string account)
    {
        var targetName = BuildTargetName(service, account);
        if (NativeMethods.CredDeleteW(targetName, CredTypeGeneric, 0))
        {
            return true;
        }

        var error = Marshal.GetLastWin32Error();
        if (error == ErrorNotFound)
        {
            return false; // 应然：本就不存在（Swift SecItemDelete errSecItemItemNotFound 的对应语义）
        }

        throw new Win32Exception(error, $"CredDeleteW 失败：{targetName}");
    }

    /// <summary>组合 Credential Manager TargetName：<c>AIQuotaBar:{service}:{account}</c>。</summary>
    private static string BuildTargetName(string service, string account)
    {
        ValidateSegments(service, account);
        return $"{TargetNamePrefix}:{service}:{account}";
    }

    /// <summary>
    /// 枚举本应用命名空间下的凭据条目（不含密钥本体）。
    /// <paramref name="servicePrefix"/> 为 null 时列出全部 <c>AIQuotaBar:*</c> 条目，
    /// 否则按 <c>AIQuotaBar:{servicePrefix}:*</c> 前缀过滤。
    /// </summary>
    /// <remarks>
    /// Swift 来源：无（Windows 端新增；CLI「cred list」与设置页账户列表的数据源）。
    /// CredEnumerateW 的 Filter 参数支持前缀通配（wincred.h），无匹配时 last error =
    /// ERROR_NOT_FOUND（1168），映射为空列表而非异常。返回的指针数组须整块 CredFree。
    /// 注意：与 Read/Write/Delete 一样，网络登录会话（如 OpenSSH）下会因凭据保管库
    /// 不可用而抛 Win32Exception —— 调用方（CLI env 探测）依赖此行为诊断会话类型。
    /// </remarks>
    public IReadOnlyList<CredentialEntry> Enumerate(string? servicePrefix = null)
    {
        var filter = servicePrefix is null
            ? $"{TargetNamePrefix}:*"
            : $"{TargetNamePrefix}:{servicePrefix}:*";
        if (!NativeMethods.CredEnumerateW(filter, 0, out var count, out var buffer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound)
            {
                return Array.Empty<CredentialEntry>(); // 应然：无匹配（非异常，Swift 无对应语义差异）
            }

            throw new Win32Exception(error, $"CredEnumerateW 失败：{filter}");
        }

        try
        {
            var entries = new List<CredentialEntry>((int)count);
            for (var i = 0; i < count; i++)
            {
                var credentialPtr = Marshal.ReadIntPtr(buffer, i * IntPtr.Size);
                var credential = Marshal.PtrToStructure<NativeMethods.Credential>(credentialPtr);
                if (credential.TargetName is null)
                {
                    continue;
                }

                var parsed = ParseTargetName(credential.TargetName);
                if (parsed is null)
                {
                    continue; // 前缀匹配但形状异常（手工造的条目）：跳过而非失败
                }

                entries.Add(new CredentialEntry(parsed.Value.Service, parsed.Value.Account, credential.UserName));
            }

            return entries;
        }
        finally
        {
            NativeMethods.CredFree(buffer);
        }
    }

    /// <summary>把 <c>AIQuotaBar:{service}:{account}</c> 拆回二元组；非本应用形状返回 null。</summary>
    private static (string Service, string Account)? ParseTargetName(string targetName)
    {
        var prefix = TargetNamePrefix + ":";
        if (!targetName.StartsWith(prefix, StringComparison.Ordinal))
        {
            return null;
        }

        var rest = targetName[prefix.Length..];
        var separator = rest.IndexOf(':');
        return separator < 0 ? null : (rest[..separator], rest[(separator + 1)..]);
    }

    /// <summary>
    /// 校验服务名/账户段：非空（服务）、不含分隔符 <c>':'</c>——
    /// 保证 (service, account) 二元组到 TargetName 的映射无歧义。
    /// </summary>
    private static void ValidateSegments(string service, string account)
    {
        if (string.IsNullOrEmpty(service))
        {
            throw new ArgumentException("服务名不可为空。", nameof(service));
        }

        if (service.Contains(':'))
        {
            throw new ArgumentException($"服务名不可包含分隔符 ':'（实然：\"{service}\"）。", nameof(service));
        }

        if (account is null)
        {
            throw new ArgumentException("账户不可为 null（允许空字符串表示无账户维度）。", nameof(account));
        }

        if (account.Contains(':'))
        {
            throw new ArgumentException($"账户不可包含分隔符 ':'（实然：\"{account}\"）。", nameof(account));
        }
    }

    /// <summary>advapi32 Credential Manager 原生入口（签名按 wincred.h 逐字段核对）。</summary>
    private static class NativeMethods
    {
        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CredReadW(
            string targetName,
            uint type,
            uint flags,
            out IntPtr credential);

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CredWriteW(
            ref Credential credential,
            uint flags);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CredDeleteW(
            string targetName,
            uint type,
            uint flags);

        [DllImport("advapi32.dll", EntryPoint = "CredEnumerateW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CredEnumerateW(
            string? filter,
            uint flags,
            out uint count,
            out IntPtr credentials);

        [DllImport("advapi32.dll", EntryPoint = "CredFree")]
        public static extern void CredFree(IntPtr buffer);

        /// <summary>wincred.h CREDENTIALW（Unicode）。字段顺序与原生一致，Sequential 布局。</summary>
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct Credential
        {
            public uint Flags;
            public uint Type;
            public string? TargetName;
            public string? Comment;
            public long LastWritten;          // FILETIME（写入时忽略）
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;     // LPBYTE：手工 AllocHGlobal/Copy，避免数组封送歧义
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;         // PCREDENTIAL_ATTRIBUTEW，本层未用
            public string? TargetAlias;
            public string? UserName;
        }
    }
}
