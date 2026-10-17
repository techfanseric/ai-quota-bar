using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.CodexTasks;

namespace AQB.Hook;

/// <summary>
/// Codex lifecycle hook forwarder (the Windows AIQuotaBarHook). Codex executes this
/// process for each registered hook event and passes the payload JSON on stdin.
/// The payload-to-event mapping itself lives in AQB.CodexTasks/HookPayloadMapper and
/// is unit-tested there (AQB.CodexTasks.Tests/HookPayloadMapperTests); this entry
/// point stays a thin, always-silent transport: read stdin, append one JSONL line,
/// print "{}", exit 0 within 2 seconds no matter what.
/// </summary>
internal static class Program
{
    private const int TimeoutMs = 2000;

    private static int Main()
    {
        try
        {
            var read = Task.Run(() => Console.In.ReadToEnd());
            if (!read.Wait(TimeoutMs))
            {
                return 0;
            }

            JsonNode? payload = null;
            if (!string.IsNullOrWhiteSpace(read.Result))
            {
                try
                {
                    payload = JsonNode.Parse(read.Result);
                }
                catch (JsonException)
                {
                    payload = null;
                }
            }

            var mapped = HookPayloadMapper.Map(payload);
            if (mapped is not null)
            {
                new HookEventLog().Append(mapped);
            }

            Console.Out.Write("{}");
        }
        catch
        {
            // A hook must never fail or talk noisily: stay silent, exit 0.
        }

        return 0;
    }
}
