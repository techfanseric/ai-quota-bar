using Microsoft.Data.Sqlite;

namespace AQB.CodexTasks;

/// <summary>
/// Read-only accessor for ~/.codex/state_5.sqlite (CODEX_HOME honored).
///
/// Best-effort port: the macOS CodexLocalActivityDetector queries the full threads
/// table (schema-drift defense via PRAGMA table_info, parent-chain root merging, a
/// 16MB rollout bootstrap, etc. — codex.md §4.3). None of that is ported here; this
/// reader only counts thread rows so callers get a cheap "how many sessions does
/// Codex know about" hint. Rollout-file watching lives in <see cref="CodexRolloutWatcher"/>.
/// </summary>
public sealed class CodexLocalStateReader
{
    public CodexLocalStateReader(string? codexHome = null)
    {
        DatabasePath = Path.Combine(codexHome ?? CodexPaths.DefaultHome(), "state_5.sqlite");
    }

    public string DatabasePath { get; }

    /// <summary>
    /// Counts rows in the threads table. Returns false when the database is missing
    /// or unreadable. A database without a threads table tolerantly reports zero.
    /// </summary>
    public bool TryCountThreads(out int threadCount)
    {
        threadCount = 0;
        if (!File.Exists(DatabasePath))
        {
            return false;
        }

        try
        {
            var builder = new SqliteConnectionStringBuilder
            {
                DataSource = DatabasePath,
                Mode = SqliteOpenMode.ReadOnly,
                DefaultTimeout = 1,
            };
            using var connection = new SqliteConnection(builder.ToString());
            connection.Open();

            using var tableCommand = connection.CreateCommand();
            tableCommand.CommandText =
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'threads'";
            if (Convert.ToInt64(tableCommand.ExecuteScalar()) == 0)
            {
                return true; // schema drift: no threads table -> zero threads, not an error
            }

            using var countCommand = connection.CreateCommand();
            countCommand.CommandText = "SELECT COUNT(*) FROM threads";
            threadCount = Convert.ToInt32(countCommand.ExecuteScalar());
            return true;
        }
        catch (Exception e) when (e is SqliteException or IOException or UnauthorizedAccessException)
        {
            threadCount = 0;
            return false;
        }
    }
}
