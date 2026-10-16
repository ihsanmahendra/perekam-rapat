import Foundation
import AVFoundation
import Accelerate

/// Menulis satu sumber audio ke file AAC (.m4a), menyisipkan hening bila ada celah
/// supaya track tetap sejajar dengan jam rekaman.
final class TrackWriter: @unchecked Sendable {
    let url: URL
    private let clock: RecordingClock
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0
    private var peak: Float = 0
    private var peakTime: Double = 0
    private(set) var lastError: Error?

    init(url: URL, clock: RecordingClock) {
        self.url = url
        self.clock = clock
    }

    /// Level puncak terbaru (0…1), meluruh bila tidak ada buffer baru.
    var level: Float {
        lock.locked { decayedPeak() }
    }

    func write(_ buffer: AVAudioPCMBuffer, hostTime: Double) {
        let bufferPeak = Self.peak(of: buffer)
        lock.locked {
            peak = max(bufferPeak, decayedPeak())
            peakTime = RecordingClock.now()

            guard let position = clock.position(at: hostTime) else { return }
            do {
                if file == nil { try open(for: buffer.format) }
                guard let file, let fileFormat else { return }
                let pcm = try convert(buffer, to: fileFormat)
                let expected = AVAudioFramePosition(position * fileFormat.sampleRate)
                let gap = expected - framesWritten
                if gap > AVAudioFramePosition(fileFormat.sampleRate * 0.1) {
                    try writeSilence(frames: gap, to: file, format: fileFormat)
                }
                if pcm.frameLength > 0 {
                    try file.write(from: pcm)
                    framesWritten += AVAudioFramePosition(pcm.frameLength)
                }
            } catch {
                lastError = error
            }
        }
    }

    /// Menutup file. Mengembalikan true bila ada audio yang tertulis.
    @discardableResult
    func finish() -> Bool {
        lock.locked {
            file = nil
            converter = nil
            return framesWritten > 0
        }
    }

    // MARK: - Internal

    /// Dipanggil saat lock sudah dipegang.
    private func decayedPeak() -> Float {
        let age = RecordingClock.now() - peakTime
        return peak * Float(max(0, 1 - age * 4))
    }

    private func open(for format: AVAudioFormat) throws {
        let channels = min(max(format.channelCount, 1), 2)
        let sampleRate = min(format.sampleRate, 48_000)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000
        ]
        let newFile = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        file = newFile
        fileFormat = newFile.processingFormat
        if format != newFile.processingFormat {
            converter = AVAudioConverter(from: format, to: newFile.processingFormat)
            converter?.downmix = true
            if converter == nil { throw RecorderError.audioFormat }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw RecorderError.audioFormat
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw (error as Error?) ?? RecorderError.audioFormat }
        return out
    }

    private func writeSilence(frames: AVAudioFramePosition, to file: AVAudioFile, format: AVAudioFormat) throws {
        let chunk: AVAudioFrameCount = 8192
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let data = silence.floatChannelData else { return }
        for c in 0..<Int(format.channelCount) {
            memset(data[c], 0, Int(chunk) * MemoryLayout<Float>.size)
        }
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, AVAudioFramePosition(chunk))
            silence.frameLength = AVAudioFrameCount(n)
            try file.write(from: silence)
            remaining -= n
            framesWritten += n
        }
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let interleaved = buffer.format.isInterleaved
        let channels = interleaved ? 1 : Int(buffer.format.channelCount)
        let count = Int(buffer.frameLength) * (interleaved ? Int(buffer.format.channelCount) : 1)
        var result: Float = 0
        for c in 0..<channels {
            var m: Float = 0
            vDSP_maxmgv(data[c], 1, &m, vDSP_Length(count))
            result = max(result, m)
        }
        return min(result, 1)
    }
}
