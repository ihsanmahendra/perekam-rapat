using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace PerekamRapat;

public sealed record AudioDevice(string Id, string Name)
{
    public override string ToString() => Name;
}

public static class AudioDevices
{
    public static List<AudioDevice> List(DataFlow flow)
    {
        using var enumerator = new MMDeviceEnumerator();
        var result = new List<AudioDevice>();
        foreach (var d in enumerator.EnumerateAudioEndPoints(flow, DeviceState.Active))
        {
            result.Add(new AudioDevice(d.ID, d.FriendlyName));
            d.Dispose();
        }
        return result.OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    /// <summary>Id kosong = perangkat default.</summary>
    public static MMDevice Get(DataFlow flow, string id)
    {
        using var enumerator = new MMDeviceEnumerator();
        return string.IsNullOrEmpty(id)
            ? enumerator.GetDefaultAudioEndpoint(flow, Role.Console)
            : enumerator.GetDevice(id);
    }
}

/// <summary>Mikrofon (WASAPI capture) atau suara sistem (WASAPI loopback pada perangkat output).</summary>
public sealed class AudioCapture : IDisposable
{
    private WasapiCapture? _capture;
    private bool _stopping;

    public event Action<byte[], int, WaveFormat>? Data;
    public event Action<Exception>? Failed;

    public void Start(string deviceId, bool loopback)
    {
        using var device = AudioDevices.Get(loopback ? DataFlow.Render : DataFlow.Capture, deviceId);
        var capture = loopback ? new WasapiLoopbackCapture(device) : new WasapiCapture(device);
        capture.DataAvailable += (_, e) => Data?.Invoke(e.Buffer, e.BytesRecorded, capture.WaveFormat);
        capture.RecordingStopped += (_, e) =>
        {
            if (!_stopping && e.Exception != null) Failed?.Invoke(e.Exception);
        };
        _capture = capture;
        capture.StartRecording();
    }

    public void Stop()
    {
        _stopping = true;
        try { _capture?.StopRecording(); } catch { /* perangkat sudah dicabut */ }
    }

    public void Dispose()
    {
        _stopping = true;
        _capture?.Dispose();
        _capture = null;
    }
}
