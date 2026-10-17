using Microsoft.Data.Sqlite;
using Xunit;

namespace AQB.CodexTasks.Tests;

public sealed class CodexLocalStateReaderTests : IDisposable
{
    private readonly TempDir _dir = new();

    public void Dispose() => _dir.Dispose();

    [Fact]
    public void MissingDatabase_ReturnsFalse()
    {
        var reader = new CodexLocalStateReader(_dir.Path);

        Assert.False(reader.TryCountThreads(out var count));
        Assert.Equal(0, count);
        Assert.Equal(Path.Combine(_dir.Path, "state_5.sqlite"), reader.DatabasePath);
    }

    [Fact]
    public void DatabaseWithoutThreadsTable_TolerantlyReportsZero()
    {
        var path = Path.Combine(_dir.Path, "state_5.sqlite");
        using (var connection = new SqliteConnection($"Data Source={path}"))
        {
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE other (id TEXT)";
            command.ExecuteNonQuery();
        }

        var reader = new CodexLocalStateReader(_dir.Path);

        Assert.True(reader.TryCountThreads(out var count));
        Assert.Equal(0, count);
    }

    [Fact]
    public void ThreadsRows_AreCountedReadOnly()
    {
        var path = Path.Combine(_dir.Path, "state_5.sqlite");
        using (var connection = new SqliteConnection($"Data Source={path}"))
        {
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText =
                "CREATE TABLE threads (id TEXT PRIMARY KEY); INSERT INTO threads (id) VALUES ('a'), ('b'), ('c');";
            command.ExecuteNonQuery();
        }

        var reader = new CodexLocalStateReader(_dir.Path);

        Assert.True(reader.TryCountThreads(out var count));
        Assert.Equal(3, count);
    }

    [Fact]
    public void CorruptFile_ReturnsFalse()
    {
        File.WriteAllText(Path.Combine(_dir.Path, "state_5.sqlite"), "this is not a database");

        var reader = new CodexLocalStateReader(_dir.Path);

        Assert.False(reader.TryCountThreads(out var count));
        Assert.Equal(0, count);
    }
}
