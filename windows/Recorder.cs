using System.Globalization;
using NAudio.CoreAudioApi;

namespace PerekamRapat;

public enum RecState { Idle, Starting, Recording, Paused, Saving }
public enum NoticeKind { Info, Error, Permission }
public sealed record Notice(NoticeKind Kind, string Text, string? SettingsUri = null);

/// <summary>Mengatur sesi rekaman: sumber audio, jeda, tanda, dan penggabungan akhir.</summary>
public sealed class Recorder
{
    public RecState State { get; private set; } = RecState.Idle;
    public string Title { get; set; } = "";
    public bool MicEnabled { get; set; } = true;
    public bool SystemEnabled { get; set; } = true;
    public string MicDeviceId { get; set; } = "";
    public string SystemDeviceId { get; set; } = "";
    public double MicVolume { get; set; } = 1;
    public double SystemVolume { get; set; } = 1;
    public bool KeepTracks { get; set; }
    public List<Mark> Marks { get; private set; } = new();
    public volatile Notice? Notice;

    public bool IsRecording => State is RecState.Recording or RecState.Paused;
    public bool IsBusy => State != RecState.Idle;
    public TimeSpan Elapsed => _clock.Elapsed;
    public float MicLevel => _micWriter?.Level ?? 0;
    public float SystemLevel => _systemWriter?.Level ?? 0;

    private RecordingClock _clock = new();
    private AudioCapture? _mic, _system;
    private TrackWriter? _micWriter, _systemWriter;
    private string? _folder;
    private DateTime _startDate;
    private string _sessionTitle = "";
    private readonly List<string> _sources = new();

    public void Start()
    {
        if (State != RecState.Idle) return;
        Notice = null;
        if (!MicEnabled && !SystemEnabled)
        {
            Notice = new(NoticeKind.Error, "Aktifkan minimal satu sumber audio.");
            return;
        }

        State = RecState.Starting;
        _startDate = DateTime.Now;
        _sessionTitle = DisplayTitle(_startDate);
        string folder;
        try { folder = Library.Shared.MakeFolder(_sessionTitle, _startDate); }
        catch (Exception e)
        {
            Notice = new(NoticeKind.Error, $"Folder rekaman tidak bisa dibuat: {e.Message}");
            State = RecState.Idle;
            return;
        }
        var trackDir = Path.Combine(folder, "Track");
        Directory.CreateDirectory(trackDir);

        _clock = new RecordingClock();
        _clock.Begin();
        _sources.Clear();
        try
        {
            if (MicEnabled)
            {
                var writer = new TrackWriter(Path.Combine(trackDir, "mikrofon.wav"), _clock);
                var capture = new AudioCapture();
                capture.Data += writer.Write;
                capture.Failed += e => Notice = new(NoticeKind.Error,
                    $"Mikrofon berhenti direkam ({e.Message}).");
                _micWriter = writer;
                _mic = capture;
                capture.Start(MicDeviceId, loopback: false);
                _sources.Add(MicDeviceId == "" ? "Mikrofon" : DeviceName(DataFlow.Capture, MicDeviceId));
            }
            if (SystemEnabled)
            {
                var writer = new TrackWriter(Path.Combine(trackDir, "sistem.wav"), _clock);
                var capture = new AudioCapture();
                capture.Data += writer.Write;
                capture.Failed += e => Notice = new(NoticeKind.Error,
                    $"Audio internal berhenti direkam ({e.Message}). Mikrofon tetap merekam.");
                _systemWriter = writer;
                _system = capture;
                capture.Start(SystemDeviceId, loopback: true);
                _sources.Add("Audio sistem");
            }
        }
        catch (Exception e)
        {
            Teardown();
            _micWriter?.Finish(); _systemWriter?.Finish();
            _micWriter = null; _systemWriter = null;
            try { Directory.Delete(folder, recursive: true); } catch { }
            Notice = e is UnauthorizedAccessException
                ? new(NoticeKind.Permission,
                      "Akses mikrofon ditolak. Izinkan aplikasi desktop memakai mikrofon di Pengaturan › Privasi & keamanan › Mikrofon.",
                      "ms-settings:privacy-microphone")
                : new(NoticeKind.Error, $"Gagal memulai rekaman: {e.Message}");
            State = RecState.Idle;
            return;
        }

        _folder = folder;
        Marks = new();
        State = RecState.Recording;
    }

    public void TogglePause()
    {
        if (State == RecState.Recording) { _clock.Pause(); State = RecState.Paused; }
        else if (State == RecState.Paused) { _clock.Resume(); State = RecState.Recording; }
    }

    public void AddMark(string note)
    {
        if (!IsRecording) return;
        note = note.Trim();
        Marks.Add(new Mark { Time = _clock.Elapsed.TotalSeconds, Label = note.Length == 0 ? $"Tanda {Marks.Count + 1}" : note });
    }

    public async Task StopAsync()
    {
        if (!IsRecording || _folder == null) return;
        var folder = _folder;
        var duration = _clock.Elapsed.TotalSeconds;
        State = RecState.Saving;
        Teardown();

        var trackDir = Path.Combine(folder, "Track");
        var tracks = new List<(string, float)>();
        if (_micWriter is { } m && m.Finish()) tracks.Add((m.Path, (float)MicVolume));
        if (_systemWriter is { } s && s.Finish()) tracks.Add((s.Path, (float)SystemVolume));
        _micWriter = null; _systemWriter = null; _folder = null;

        try
        {
            if (tracks.Count == 0)
            {
                try { Directory.Delete(folder, recursive: true); } catch { }
                Notice = new(NoticeKind.Error, "Tidak ada audio yang tertangkap. Periksa mikrofon dan sumber audio sistem.");
                return;
            }

            var fileName = Library.SafeName(_sessionTitle) + ".m4a";
            try
            {
                await Task.Run(() => Mixer.Mix(tracks, Path.Combine(folder, fileName)));
                if (!KeepTracks) { try { Directory.Delete(trackDir, recursive: true); } catch { } }
                var info = new RecordingInfo
                {
                    Name = _sessionTitle, Date = _startDate, Duration = duration,
                    Marks = Marks, Sources = _sources.ToList(), AudioFile = fileName,
                };
                Library.Shared.Save(info, folder);
                Notice = new(NoticeKind.Info, $"Tersimpan: {_sessionTitle} ({Fmt.Time(duration)}).");
                Title = "";
                Marks = new();
            }
            catch (Exception e)
            {
                Notice = new(NoticeKind.Error,
                    $"Rekaman tidak bisa digabung: {e.Message} Track mentah tetap ada di folder Track.");
            }
        }
        finally
        {
            State = RecState.Idle;
            Library.Shared.Refresh();
        }
    }

    private void Teardown()
    {
        _mic?.Stop(); _system?.Stop();
        _mic?.Dispose(); _system?.Dispose();
        _mic = null; _system = null;
    }

    private static string DeviceName(DataFlow flow, string id)
    {
        try { using var d = AudioDevices.Get(flow, id); return d.FriendlyName; }
        catch { return "Mikrofon"; }
    }

    private string DisplayTitle(DateTime date)
    {
        var t = Title.Trim();
        if (t.Length > 0) return t;
        return "Rapat " + date.ToString("d MMM yyyy HH'.'mm", new CultureInfo("id-ID"));
    }
}
