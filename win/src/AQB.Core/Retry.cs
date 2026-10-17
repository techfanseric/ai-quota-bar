namespace AQB.Core;

/// <summary>Small retry helper with exponential backoff, used by provider/team HTTP clients.</summary>
public static class Retry
{
    public static async Task<T> WithBackoffAsync<T>(
        Func<int, Task<T>> attempt,
        int maxAttempts = 3,
        TimeSpan? initialDelay = null,
        CancellationToken cancellationToken = default)
    {
        var delay = initialDelay ?? TimeSpan.FromSeconds(1);
        for (var i = 1; ; i++)
        {
            try
            {
                return await attempt(i);
            }
            catch (Exception e) when (i < maxAttempts && e is HttpRequestException or TaskCanceledException)
            {
                await Task.Delay(delay, cancellationToken);
                delay *= 2;
            }
        }
    }
}
