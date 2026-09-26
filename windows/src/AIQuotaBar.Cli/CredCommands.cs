// Swift 来源：无（Windows 端新增；凭据库的完整 CLI 操作：list/write/read/delete）。
// 密钥安全约定：list 不显示密钥；read 默认掩码，--raw 显式放开；write 支持 --stdin 管道
// （避免密钥进入 shell 历史 / 进程参数）。SSH 网络会话下写操作会失败并给出解释（env 探测同源）。

#nullable enable

using AIQuotaBar.Platform.Credentials;

namespace AIQuotaBar.Cli;

internal static class CredCommand
{
    public static int Run(List<string> tail)
    {
        if (tail.Count == 0)
        {
            throw new UsageException("用法：aqb cred <list|write|read|delete> ...");
        }

        var sub = tail[0].ToLowerInvariant();
        var args = tail.Skip(1).ToList();
        return sub switch
        {
            "list" => List(args),
            "write" => Write(args),
            "read" => Read(args),
            "delete" => Delete(args),
            _ => throw new UsageException($"未知子命令：cred {sub}（可用：list/write/read/delete）"),
        };
    }

    private static int List(List<string> args)
    {
        var t0 = CliLog.OpBegin("cred list");
        var service = args.FirstOrDefault();
        var store = new CredentialStore();
        var entries = store.Enumerate(service);
        Console.WriteLine(entries.Count == 0
            ? "（无匹配凭据）"
            : string.Join(Environment.NewLine, entries.Select(e => $"  {e.Service} : {e.Account}  (user={e.UserName ?? "-"})")));
        CliLog.Op("cred list", t0);
        return 0;
    }

    private static int Write(List<string> args)
    {
        if (args.Count < 2)
        {
            throw new UsageException("用法：aqb cred write <service> <account> [--secret <s> | --stdin]");
        }

        var service = args[0];
        var account = args[1];
        var secret = ExtractSecret(args.Skip(2).ToList());
        var t0 = CliLog.OpBegin("cred write");
        var store = new CredentialStore();
        store.Write(service, account, secret);
        Console.WriteLine($"已写入 {service}:{account}（{Support.Mask(secret)}）");
        CliLog.Op("cred write", t0);
        return 0;
    }

    private static int Read(List<string> args)
    {
        if (args.Count < 2)
        {
            throw new UsageException("用法：aqb cred read <service> <account> [--raw]");
        }

        var service = args[0];
        var account = args[1];
        var raw = args.Contains("--raw");
        var t0 = CliLog.OpBegin("cred read");
        var store = new CredentialStore();
        var secret = store.Read(service, account);
        if (secret is null)
        {
            Console.WriteLine($"（{service}:{account} 无凭据）");
            CliLog.Op("cred read", t0);
            return 1;
        }

        Console.WriteLine(raw ? secret : $"  {service}:{account} = {Support.Mask(secret)}");
        CliLog.Op("cred read", t0);
        return 0;
    }

    private static int Delete(List<string> args)
    {
        if (args.Count < 2)
        {
            throw new UsageException("用法：aqb cred delete <service> <account>");
        }

        var t0 = CliLog.OpBegin("cred delete");
        var store = new CredentialStore();
        var deleted = store.Delete(args[0], args[1]);
        Console.WriteLine(deleted ? $"已删除 {args[0]}:{args[1]}" : $"（{args[0]}:{args[1]} 本不存在）");
        CliLog.Op("cred delete", t0);
        return deleted ? 0 : 1;
    }

    private static string ExtractSecret(List<string> flags)
    {
        for (var i = 0; i < flags.Count; i++)
        {
            if (flags[i] == "--secret" && i + 1 < flags.Count)
            {
                return flags[i + 1];
            }
        }

        if (flags.Contains("--stdin"))
        {
            var line = Console.ReadLine();
            if (!string.IsNullOrEmpty(line))
            {
                return line;
            }
        }

        throw new UsageException("缺少密钥：用 --secret <s> 或 --stdin（管道一行）");
    }
}
