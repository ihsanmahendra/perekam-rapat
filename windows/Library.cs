using System.IO;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.VisualBasic.FileIO;
using NAudio.MediaFoundation;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace PerekamRapat;

public static class Fmt
{
    public static string Time(double t)
    {
        var s = Math.Max(0, (int)t);
        return $"{s / 3600:00}:{s / 60 % 60:00}:{s % 60:00}";
    }
}

public sealed class Mark
{
    public double Time { get; set; }
    public string Label { get; set; } = "";
}

/// <summary>Format sama dengan info.json versi macOS.</summary>
public sealed class RecordingInfo
{
    public string Name { get; set; } = "";
    public DateTime Date { get; set; }
    public double Duration { get; set; }
    public List<Mark> Marks { get; set; } = new();
    public List<string> Sources { get; set; } = new();
    public string AudioFile { get; set; } = "";
}

public sealed class Recording
{
    public required string Folder { get; init; }
    public required RecordingInfo Info { get; init; }
    public string AudioPath => Path.Combine(Folder, Info.AudioFile);
}

internal sealed class IsoDateConverter : JsonConverter<DateTime>
{
    public override DateTime Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) =>
        DateTime.Parse(r.GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);

    public override void Write(Utf8JsonWriter w, DateTime v, JsonSerializerOptions o) =>
        w.WriteStringValue(v.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
}

/// <summary>Folder Dokumen\Perekam Rapat; satu subfolder per rekaman berisi .m4a, info.json dan Tanda.txt.</summary>
public sealed class Library
{
    public static readonly Library Shared = new();
    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new IsoDateConverter() },
    };

    public string Root { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Perekam Rapat");
    public List<Recording> Items { get; private set; } = new();

    public void Refresh()
    {
        var list = new List<Recording>();
        if (Directory.Exists(Root))
        {
            foreach (var folder in Directory.GetDirectories(Root))
            {
                var file = Path.Combine(folder, "info.json");
                if (!File.Exists(file)) continue;
                try
                {
                    var info = JsonSerializer.Deserialize<RecordingInfo>(File.ReadAllText(file), Json);
                    if (info != null) list.Add(new Recording { Folder = folder, Info = info });
                }
                catch { /* info.json rusak: lewati */ }
            }
        }
        Items = list.OrderByDescending(r => r.Info.Date).ToList();
    }

    public string MakeFolder(string title, DateTime date)
    {
        var stamp = date.ToString("yyyy-MM-dd HH'.'mm'.'ss", CultureInfo.InvariantCulture);
        var folder = Path.Combine(Root, $"{stamp} - {SafeName(title)}");
        Directory.CreateDirectory(folder);
        return folder;
    }

    public void Save(RecordingInfo info, string folder)
    {
        File.WriteAllText(Path.Combine(folder, "info.json"), JsonSerializer.Serialize(info, Json));
        if (info.Marks.Count > 0)
        {
            var lines = info.Marks.Select(m => $"{Fmt.Time(m.Time)}  {m.Label}");
            File.WriteAllText(Path.Combine(folder, "Tanda.txt"),
                info.Name + "\n\n" + string.Join("\n", lines) + "\n", new UTF8Encoding(false));
        }
    }

    public void Trash(Recording r)
    {
        try
        {
            FileSystem.DeleteDirectory(r.Folder, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
        }
        catch { /* dibatalkan atau gagal */ }
        Refresh();
    }

    public static string SafeName(string s)
    {
        var bad = Path.GetInvalidFileNameChars().Append('%').ToArray();
        var cleaned = string.Join("-", s.Split(bad)).Trim().TrimEnd('.');
        if (cleaned.Length == 0) return "Rapat";
        return cleaned.Length > 80 ? cleaned[..80].TrimEnd() : cleaned;
    }
}

/// <summary>Menggabungkan beberapa track WAV menjadi satu file .m4a (AAC) dengan volume masing-masing.</summary>
public static class Mixer
{
    private const int OutRate = 48000;
    private static bool _started;

    public static void Mix(IReadOnlyList<(string Path, float Volume)> tracks, string output)
    {
        if (!_started) { MediaFoundationApi.Startup(); _started = true; }
        var readers = new List<AudioFileReader>();
        try
        {
            var inputs = new List<ISampleProvider>();
            foreach (var (path, volume) in tracks)
            {
                var reader = new AudioFileReader(path) { Volume = volume };
                readers.Add(reader);
                ISampleProvider sp = reader;
                if (sp.WaveFormat.Channels > 2)
                {
                    var mux = new MultiplexingSampleProvider(new[] { sp }, 2);
                    mux.ConnectInputToOutput(0, 0);
                    mux.ConnectInputToOutput(1, 1);
                    sp = mux;
                }
                if (sp.WaveFormat.SampleRate != OutRate) sp = new WdlResamplingSampleProvider(sp, OutRate);
                if (sp.WaveFormat.Channels == 1) sp = new MonoToStereoSampleProvider(sp);
                inputs.Add(sp);
            }
            if (inputs.Count == 0) throw new InvalidOperationException("Tidak ada audio yang tertangkap.");

            var mixer = new MixingSampleProvider(inputs);
            if (File.Exists(output)) File.Delete(output);
            MediaFoundationEncoder.EncodeToAac(new SampleToWaveProvider16(mixer), output, 160_000);
        }
        finally
        {
            foreach (var r in readers) r.Dispose();
        }
    }
}

/// <summary>Pemutar sederhana untuk daftar rekaman.</summary>
public sealed class Player
{
    public string? Current { get; private set; }
    public bool IsPlaying { get; private set; }
    public event Action? Changed;

    private WaveOutEvent? _output;
    private MediaFoundationReader? _reader;
    private EventHandler<StoppedEventArgs>? _stoppedHandler;

    public void Toggle(string path)
    {
        if (Current == path && _output != null)
        {
            if (IsPlaying) _output.Pause(); else _output.Play();
            IsPlaying = !IsPlaying;
            Changed?.Invoke();
        }
        else Play(path, 0);
    }

    public void Play(string path, double at)
    {
        if (Current != path)
        {
            Stop();
            _reader = new MediaFoundationReader(path);
            _output = new WaveOutEvent();
            _output.Init(_reader);
            _stoppedHandler = (_, _) =>
            {
                IsPlaying = false;
                if (_reader != null) _reader.Position = 0;
                Changed?.Invoke();
            };
            _output.PlaybackStopped += _stoppedHandler;
            Current = path;
        }
        _reader!.CurrentTime = TimeSpan.FromSeconds(at);
        _output!.Play();
        IsPlaying = true;
        Changed?.Invoke();
    }

    public void Stop()
    {
        if (_output != null && _stoppedHandler != null) _output.PlaybackStopped -= _stoppedHandler;
        _output?.Stop();
        _output?.Dispose();
        _reader?.Dispose();
        _output = null; _reader = null; _stoppedHandler = null;
        Current = null;
        IsPlaying = false;
    }
}
