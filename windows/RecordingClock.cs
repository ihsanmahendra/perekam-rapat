using System.Diagnostics;

namespace PerekamRapat;

/// <summary>Jam rekaman bersama; waktu jeda tidak dihitung.</summary>
public sealed class RecordingClock
{
    private readonly Stopwatch _sw = new();
    private readonly object _lock = new();
    private TimeSpan _pausedTotal;
    private TimeSpan? _pauseStart;

    public void Begin()
    {
        lock (_lock) { _pausedTotal = TimeSpan.Zero; _pauseStart = null; _sw.Restart(); }
    }

    public bool IsPaused { get { lock (_lock) return _pauseStart != null; } }

    public TimeSpan Elapsed
    {
        get
        {
            lock (_lock)
            {
                var now = _sw.Elapsed;
                var paused = _pausedTotal + (_pauseStart is { } p ? now - p : TimeSpan.Zero);
                return now - paused;
            }
        }
    }

    public void Pause() { lock (_lock) { _pauseStart ??= _sw.Elapsed; } }

    public void Resume()
    {
        lock (_lock)
        {
            if (_pauseStart is { } p) { _pausedTotal += _sw.Elapsed - p; _pauseStart = null; }
        }
    }
}
