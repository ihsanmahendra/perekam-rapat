import Foundation
import AVFoundation
import AppKit
import CoreGraphics
import CoreAudio

struct RunningApp: Identifiable, Hashable {
    let id: String   // bundle id
    let name: String
}

enum Notice: Equatable {
    case info(String)
    case error(String)
    case permission(String, pane: String)

    var text: String {
        switch self {
        case .info(let s), .error(let s), .permission(let s, _): return s
        }
    }
}

enum Permissions {
    static func microphone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Mengatur sesi rekaman: izin, sumber audio, jeda, tanda, dan penggabungan akhir.
final class Recorder: ObservableObject {
    static let shared = Recorder()

    enum State { case idle, starting, recording, paused, saving }

    @Published private(set) var state: State = .idle
    @Published var title = ""
    @Published var micEnabled = true
    @Published var systemEnabled = true
    @Published var micDeviceID: AudioDeviceID?
    @Published var appChoice = ""            // "" = semua audio sistem
    @Published var micVolume = 1.0
    @Published var systemVolume = 1.0
    @Published var keepTracks = false
    @Published var markNote = ""
    @Published private(set) var micDevices: [AudioDevice] = []
    @Published private(set) var apps: [RunningApp] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var marks: [Mark] = []
    @Published var notice: Notice?

    private var clock = RecordingClock()
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var micWriter: TrackWriter?
    private var systemWriter: TrackWriter?
    private var folder: URL?
    private var startDate = Date()
    private var sessionTitle = ""
    private var sessionSources: [String] = []
    private var ticker: Task<Void, Never>?

    var isRecording: Bool { state == .recording || state == .paused }
    var isBusy: Bool { state != .idle }

    @MainActor func refreshSources() {
        micDevices = AudioDevices.inputDevices()
        if let id = micDeviceID, !micDevices.contains(where: { $0.id == id }) { micDeviceID = nil }

        let mine = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, id != mine else { return nil }
                return RunningApp(id: id, name: app.localizedName ?? id)
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !appChoice.isEmpty, !apps.contains(where: { $0.id == appChoice }) { appChoice = "" }
    }

    @MainActor func start() async {
        guard state == .idle else { return }
        notice = nil
        guard micEnabled || systemEnabled else {
            notice = .error("Aktifkan minimal satu sumber audio.")
            return
        }
        if micEnabled, !(await Permissions.microphone()) {
            notice = .permission("Akses mikrofon ditolak. Izinkan Perekam Rapat di Pengaturan Sistem › Privasi & Keamanan › Mikrofon.",
                                 pane: "Privacy_Microphone")
            return
        }
        if systemEnabled, !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            notice = .permission("Untuk merekam audio internal, izinkan Perekam Rapat di Pengaturan Sistem › Privasi & Keamanan › Perekaman Layar & Audio Sistem, lalu buka ulang aplikasi.",
                                 pane: "Privacy_ScreenCapture")
            return
        }

        state = .starting
        startDate = Date()
        sessionTitle = displayTitle(for: startDate)
        let folder: URL
        do {
            folder = try Library.shared.makeFolder(title: sessionTitle, date: startDate)
        } catch {
            notice = .error("Folder rekaman tidak bisa dibuat: \(error.localizedDescription)")
            state = .idle
            return
        }
        let trackDir = folder.appendingPathComponent("Track", isDirectory: true)
        try? FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)

        let clock = RecordingClock()
        self.clock = clock
        clock.begin()
        sessionSources = []
        do {
            if micEnabled {
                let writer = TrackWriter(url: trackDir.appendingPathComponent("mikrofon.m4a"), clock: clock)
                let capture = MicCapture()
                capture.onBuffer = { buffer, time in writer.write(buffer, hostTime: time) }
                micWriter = writer
                mic = capture
                try capture.start(deviceID: micDeviceID)
                sessionSources.append(micDevices.first { $0.id == micDeviceID }?.name ?? "Mikrofon")
            }
            if systemEnabled {
                let writer = TrackWriter(url: trackDir.appendingPathComponent("sistem.m4a"), clock: clock)
                let capture = SystemAudioCapture()
                capture.onBuffer = { buffer, time in writer.write(buffer, hostTime: time) }
                capture.onStop = { [weak self] error in
                    Task { @MainActor in self?.systemStopped(error) }
                }
                systemWriter = writer
                system = capture
                try await capture.start(appBundleID: appChoice.isEmpty ? nil : appChoice)
                sessionSources.append(apps.first { $0.id == appChoice }.map { "Audio \($0.name)" } ?? "Audio sistem")
            }
        } catch {
            await teardown()
            micWriter?.finish(); systemWriter?.finish()
            micWriter = nil; systemWriter = nil
            try? FileManager.default.removeItem(at: folder)
            notice = .error("Gagal memulai rekaman: \(error.localizedDescription)")
            state = .idle
            return
        }

        self.folder = folder
        marks = []
        state = .recording
        startTicker()
    }

    @MainActor func togglePause() {
        switch state {
        case .recording: clock.pause(); state = .paused
        case .paused: clock.resume(); state = .recording
        default: break
        }
    }

    @MainActor func addMark() {
        guard isRecording else { return }
        let note = markNote.trimmingCharacters(in: .whitespacesAndNewlines)
        marks.append(Mark(time: clock.elapsed, label: note.isEmpty ? "Tanda \(marks.count + 1)" : note))
        markNote = ""
    }

    @MainActor func stop() async {
        guard isRecording, let folder else { return }
        let duration = clock.elapsed
        state = .saving
        ticker?.cancel()
        await teardown()

        let trackDir = folder.appendingPathComponent("Track", isDirectory: true)
        var tracks: [(url: URL, volume: Float)] = []
        if let w = micWriter, w.finish() { tracks.append((w.url, Float(micVolume))) }
        if let w = systemWriter, w.finish() { tracks.append((w.url, Float(systemVolume))) }
        micWriter = nil
        systemWriter = nil
        self.folder = nil

        defer {
            state = .idle
            elapsed = 0
            Library.shared.refresh()
        }
        guard !tracks.isEmpty else {
            try? FileManager.default.removeItem(at: folder)
            notice = .error("Tidak ada audio yang tertangkap. Periksa mikrofon dan sumber audio sistem.")
            return
        }

        let fileName = Library.safeName(sessionTitle) + ".m4a"
        do {
            try await Mixer.mix(tracks, to: folder.appendingPathComponent(fileName))
            if !keepTracks { try? FileManager.default.removeItem(at: trackDir) }
            let info = RecordingInfo(name: sessionTitle, date: startDate, duration: duration,
                                     marks: marks, sources: sessionSources, audioFile: fileName)
            try Library.shared.save(info, in: folder)
            notice = .info("Tersimpan: \(sessionTitle) (\(formatTime(duration))).")
            title = ""
            marks = []
        } catch {
            notice = .error("Rekaman tidak bisa digabung: \(error.localizedDescription) Track mentah tetap ada di folder Track.")
        }
    }

    // MARK: - Internal

    @MainActor private func teardown() async {
        mic?.stop()
        mic = nil
        await system?.stop()
        system = nil
        micLevel = 0
        systemLevel = 0
    }

    @MainActor private func systemStopped(_ error: Error) {
        guard isRecording else { return }
        system = nil
        notice = .error("Audio internal berhenti direkam (\(error.localizedDescription)). Mikrofon tetap merekam.")
    }

    @MainActor private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.elapsed = self.clock.elapsed
                self.micLevel = self.micWriter?.level ?? 0
                self.systemLevel = self.systemWriter?.level ?? 0
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func displayTitle(for date: Date) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateFormat = "d MMM yyyy HH.mm"
        return "Rapat \(f.string(from: date))"
    }
}
