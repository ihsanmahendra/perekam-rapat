using System.Diagnostics;
using NAudio.Wave;

namespace PerekamRapat;

/// <summary>
/// Menulis satu sumber audio ke file WAV dan menyisipkan hening bila ada celah
/// (mis. loopback tidak mengirim data saat tidak ada suara) supaya track tetap sejajar jam rekaman.
/// </summary>
public sealed class TrackWriter
{
    public string Path { get; }
    public Exception? LastError { get; private set; }

    private readonly RecordingClock _clock;
    private readonly object _lock = new();
    private WaveFileWriter? _writer;
    private WaveFormat? _format;
    private long _frames;
    private float _peak;
    private long _peakTick;

    public TrackWriter(string path, RecordingClock clock) { Path = path; _clock = clock; }

    /// <summary>Level puncak terbaru (0..1), meluruh bila tidak ada buffer baru.</summary>
    public float Level { get { lock (_lock) return DecayedPeak(); } }

    public void Write(byte[] data, int count, WaveFormat source)
    {
        var bufferPeak = PeakOf(data, count, source);
        lock (_lock)
        {
            _peak = Math.Max(bufferPeak, DecayedPeak());
            _peakTick = Stopwatch.GetTimestamp();
            if (_clock.IsPaused || count <= 0) return;
            try
            {
                _format ??= Simplify(source);
                _writer ??= new WaveFileWriter(Path, _format);

                var bufferSeconds = (double)count / _format.AverageBytesPerSecond;
                var position = Math.Max(0, _clock.Elapsed.TotalSeconds - bufferSeconds);
                var expected = (long)(position * _format.SampleRate);
                var gap = expected - _frames;
                if (gap > _format.SampleRate / 10) WriteSilence(gap);

                var usable = count - count % _format.BlockAlign;
                _writer.Write(data, 0, usable);
                _frames += usable / _format.BlockAlign;
            }
            catch (Exception e) { LastError = e; }
        }
    }

    /// <summary>Menutup file. Mengembalikan true bila ada audio yang tertulis.</summary>
    public bool Finish()
    {
        lock (_lock)
        {
            _writer?.Dispose();
            _writer = null;
            return _frames > 0;
        }
    }

    private void WriteSilence(long frames)
    {
        var chunk = new byte[_format!.BlockAlign * 4800];
        while (frames > 0)
        {
            var n = (int)Math.Min(frames, 4800);
            _writer!.Write(chunk, 0, n * _format.BlockAlign);
            _frames += n;
            frames -= n;
        }
    }

    private float DecayedPeak()
    {
        var age = (Stopwatch.GetTimestamp() - _peakTick) / (double)Stopwatch.Frequency;
        return _peak * (float)Math.Max(0, 1 - age * 4);
    }

    private static WaveFormat Simplify(WaveFormat f) =>
        f.BitsPerSample == 32
            ? WaveFormat.CreateIeeeFloatWaveFormat(f.SampleRate, f.Channels)
            : new WaveFormat(f.SampleRate, f.BitsPerSample, f.Channels);

    private static float PeakOf(byte[] data, int count, WaveFormat f)
    {
        float peak = 0;
        if (f.BitsPerSample == 32)
        {
            for (var i = 0; i + 4 <= count; i += 4)
                peak = Math.Max(peak, Math.Abs(BitConverter.ToSingle(data, i)));
        }
        else if (f.BitsPerSample == 16)
        {
            for (var i = 0; i + 2 <= count; i += 2)
                peak = Math.Max(peak, Math.Abs((float)BitConverter.ToInt16(data, i)) / 32768f);
        }
        return Math.Min(peak, 1f);
    }
}
