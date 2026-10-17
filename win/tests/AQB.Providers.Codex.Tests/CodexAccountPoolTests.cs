using AQB.Core;
using Xunit;

namespace AQB.Providers.Codex.Tests;

public class CodexAccountPoolTests
{
    [Fact]
    public void MissingAccountsDirectoryYieldsEmptyList()
    {
        using var home = new TempCodexHome();
        var pool = new CodexAccountPool(home.Root);

        Assert.Empty(pool.ListAccounts());
    }

    [Fact]
    public void EnumeratesAccountFilesSortedByLabelCaseInsensitively()
    {
        using var home = new TempCodexHome();
        home.WritePoolAccount("Zeta.json", AuthFiles.AuthJson(accountId: "org-z"));
        home.WritePoolAccount("alpha.json", AuthFiles.AuthJson(accountId: "org-a", idToken: TestJwts.WithEmail("alpha@example.com")));
        home.WritePoolAccount(".hidden.json", AuthFiles.AuthJson(accountId: "org-hidden"));
        home.WritePoolAccount("broken.json", "not json at all");
        home.WritePoolAccount("unusable.json", AuthFiles.AuthJson(accountId: null));

        var accounts = new CodexAccountPool(home.Root).ListAccounts();

        Assert.Equal(2, accounts.Count);
        Assert.Equal("alpha", accounts[0].Label);
        Assert.Equal("org-a", accounts[0].AccountId);
        Assert.Equal("alpha@example.com", accounts[0].Email);
        Assert.EndsWith("alpha.json", accounts[0].FilePath);
        Assert.Equal("Zeta", accounts[1].Label);
        Assert.Equal("org-z", accounts[1].AccountId);
        Assert.Null(accounts[1].Email);
    }

    [Fact]
    public void PoolHomeFollowsTheInjectedCodexHome()
    {
        using var home = new TempCodexHome();
        var pool = new CodexAccountPool(home.Root);

        Assert.Equal(home.Root, pool.CodexHome);
    }
}

public class AccountFingerprintVectorTests
{
    [Fact]
    public void CodexDigestMatchesLockedVector()
    {
        // SHA-256("codex-account|org-test"), lowercase hex — must stay byte-compatible with macOS.
        Assert.Equal(
            "1754784ce02b971fc12503c849cd9d413e55f40454783f0963f98b3b3bf937e7",
            AccountFingerprint.Codex("org-test"));
    }

    [Fact]
    public void CodexDigestMatchesVectorForOrgDash1()
    {
        Assert.Equal(
            "6a357562dc1fc3da48697c32b96ce8f1d9c2dc81027d195a7836344e42e5ca99",
            AccountFingerprint.Codex("org-1"));
    }

    [Fact]
    public void CodexDigestShapeAndDeterminism()
    {
        var digest = AccountFingerprint.Codex("org-test");

        Assert.Equal(64, digest.Length);
        Assert.Matches("^[0-9a-f]{64}$", digest);
        Assert.Equal(digest, AccountFingerprint.Codex("org-test"));
        Assert.NotEqual(digest, AccountFingerprint.Codex("org-other"));
        Assert.DoesNotContain("org-test", digest);
    }
}
