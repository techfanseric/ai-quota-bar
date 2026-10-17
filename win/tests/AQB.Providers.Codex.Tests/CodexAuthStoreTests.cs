using Xunit;

namespace AQB.Providers.Codex.Tests;

public class CodexAuthStoreTests
{
    [Fact]
    public void ApiKeyModeWinsOverStaleChatgptTokens()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson(apiKey: "sk-test", idToken: TestJwts.WithEmail("eric@example.com")));

        var info = new CodexAuthStore(home.Root).Load();

        Assert.NotNull(info);
        Assert.True(info.HasApiKey);
        Assert.Equal("org-1", info.AccountId);
        // API key mode still reads tokens.account_id; email from id_token is still available.
        Assert.Equal("eric@example.com", info.Email);
    }

    [Fact]
    public void OAuthModeParsesAccountIdAndJwtEmail()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson(idToken: TestJwts.WithEmail("eric@example.com", "user-1")));

        var info = new CodexAuthStore(home.Root).Load();

        Assert.NotNull(info);
        Assert.False(info.HasApiKey);
        Assert.Equal("org-1", info.AccountId);
        Assert.Equal("eric@example.com", info.Email);
        Assert.Contains("at-old", info.RawJson);
    }

    [Fact]
    public void LegacyFileWithoutAuthModeStillLogsIn()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());

        var info = new CodexAuthStore(home.Root).Load();

        Assert.NotNull(info);
        Assert.Equal("org-1", info.AccountId);
    }

    [Fact]
    public void MissingAccountIdIsUnusable()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson(accountId: null));
        Assert.Null(new CodexAuthStore(home.Root).Load());

        home.WriteAuth("{}");
        Assert.Null(new CodexAuthStore(home.Root).Load());
    }

    [Fact]
    public void NonChatgptAuthModeIsUnusableUnlessApiKeyPresent()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson(authMode: "apikey"));
        Assert.Null(new CodexAuthStore(home.Root).Load());

        home.WriteAuth(AuthFiles.AuthJson(authMode: "apikey", apiKey: "sk-x"));
        var info = new CodexAuthStore(home.Root).Load();
        Assert.NotNull(info);
        Assert.True(info.HasApiKey);
    }

    [Fact]
    public void MissingOrGarbageFileIsUnusable()
    {
        using var home = new TempCodexHome();
        Assert.Null(new CodexAuthStore(home.Root).Load());

        home.WriteAuth("this is not json{");
        Assert.Null(new CodexAuthStore(home.Root).Load());

        home.WriteAuth(string.Empty);
        Assert.Null(new CodexAuthStore(home.Root).Load());
    }

    [Fact]
    public void JwtVariantsDegradeToNullEmail()
    {
        using var home = new TempCodexHome();

        // JWT without an email claim.
        home.WriteAuth(AuthFiles.AuthJson(idToken: TestJwts.Make("{\"sub\":\"u1\"}")));
        var noEmail = new CodexAuthStore(home.Root).Load();
        Assert.NotNull(noEmail);
        Assert.Null(noEmail.Email);

        // Not a JWT at all.
        home.WriteAuth(AuthFiles.AuthJson(idToken: "garbage"));
        var garbage = new CodexAuthStore(home.Root).Load();
        Assert.NotNull(garbage);
        Assert.Null(garbage.Email);
        Assert.Equal("org-1", garbage.AccountId);
    }

    [Fact]
    public void ConstructorCodexHomeBeatsEnvironmentVariable()
    {
        using var homeWithAuth = new TempCodexHome();
        using var homeWithoutAuth = new TempCodexHome();
        homeWithAuth.WriteAuth(AuthFiles.AuthJson());

        var previous = Environment.GetEnvironmentVariable("CODEX_HOME");
        Environment.SetEnvironmentVariable("CODEX_HOME", homeWithoutAuth.Root);
        try
        {
            var fromConstructor = new CodexAuthStore(homeWithAuth.Root).Load();
            Assert.NotNull(fromConstructor);
            Assert.Equal("org-1", fromConstructor.AccountId);

            // CODEX_HOME env var is honoured when no constructor override is given.
            Assert.Null(new CodexAuthStore().Load());
            Assert.Equal(homeWithoutAuth.Root, new CodexAuthStore().CodexHome);
        }
        finally
        {
            Environment.SetEnvironmentVariable("CODEX_HOME", previous);
        }
    }

    [Fact]
    public void TornReadRetriesOnceAndAcceptsTheStableContent()
    {
        using var home = new TempCodexHome();
        var first = new CodexFileStamp(new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc), 100);
        var rewritten = new CodexFileStamp(new DateTime(2026, 1, 1, 0, 0, 5, DateTimeKind.Utc), 150);

        // Attempt 1: file rewritten between the two stats -> torn. Attempt 2: stable.
        var stats = new CodexFileStamp?[] { first, rewritten, rewritten, rewritten };
        var reads = new[] { AuthFiles.AuthJson(accountId: "org-a"), AuthFiles.AuthJson(accountId: "org-b") };
        var store = new ScriptedAuthStore(stats, reads, home.Root);

        var info = store.Load();

        Assert.NotNull(info);
        Assert.Equal("org-b", info.AccountId);
        Assert.Equal(4, store.StatCalls);
        Assert.Equal(2, store.ReadCalls);
    }

    [Fact]
    public void MtimeOnlyChangeAlsoCountsAsTorn()
    {
        using var home = new TempCodexHome();
        var stats = new CodexFileStamp?[]
        {
            new(new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc), 100),
            new(new DateTime(2026, 1, 1, 0, 0, 1, DateTimeKind.Utc), 100),
            new(new DateTime(2026, 1, 1, 0, 0, 2, DateTimeKind.Utc), 100),
            new(new DateTime(2026, 1, 1, 0, 0, 2, DateTimeKind.Utc), 100),
        };
        var reads = new[] { AuthFiles.AuthJson(accountId: "org-a"), AuthFiles.AuthJson(accountId: "org-b") };
        var store = new ScriptedAuthStore(stats, reads, home.Root);

        var info = store.Load();

        Assert.NotNull(info);
        Assert.Equal("org-b", info.AccountId);
    }

    [Fact]
    public void PersistentlyTornFileIsUnusable()
    {
        using var home = new TempCodexHome();
        var a = new CodexFileStamp(new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc), 100);
        var b = new CodexFileStamp(new DateTime(2026, 1, 1, 0, 0, 1, DateTimeKind.Utc), 110);
        var c = new CodexFileStamp(new DateTime(2026, 1, 1, 0, 0, 2, DateTimeKind.Utc), 120);

        var stats = new CodexFileStamp?[] { a, b, b, c };
        var reads = new[] { AuthFiles.AuthJson(), AuthFiles.AuthJson() };
        var store = new ScriptedAuthStore(stats, reads, home.Root);

        Assert.Null(store.Load());
        Assert.Equal(4, store.StatCalls);
        Assert.Equal(2, store.ReadCalls);
    }

    [Fact]
    public void OversizedFileIsRejectedWithoutReading()
    {
        using var home = new TempCodexHome();
        var oversized = new CodexFileStamp(DateTime.UtcNow, CodexAuthStore.MaxFileBytes + 1);
        var store = new ScriptedAuthStore(
            new CodexFileStamp?[] { oversized },
            Array.Empty<string?>(),
            home.Root);

        Assert.Null(store.Load());
        Assert.Equal(0, store.ReadCalls);
    }

    private sealed class ScriptedAuthStore : CodexAuthStore
    {
        private readonly CodexFileStamp?[] _stats;
        private readonly string?[] _reads;
        private int _statIndex;
        private int _readIndex;

        public ScriptedAuthStore(CodexFileStamp?[] stats, string?[] reads, string codexHome)
            : base(codexHome)
        {
            _stats = stats;
            _reads = reads;
        }

        public int StatCalls { get; private set; }

        public int ReadCalls { get; private set; }

        protected override CodexFileStamp? TryStat(string path)
        {
            StatCalls++;
            return _statIndex < _stats.Length ? _stats[_statIndex++] : null;
        }

        protected override string? TryReadAllText(string path)
        {
            ReadCalls++;
            return _readIndex < _reads.Length ? _reads[_readIndex++] : null;
        }
    }
}
