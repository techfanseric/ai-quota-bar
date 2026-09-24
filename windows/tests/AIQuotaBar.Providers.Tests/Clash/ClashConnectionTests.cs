// Swift 来源：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift（v1.28.1）
// 暂缓项（UI / live 门控，见移植报告）：testLiveClashConnectionViewRendersWhenExplicitlyEnabled、
// testLiveClashConnectionStreamWhenExplicitlyEnabled（依赖 ClashConnectionViewModel + WebSocket 流）。
// fixtures：connections-response-mihomo.json（Swift 内嵌 JSON 已由契约 agent 提取为共享样本）。

#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Clash;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Clash;

public sealed class ClashConnectionTests
{
    // ---------------------------------------------------------------- format

    [Fact]
    public void ConnectionDetailStartsWithNetworkAndOmitsProcess()
    {
        // 应然：网络大写 + 链路以 " · " 连接；process 不参与（实然不符即失败）。
        Assert.Equal("TCP · Japan 01", ClashConnectionFormat.Detail("tcp", "Japan 01"));
        Assert.Equal("UDP", ClashConnectionFormat.Detail(" udp ", null));
        Assert.Equal("Singapore 02", ClashConnectionFormat.Detail(null, "Singapore 02"));
        Assert.Null(ClashConnectionFormat.Detail(" ", null));
    }

    // ---------------------------------------------------------------- decode

    [Fact]
    public void ConnectionsResponseDecodesMihomoFields()
    {
        var json = Fixtures.ReadClashFixture("connections-response-mihomo.json");
        var response = JsonSerializer.Deserialize<ClashConnectionsResponse>(json, QuotaJson.Default);

        Assert.NotNull(response);
        // 应然：memory 等未知字段容忍，downloadTotal/uploadTotal 正常解码（实然不符即失败）。
        Assert.Equal(1234L, response!.DownloadTotal);
        Assert.Equal(567L, response.UploadTotal);
        Assert.Equal(1, response.Connections.Count);
        Assert.Equal("api.openai.com", response.Connections[0].Metadata.Host);
        Assert.Equal("openai.com", response.Connections[0].RulePayload);
        Assert.NotNull(ClashConnectionDateParser.Date(response.Connections[0].Start));
    }

    // ---------------------------------------------------------------- openai filter

    [Fact]
    public void FilterMatchesOnlyOpenAIAndChatGPTDomainSuffixes()
    {
        foreach (var host in new[]
                 {
                     "openai.com",
                     "api.openai.com",
                     "chatgpt.com:443",
                     "https://ab.chatgpt.com/path",
                 })
        {
            Assert.True(
                ClashOpenAIConnectionFilter.Matches(Record(id: host, host: host)),
                $"host: {host}");
        }

        foreach (var host in new[]
                 {
                     "notopenai.example",
                     "openai.example.com",
                     "oaistatic.com",
                     "chatgpt.example",
                 })
        {
            Assert.False(
                ClashOpenAIConnectionFilter.Matches(Record(id: host, host: host)),
                $"host: {host}");
        }
    }

    [Fact]
    public void FilterUsesSniffHostAndRulePayloadFallbacks()
    {
        Assert.True(ClashOpenAIConnectionFilter.Matches(
            Record(id: "sniffed", host: null, sniffHost: "ios.chatgpt.com")));
        Assert.True(ClashOpenAIConnectionFilter.Matches(
            Record(id: "rule", host: null, rulePayload: "+.openai.com")));
    }

    // ---------------------------------------------------------------- activity calculator

    [Fact]
    public void ActivityCalculatorComputesFilteredPerSecondRates()
    {
        var start = DateTimeOffset.FromUnixTimeSeconds(1_785_307_190);
        var calculator = new ClashConnectionActivityCalculator();

        var first = calculator.Update(
            Response(new[]
            {
                Record(id: "openai", host: "api.openai.com", upload: 1_000, download: 2_000, start: start.AddSeconds(-10)),
                Record(id: "other", host: "example.com", upload: 9_000, download: 9_000, start: start),
            }),
            observedAt: start);

        Assert.Equal(new[] { "openai" }, first.Connections.Select(connection => connection.Id).ToArray());
        Assert.Equal(0.0, first.UploadSpeed, precision: 3);
        Assert.Equal(0.0, first.DownloadSpeed, precision: 3);

        var second = calculator.Update(
            Response(new[]
            {
                Record(id: "openai", host: "api.openai.com", upload: 1_600, download: 3_000, start: start.AddSeconds(-10)),
            }),
            observedAt: start.AddSeconds(2));

        Assert.Equal(300.0, second.UploadSpeed, precision: 3);
        Assert.Equal(500.0, second.DownloadSpeed, precision: 3);
        Assert.Equal(12.0, second.Connections[0].Duration, precision: 3);
    }

    [Fact]
    public void NewAndResetConnectionsDoNotCreateSpeedSpikes()
    {
        var start = DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);
        var calculator = new ClashConnectionActivityCalculator();

        _ = calculator.Update(
            Response(new[]
            {
                Record(id: "one", host: "chatgpt.com", upload: 5_000, download: 7_000, start: start),
            }),
            observedAt: start);

        var reset = calculator.Update(
            Response(new[]
            {
                Record(id: "one", host: "chatgpt.com", upload: 10, download: 20, start: start),
                Record(id: "new", host: "api.openai.com", upload: 2_000, download: 3_000, start: start),
            }),
            observedAt: start.AddSeconds(1));

        // 应然：计数器回退与新连接都不得产生速率（实然出现尖刺即失败）。
        Assert.Equal(0.0, reset.UploadSpeed, precision: 3);
        Assert.Equal(0.0, reset.DownloadSpeed, precision: 3);
    }

    // ---------------------------------------------------------------- history

    [Fact]
    public void HistoryReplacesCurrentMinuteAndKeepsSixtySamples()
    {
        var currentMinute = DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);
        var samples = Enumerable.Range(1, 65)
            .Select(offset => new ClashConnectionHistorySample(
                currentMinute.AddSeconds(-offset * 60),
                new[] { (double)offset }))
            .ToList();

        var snapshot = new ClashConnectionActivitySnapshot(
            ObservedAt: currentMinute.AddSeconds(35),
            Connections: new[] { ActiveConnection("new", 10), ActiveConnection("old", 4_000) },
            UploadSpeed: 0,
            DownloadSpeed: 0);
        samples = ClashConnectionHistory.Upserting(snapshot, samples).ToList();

        Assert.Equal(60, samples.Count);
        Assert.Equal(currentMinute, samples[^1].Timestamp);
        Assert.Equal(new[] { 4_000.0, 10.0 }, samples[^1].ConnectionAges.ToArray());

        var replacement = new ClashConnectionActivitySnapshot(
            ObservedAt: currentMinute.AddSeconds(55),
            Connections: new[] { ActiveConnection("only", 30) },
            UploadSpeed: 0,
            DownloadSpeed: 0);
        samples = ClashConnectionHistory.Upserting(replacement, samples).ToList();

        Assert.Equal(60, samples.Count);
        Assert.Equal(new[] { 30.0 }, samples[^1].ConnectionAges.ToArray());
    }

    [Fact]
    public async Task HistoryStoreRoundTripsAggregateAgesOnly()
    {
        var directory = Path.Combine(Path.GetTempPath(), "clash-connections-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new ClashConnectionHistoryStore(directory);
            var date = ClashConnectionHistory.MinuteStart(DateTimeOffset.UtcNow);
            var samples = new[] { new ClashConnectionHistorySample(date, new[] { 5.0, 70.0 }) };

            await store.SaveAsync(samples);
            var loaded = await store.LoadAsync(date);

            Assert.Equal(1, loaded.Count);
            Assert.Equal(date, loaded[0].Timestamp);
            Assert.Equal(new[] { 5.0, 70.0 }, loaded[0].ConnectionAges.ToArray());

            // 应然：落盘内容只含聚合年龄，不含 host/process/destinationIP 明细。
            var persistedText = await File.ReadAllTextAsync(store.FilePath);
            Assert.False(persistedText.Contains("openai.com"));
            Assert.False(persistedText.Contains("process"));
            Assert.False(persistedText.Contains("destinationIP"));
        }
        finally
        {
            TryDeleteDirectory(directory);
        }
    }

    [Fact]
    public void AgeScaleClampsAtOneHour()
    {
        Assert.Equal(0.0, ClashConnectionAgeScale.Progress(-1), precision: 3);
        Assert.Equal(0.5, ClashConnectionAgeScale.Progress(30 * 60), precision: 3);
        Assert.Equal(1.0, ClashConnectionAgeScale.Progress(2 * 60 * 60), precision: 3);
    }

    // ---------------------------------------------------------------- helpers

    private static ClashConnectionsResponse Response(IReadOnlyList<ClashConnectionRecord> connections) =>
        new(DownloadTotal: null, UploadTotal: null, Connections: connections);

    private static ClashConnectionRecord Record(
        string id,
        string? host,
        string? sniffHost = null,
        string? rulePayload = null,
        long upload = 0,
        long download = 0,
        DateTimeOffset? start = null) =>
        new(
            Id: id,
            Download: download,
            Upload: upload,
            Chains: new[] { "AI group", "JP 01" },
            Rule: "DomainSuffix",
            RulePayload: rulePayload,
            Start: IsoSecondString(start ?? DateTimeOffset.FromUnixTimeSeconds(1_785_307_200)),
            Metadata: new ClashConnectionMetadata(
                Network: "tcp",
                Type: "HTTP",
                DestinationIp: "203.0.113.1",
                Host: host,
                Process: "Codex",
                ProcessPath: null,
                RemoteDestination: null,
                SniffHost: sniffHost));

    private static ClashActiveConnection ActiveConnection(string id, double duration) =>
        new(
            Id: id,
            Host: "api.openai.com",
            Process: "Codex",
            Network: "tcp",
            Chains: new[] { "AI group" },
            StartedAt: null,
            Duration: duration,
            UploadSpeed: 0,
            DownloadSpeed: 0);

    private static string IsoSecondString(DateTimeOffset date) =>
        date.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);

    private static void TryDeleteDirectory(string directory)
    {
        try
        {
            Directory.Delete(directory, recursive: true);
        }
        catch (IOException)
        {
            // 清理失败不影响断言（对应 Swift 端 try? removeItem）。
        }
    }
}
