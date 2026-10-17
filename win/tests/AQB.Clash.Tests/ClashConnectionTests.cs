using System.Text.Json;
using AQB.Core;
using Xunit;

namespace AQB.Clash.Tests;

public class ClashConnectionModelTests
{
    [Fact]
    public void ParsesMihomoFrameFields()
    {
        const string json = """
            {
              "downloadTotal": 1234,
              "uploadTotal": 567,
              "memory": 999,
              "connections": [
                {
                  "id": "connection-1",
                  "download": 400,
                  "upload": 100,
                  "chains": ["AI group", "JP 01"],
                  "rule": "DomainSuffix",
                  "rulePayload": "openai.com",
                  "start": "2026-07-29T07:00:00.123456Z",
                  "metadata": {
                    "network": "tcp",
                    "type": "HTTP",
                    "destinationIP": "203.0.113.1",
                    "host": "api.openai.com",
                    "process": "Codex",
                    "processPath": "/Applications/Codex.app",
                    "remoteDestination": "api.openai.com:443",
                    "sniffHost": ""
                  }
                }
              ]
            }
            """;

        var response = ConnectionsResponse.Parse(json);

        Assert.NotNull(response);
        Assert.Equal(1234, response.DownloadTotal);
        Assert.Equal(567, response.UploadTotal);
        var connection = Assert.Single(response.Connections);
        Assert.Equal("connection-1", connection.Id);
        Assert.Equal(400, connection.Download);
        Assert.Equal(100, connection.Upload);
        Assert.Equal(new[] { "AI group", "JP 01" }, connection.Chains);
        Assert.Equal("api.openai.com", connection.Metadata.Host);
        Assert.Equal("Codex", connection.Metadata.Process);
        Assert.NotNull(ClashConnectionDateParser.Parse(connection.Start));
    }

    [Fact]
    public void RejectsInvalidJsonFrames()
    {
        Assert.Null(ConnectionsResponse.Parse("not json"));
    }

    [Theory]
    [InlineData("2026-07-29T07:00:00.123456Z")]
    [InlineData("2026-07-29T07:00:00Z")]
    [InlineData("2026-07-29T07:00:00.123456789Z")]
    [InlineData("2026-07-29T15:00:00.5+08:00")]
    public void DateParserHandlesFractionalAndOffsetTimestamps(string value)
    {
        Assert.NotNull(ClashConnectionDateParser.Parse(value));
    }

    [Theory]
    [InlineData("")]
    [InlineData("garbage")]
    [InlineData("29/07/2026 07:00")]
    public void DateParserRejectsInvalidTimestamps(string value)
    {
        Assert.Null(ClashConnectionDateParser.Parse(value));
    }
}

public class ClashOpenAiConnectionFilterTests
{
    private static ConnectionRecord Record(
        string? host = null,
        string? sniffHost = null,
        string? remoteDestination = null,
        string? rulePayload = null,
        string? destinationIp = null)
        => new()
        {
            Id = Guid.NewGuid().ToString("N"),
            Metadata = new ConnectionMetadata
            {
                Host = host,
                SniffHost = sniffHost,
                RemoteDestination = remoteDestination,
                DestinationIP = destinationIp,
            },
            RulePayload = rulePayload,
        };

    [Theory]
    [InlineData("openai.com")]
    [InlineData("api.openai.com")]
    [InlineData("chatgpt.com:443")]
    [InlineData("https://ab.chatgpt.com/path")]
    public void MatchesOpenAiAndChatGptDomains(string host)
    {
        Assert.True(ClashOpenAiConnectionFilter.Matches(Record(host: host)));
    }

    [Theory]
    [InlineData("notopenai.example")]
    [InlineData("openai.example.com")]
    [InlineData("oaistatic.com")]
    [InlineData("chatgpt.example")]
    public void RejectsUnrelatedHosts(string host)
    {
        Assert.False(ClashOpenAiConnectionFilter.Matches(Record(host: host)));
    }

    [Fact]
    public void UsesSniffHostAndRulePayloadFallbacks()
    {
        Assert.True(ClashOpenAiConnectionFilter.Matches(Record(sniffHost: "ios.chatgpt.com")));
        Assert.True(ClashOpenAiConnectionFilter.Matches(Record(rulePayload: "+.openai.com")));
        Assert.True(ClashOpenAiConnectionFilter.Matches(Record(remoteDestination: "api.openai.com:443")));
    }

    [Fact]
    public void DisplayHostPrefersHostThenSniffHostThenRemoteDestination()
    {
        Assert.Equal("api.openai.com", ClashOpenAiConnectionFilter.DisplayHost(Record(
            host: "api.openai.com",
            sniffHost: "sniffed.openai.com",
            destinationIp: "203.0.113.1")));
        Assert.Equal("ios.chatgpt.com", ClashOpenAiConnectionFilter.DisplayHost(Record(
            sniffHost: "ios.chatgpt.com",
            remoteDestination: "api.openai.com:443")));
        Assert.Equal("api.openai.com", ClashOpenAiConnectionFilter.DisplayHost(Record(
            remoteDestination: "api.openai.com:443",
            destinationIp: "203.0.113.1")));
        Assert.Equal("203.0.113.1", ClashOpenAiConnectionFilter.DisplayHost(Record(destinationIp: "203.0.113.1")));
        Assert.Equal("—", ClashOpenAiConnectionFilter.DisplayHost(Record()));
    }

    [Theory]
    [InlineData("API.OpenAI.COM.", "api.openai.com")]
    [InlineData("  chatgpt.com  ", "chatgpt.com")]
    [InlineData("+.openai.com", "openai.com")]
    [InlineData("https://ab.chatgpt.com/path", "ab.chatgpt.com")]
    [InlineData("chatgpt.com:443", "chatgpt.com")]
    [InlineData("example.com:", "example.com")]
    [InlineData("[2001:db8::1]", "[2001:db8::1]")]
    public void NormalizesHostVariants(string raw, string expected)
    {
        Assert.Equal(expected, ClashOpenAiConnectionFilter.NormalizeHost(raw));
    }
}

public class ClashConnectionActivityCalculatorTests
{
    private static readonly DateTimeOffset Start =
        DateTimeOffset.FromUnixTimeSeconds(1_785_307_190);

    private static ConnectionsResponse Response(params ConnectionRecord[] connections)
        => new() { Connections = connections };

    private static ConnectionRecord Record(
        string id,
        string host,
        long upload,
        long download,
        DateTimeOffset? start = null)
        => new()
        {
            Id = id,
            Upload = upload,
            Download = download,
            Start = TimeText.FixedIso(start ?? Start),
            Metadata = new ConnectionMetadata { Host = host },
        };

    [Fact]
    public void ComputesFilteredPerSecondRates()
    {
        var calculator = new ClashConnectionActivityCalculator();

        var first = calculator.Update(
            Response(
                Record("openai", "api.openai.com", 1_000, 2_000, Start.AddSeconds(-10)),
                Record("other", "example.com", 9_000, 9_000)),
            Start);

        var openAi = Assert.Single(first.Connections);
        Assert.Equal("openai", openAi.Id);
        Assert.Equal(0, first.UploadBps);
        Assert.Equal(0, first.DownloadBps);
        Assert.Equal(10, openAi.DurationSeconds, 3);

        var second = calculator.Update(
            Response(Record("openai", "api.openai.com", 1_600, 3_000, Start.AddSeconds(-10))),
            Start.AddSeconds(2));

        Assert.Equal(300, second.UploadBps, 0.001);
        Assert.Equal(500, second.DownloadBps, 0.001);
        Assert.Equal(12, second.Connections[0].DurationSeconds, 0.001);
        Assert.Equal("api.openai.com", second.Connections[0].Host);
    }

    [Fact]
    public void NewAndResetConnectionsDoNotCreateSpeedSpikes()
    {
        var start = DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);
        var calculator = new ClashConnectionActivityCalculator();

        calculator.Update(
            Response(Record("one", "chatgpt.com", 5_000, 7_000, start)),
            start);

        var reset = calculator.Update(
            Response(
                Record("one", "chatgpt.com", 10, 20, start),
                Record("new", "api.openai.com", 2_000, 3_000, start)),
            start.AddSeconds(1));

        Assert.Equal(0, reset.UploadBps);
        Assert.Equal(0, reset.DownloadBps);
    }

    [Fact]
    public void SortsNewestConnectionFirst()
    {
        var calculator = new ClashConnectionActivityCalculator();
        var snapshot = calculator.Update(
            Response(
                Record("old", "api.openai.com", 1, 1, Start),
                Record("new", "chatgpt.com", 1, 1, Start.AddSeconds(30))),
            Start.AddSeconds(60));

        Assert.Equal(new[] { "new", "old" }, snapshot.Connections.Select(connection => connection.Id));
    }
}

public class ClashConnectionHistoryTests
{
    private static readonly DateTimeOffset CurrentMinute =
        DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);

    private static ActivitySnapshot Snapshot(DateTimeOffset observedAt, params double[] durations)
        => new()
        {
            ObservedAt = observedAt,
            Connections = durations.Select(duration => new ActiveConnection
            {
                Id = Guid.NewGuid().ToString("N"),
                Host = "host",
                DurationSeconds = duration,
            }).ToArray(),
        };

    [Fact]
    public void MinuteStartAlignsToMinuteGrid()
    {
        var value = DateTimeOffset.FromUnixTimeSeconds(1_785_307_235).AddMilliseconds(400);
        Assert.Equal(1_785_307_200, ClashConnectionHistory.MinuteStart(value).ToUnixTimeSeconds());
    }

    [Fact]
    public void UpsertReplacesCurrentMinuteAndKeepsSixtySamples()
    {
        var samples = Enumerable.Range(1, 65)
            .Select(offset => new ConnectionHistorySample
            {
                Timestamp = CurrentMinute.AddSeconds(-offset * 60),
                ConnectionAges = new[] { (double)offset },
            })
            .ToList();

        samples = ClashConnectionHistory.Upsert(
            Snapshot(CurrentMinute.AddSeconds(35), 10, 4_000),
            samples);

        Assert.Equal(60, samples.Count);
        Assert.Equal(CurrentMinute, samples[^1].Timestamp);
        Assert.Equal(2, samples[^1].ConnectionAges.Count);
        Assert.Equal(4_000, samples[^1].ConnectionAges[0]);
        Assert.Equal(10, samples[^1].ConnectionAges[1]);

        samples = ClashConnectionHistory.Upsert(
            Snapshot(CurrentMinute.AddSeconds(55), 30),
            samples);

        Assert.Equal(60, samples.Count);
        var latest = samples[^1];
        Assert.Single(latest.ConnectionAges);
        Assert.Equal(30, latest.ConnectionAges[0]);
    }

    [Fact]
    public void PruneKeepsTheSixtyMinuteWindow()
    {
        var samples = Enumerable.Range(0, 70)
            .Select(offset => new ConnectionHistorySample
            {
                Timestamp = CurrentMinute.AddSeconds(-offset * 60),
                ConnectionAges = new[] { (double)offset },
            });

        var pruned = ClashConnectionHistory.Prune(samples, CurrentMinute.AddSeconds(30));

        Assert.Equal(60, pruned.Count);
        Assert.Equal(CurrentMinute.AddSeconds(-59 * 60), pruned[0].Timestamp);
        Assert.Equal(CurrentMinute, pruned[^1].Timestamp);
    }
}

public class ClashConnectionHistoryStoreTests
{
    [Fact]
    public void RoundTripsAggregateAgesOnly()
    {
        var directory = Path.Combine(Path.GetTempPath(), "clash-connections-" + Guid.NewGuid().ToString("N"));
        var store = new ClashConnectionHistoryStore(directory);
        try
        {
            var minute = ClashConnectionHistory.MinuteStart(DateTimeOffset.UtcNow);
            var samples = new List<ConnectionHistorySample>
            {
                new() { Timestamp = minute, ConnectionAges = new[] { 5d, 70d } },
            };

            store.Save(samples);

            Assert.Equal(
                samples.Select(sample => sample.Timestamp),
                store.Load(minute.AddSeconds(30)).Select(sample => sample.Timestamp));
            var loaded = Assert.Single(store.Load(minute.AddSeconds(30)));
            Assert.Equal(2, loaded.ConnectionAges.Count);
            Assert.Equal(5, loaded.ConnectionAges[0]);
            Assert.Equal(70, loaded.ConnectionAges[1]);

            var persistedText = File.ReadAllText(store.FilePath);
            Assert.Contains("\"version\":1", persistedText);
            Assert.DoesNotContain("openai.com", persistedText);
            Assert.DoesNotContain("process", persistedText);
            Assert.DoesNotContain("destinationIP", persistedText);
            Assert.DoesNotContain("host", persistedText);
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }

    [Fact]
    public void LoadToleratesMissingAndCorruptFiles()
    {
        var directory = Path.Combine(Path.GetTempPath(), "clash-connections-" + Guid.NewGuid().ToString("N"));
        var store = new ClashConnectionHistoryStore(directory);
        try
        {
            Assert.Empty(store.Load());

            Directory.CreateDirectory(directory);
            File.WriteAllText(store.FilePath, "{ not json");
            Assert.Empty(store.Load());
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }
}

public class ClashConnectionAgeScaleTests
{
    [Fact]
    public void ProgressClampsAtOneHour()
    {
        Assert.Equal(0, ClashConnectionAgeScale.Progress(-1));
        Assert.Equal(0.5, ClashConnectionAgeScale.Progress(30 * 60), 3);
        Assert.Equal(1, ClashConnectionAgeScale.Progress(2 * 60 * 60));
    }

    [Fact]
    public void ColorInterpolatesFromGreenToOrange()
    {
        var fresh = ClashConnectionAgeScale.Color(0);
        Assert.Equal(0.20, fresh.R, 3);
        Assert.Equal(0.78, fresh.G, 3);
        Assert.Equal(0.35, fresh.B, 3);

        var oldest = ClashConnectionAgeScale.Color(3600);
        Assert.Equal(1.00, oldest.R, 3);
        Assert.Equal(0.49, oldest.G, 3);
        Assert.Equal(0.05, oldest.B, 3);

        var mid = ClashConnectionAgeScale.Color(1800);
        Assert.Equal(0.6, mid.R, 3);
        Assert.Equal(0.635, mid.G, 3);
        Assert.Equal(0.2, mid.B, 3);
    }
}
