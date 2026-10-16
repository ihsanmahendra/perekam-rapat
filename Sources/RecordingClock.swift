import Foundation
import AVFoundation
import CoreMedia

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Jam bersama untuk semua track. Posisi tiap buffer dihitung dari waktu host-nya,
/// sehingga mikrofon dan audio sistem tetap sinkron walau mulai pada saat berbeda.
final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var startTime: Double?
    private var pausedAt: Double?
    private var pausedTotal: Double = 0

    static func now() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    /// Waktu host dari sebuah buffer; kembali ke "sekarang" bila stempel waktunya tidak masuk akal.
    static func sanitized(_ seconds: Double) -> Double {
        let current = now()
        return seconds.isFinite && abs(seconds - current) < 5 ? seconds : current
    }

    static func hostSeconds(from time: CMTime) -> Double {
        sanitized(time.seconds)
    }

    static func hostSeconds(fromHostTime hostTime: UInt64) -> Double {
        sanitized(AVAudioTime.seconds(forHostTime: hostTime))
    }

    func begin() {
        lock.locked { startTime = Self.now() }
    }

    func pause() {
        lock.locked { if pausedAt == nil { pausedAt = Self.now() } }
    }

    func resume() {
        lock.locked {
            if let p = pausedAt {
                pausedTotal += Self.now() - p
                pausedAt = nil
            }
        }
    }

    /// Posisi (detik) di dalam rekaman untuk buffer pada waktu host `t`; nil saat dijeda.
    func position(at t: Double) -> Double? {
        lock.locked {
            guard let s = startTime, pausedAt == nil else { return nil }
            return max(0, t - s - pausedTotal)
        }
    }

    var elapsed: Double {
        lock.locked {
            guard let s = startTime else { return 0 }
            return max(0, (pausedAt ?? Self.now()) - s - pausedTotal)
        }
    }
}
