import Foundation
import AVFoundation
import ScreenCaptureKit

/// Merekam audio internal (suara sistem atau satu aplikasi, mis. Zoom) lewat ScreenCaptureKit.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onBuffer: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
    var onStop: (@Sendable (Error) -> Void)?

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "perekam.system-audio", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "perekam.system-video", qos: .utility)

    /// - Parameter appBundleID: nil untuk semua suara sistem, atau bundle id satu aplikasi.
    func start(appBundleID: String?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter: SCContentFilter
        if let appBundleID {
            let targets = content.applications.filter { $0.bundleIdentifier == appBundleID }
            guard !targets.isEmpty else { throw RecorderError.appNotFound }
            filter = SCContentFilter(display: display, including: targets, exceptingWindows: [])
        } else {
            let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // ScreenCaptureKit selalu butuh video; dibuat sekecil dan sejarang mungkin lalu diabaikan.
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = sampleBuffer.copyPCMBuffer() else { return }
        onBuffer?(pcm, RecordingClock.hostSeconds(from: sampleBuffer.presentationTimeStamp))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}

extension CMSampleBuffer {
    func copyPCMBuffer() -> AVAudioPCMBuffer? {
        guard isValid, CMSampleBufferDataIsReady(self), let description = formatDescription else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0 else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
