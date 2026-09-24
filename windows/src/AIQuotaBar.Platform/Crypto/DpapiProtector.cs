// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：CryptoKit/CommonCrypto 的部分场景（Kimi safeStorage 等）→ DPAPI）
// 对应测试：windows/tests/AIQuotaBar.Platform.Tests/Crypto/DpapiProtectorTests.cs
//
// P/Invoke 依据（Microsoft Learn，dpapi.h / wincrypt.h DATA_BLOB）：
// - DATA_BLOB { DWORD cbData; BYTE *pbData; }。
// - BOOL CryptProtectData(DATA_BLOB *pDataIn, LPCWSTR szDataDescr, DATA_BLOB *pOptionalEntropy,
//   PVOID pvReserved, CRYPTPROTECT_PROMPTSTRUCT *pPromptStruct, DWORD dwFlags, DATA_BLOB *pDataOut)；
//   CryptUnprotectData 同形（第 2 参改为出参描述字符串）。crypt32.dll。
// - 出参 pbData 由 DPAPI 以 LocalAlloc 分配，调用方须 LocalFree 释放。
// - CRYPTPROTECT_UI_FORBIDDEN = 0x1（无 UI 场景，服务/后台进程必备）；
//   密文内含 MAC（防篡改），密钥绑定当前用户 + 本机。

#nullable enable

using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace AIQuotaBar.Platform.Crypto;

/// <summary>
/// Windows DPAPI（crypt32 CryptProtectData / CryptUnprotectData）封装：
/// 当前用户作用域的对称保护，用于无需跨机漫游的本地敏感数据。
/// </summary>
/// <remarks>
/// macOS 端没有单一对应物：Swift 端凭据走 Keychain，Kimi safeStorage 缓存在 Windows 上
/// 恰好就是 DPAPI（计划 §4「CryptoKit/CommonCrypto」行、§5.4 相关风险）。本类提供
/// byte[] 与 UTF-8 string（Base64 输出，便于落盘/入库）两种门面。与 Keychain 不同，
/// DPAPI 不自带存储——密文的持久化位置由调用方决定。
/// 绑定当前登录用户与机器；同机同用户即可解密，故只适合「本地缓存」，不适合当凭据库主存储。
/// </remarks>
public sealed class DpapiProtector
{
    private const uint CryptProtectUiForbidden = 0x1;

    /// <summary>
    /// 保护字节数组。返回的密文为 DPAPI 独立 blob（含盐与 MAC），
    /// 对同一明文的多次调用产生不同密文。
    /// </summary>
    /// <param name="plaintext">待保护明文，须非空。</param>
    /// <exception cref="ArgumentNullException"><paramref name="plaintext"/> 为 null。</exception>
    /// <exception cref="ArgumentException"><paramref name="plaintext"/> 长度为 0。</exception>
    /// <exception cref="CryptographicException">DPAPI 调用失败（GetLastError 映射）。</exception>
    public byte[] Protect(byte[] plaintext)
    {
        if (plaintext is null)
        {
            throw new ArgumentNullException(nameof(plaintext));
        }

        if (plaintext.Length == 0)
        {
            throw new ArgumentException("明文不可为空字节组。", nameof(plaintext));
        }

        return Transform(plaintext, protect: true);
    }

    /// <summary>
    /// 解除保护，还原明文字节数组。
    /// </summary>
    /// <param name="encrypted">CryptProtectData 输出的密文 blob。</param>
    /// <exception cref="CryptographicException">密文非法、被篡改或非本用户/本机加密。</exception>
    public byte[] Unprotect(byte[] encrypted)
    {
        if (encrypted is null)
        {
            throw new ArgumentNullException(nameof(encrypted));
        }

        if (encrypted.Length == 0)
        {
            throw new ArgumentException("密文不可为空字节组。", nameof(encrypted));
        }

        return Transform(encrypted, protect: false);
    }

    /// <summary>
    /// 保护 UTF-8 字符串，输出 Base64 文本（便于直接写入 JSON/配置文件）。
    /// </summary>
    /// <param name="plaintext">待保护明文，须非空。</param>
    /// <exception cref="CryptographicException">DPAPI 调用失败。</exception>
    public string Protect(string plaintext)
    {
        if (plaintext is null)
        {
            throw new ArgumentNullException(nameof(plaintext));
        }

        var protectedBytes = Protect(Encoding.UTF8.GetBytes(plaintext));
        return Convert.ToBase64String(protectedBytes);
    }

    /// <summary>
    /// 解除保护 Base64 文本（<see cref="Protect(string)"/> 的逆操作），还原 UTF-8 字符串。
    /// </summary>
    /// <param name="protectedText">Base64 密文。</param>
    /// <exception cref="FormatException">入参不是合法 Base64。</exception>
    /// <exception cref="CryptographicException">解密失败（篡改/跨用户/跨机）。</exception>
    public string Unprotect(string protectedText)
    {
        if (protectedText is null)
        {
            throw new ArgumentNullException(nameof(protectedText));
        }

        var plaintextBytes = Unprotect(Convert.FromBase64String(protectedText));
        return Encoding.UTF8.GetString(plaintextBytes);
    }

    /// <summary>CryptProtectData / CryptUnprotectData 的公共骨架。</summary>
    private byte[] Transform(byte[] input, bool protect)
    {
        var inputHandle = GCHandle.Alloc(input, GCHandleType.Pinned);
        byte[] result;
        try
        {
            var dataIn = new NativeMethods.DataBlob
            {
                CbData = (uint)input.Length,
                PbData = inputHandle.AddrOfPinnedObject(),
            };

            var dataOut = default(NativeMethods.DataBlob);
            var descriptionPtr = IntPtr.Zero;
            try
            {
                var succeeded = protect
                    ? NativeMethods.CryptProtectData(
                        ref dataIn, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                        CryptProtectUiForbidden, ref dataOut)
                    : NativeMethods.CryptUnprotectData(
                        ref dataIn, ref descriptionPtr, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                        CryptProtectUiForbidden, ref dataOut);
                if (!succeeded)
                {
                    // GetLastError → CryptographicException（沿用 .NET 加密异常惯例）
                    throw new CryptographicException(Marshal.GetLastWin32Error());
                }

                result = new byte[dataOut.CbData];
                if (dataOut.CbData > 0)
                {
                    Marshal.Copy(dataOut.PbData, result, 0, result.Length);
                }
            }
            finally
            {
                if (descriptionPtr != IntPtr.Zero)
                {
                    _ = NativeMethods.LocalFree(descriptionPtr);
                }

                if (dataOut.PbData != IntPtr.Zero)
                {
                    _ = NativeMethods.LocalFree(dataOut.PbData); // DPAPI 出参须 LocalFree
                }
            }
        }
        finally
        {
            inputHandle.Free();
        }

        return result;
    }

    /// <summary>crypt32 / kernel32 原生入口（签名按 dpapi.h 逐字段核对）。</summary>
    private static class NativeMethods
    {
        [DllImport("crypt32.dll", EntryPoint = "CryptProtectData", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CryptProtectData(
            ref DataBlob pDataIn,
            string? szDataDescr,
            IntPtr pOptionalEntropy,
            IntPtr pvReserved,
            IntPtr pPromptStruct,
            uint dwFlags,
            ref DataBlob pDataOut);

        [DllImport("crypt32.dll", EntryPoint = "CryptUnprotectData", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CryptUnprotectData(
            ref DataBlob pDataIn,
            ref IntPtr ppszDataDescr,
            IntPtr pOptionalEntropy,
            IntPtr pvReserved,
            IntPtr pPromptStruct,
            uint dwFlags,
            ref DataBlob pDataOut);

        [DllImport("kernel32.dll", EntryPoint = "LocalFree", SetLastError = true)]
        public static extern IntPtr LocalFree(IntPtr hMem);

        /// <summary>wincrypt.h DATA_BLOB（CRYPTOAPI_BLOB）：{ DWORD cbData; BYTE *pbData; }。</summary>
        [StructLayout(LayoutKind.Sequential)]
        public struct DataBlob
        {
            public uint CbData;
            public IntPtr PbData;
        }
    }
}
