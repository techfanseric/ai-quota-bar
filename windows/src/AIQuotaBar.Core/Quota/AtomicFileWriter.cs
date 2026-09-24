// Swift 来源：无（Foundation Data.write(to:options: [.atomic]) 的 Windows 端等价实现：
// 先写同目录临时文件，再 File.Move 覆盖目标，避免半截文件）。

#nullable enable

using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace AIQuotaBar.Core.Quota;

/// <summary>原子写文件的内部辅助（store 持久化共用；对应 Swift 的 .atomic 写入选项）。</summary>
internal static class AtomicFileWriter
{
    public static async Task WriteAsync(
        string destinationPath,
        string contents,
        CancellationToken cancellationToken)
    {
        var temporaryPath = destinationPath + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await File.WriteAllTextAsync(temporaryPath, contents, cancellationToken);
            File.Move(temporaryPath, destinationPath, overwrite: true);
        }
        finally
        {
            TryDelete(temporaryPath);
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            // Move 成功后临时文件已不存在；此处只清理失败残留。
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (IOException)
        {
            // 清理残留失败可接受（下次写入用新的 UUID 后缀，不会相互冲突）。
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
