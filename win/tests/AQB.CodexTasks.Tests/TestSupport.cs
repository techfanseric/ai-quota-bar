namespace AQB.CodexTasks.Tests;

public sealed class TempDir : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(
        System.IO.Path.GetTempPath(), "aqb-codex-tests", Guid.NewGuid().ToString("N"));

    public TempDir()
    {
        Directory.CreateDirectory(Path);
    }

    public string File(string name) => System.IO.Path.Combine(Path, name);

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}

public sealed class MutableClock
{
    private DateTimeOffset _now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public DateTimeOffset UtcNow => _now;

    public void Advance(TimeSpan span) => _now = _now.Add(span);

    public void Set(DateTimeOffset value) => _now = value;

    public Func<DateTimeOffset> AsFunc() => () => _now;
}

public static class Iso
{
    /// <summary>Fixed-millisecond ISO used by the log/watcher lines.</summary>
    public static string Write(DateTimeOffset value) =>
        value.ToUniversalTime().UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffZ",
            System.Globalization.CultureInfo.InvariantCulture);
}
