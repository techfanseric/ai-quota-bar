using System.Text.Json;
using System.Text.Json.Nodes;

namespace AQB.Core;

public static class Json
{
    public static readonly JsonSerializerOptions SnakeCase = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public static readonly JsonSerializerOptions CamlCaseWrite = new(JsonSerializerDefaults.General)
    {
        WriteIndented = false,
    };

    public static JsonNode? ToNode(object value) => JsonSerializer.SerializeToNode(value, SnakeCase);

    /// <summary>Reads a JSON file tolerating missing files and parse failures (returns null).</summary>
    public static JsonNode? TryReadFile(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }

            return JsonNode.Parse(File.ReadAllText(path));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    public static string GetString(this JsonNode? node, string key, string fallback = "")
    {
        var value = node?[key];
        return value is null ? fallback : value.ToString();
    }

    public static long GetLong(this JsonNode? node, string key, long fallback = 0)
    {
        var value = node?[key];
        if (value is null)
        {
            return fallback;
        }

        try
        {
            return value.GetValue<long>();
        }
        catch (FormatException)
        {
            return long.TryParse(value.ToString(), out var parsed) ? parsed : fallback;
        }
    }

    public static double GetDouble(this JsonNode? node, string key, double fallback = 0)
    {
        var value = node?[key];
        if (value is null)
        {
            return fallback;
        }

        try
        {
            return value.GetValue<double>();
        }
        catch (FormatException)
        {
            return double.TryParse(value.ToString(), out var parsed) ? parsed : fallback;
        }
    }

    public static bool GetBool(this JsonNode? node, string key, bool fallback = false)
    {
        var value = node?[key];
        if (value is null)
        {
            return fallback;
        }

        try
        {
            return value.GetValue<bool>();
        }
        catch (FormatException)
        {
            return bool.TryParse(value.ToString(), out var parsed) && parsed;
        }
    }

    /// <summary>Atomic write: temp file + File.Replace/File.Move.</summary>
    public static void AtomicWrite(string path, string content)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var temp = path + ".tmp";
        File.WriteAllText(temp, content);
        if (File.Exists(path))
        {
            File.Replace(temp, path, null);
        }
        else
        {
            File.Move(temp, path);
        }
    }
}
