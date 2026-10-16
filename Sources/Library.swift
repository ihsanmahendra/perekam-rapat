import Foundation
import AppKit
import AVFoundation

struct Mark: Codable, Hashable {
    var time: TimeInterval
    var label: String
}

struct RecordingInfo: Codable, Hashable {
    var name: String
    var date: Date
    var duration: TimeInterval
    var marks: [Mark]
    var sources: [String]
    var audioFile: String
}

struct Recording: Identifiable, Hashable {
    let folder: URL
    let info: RecordingInfo
    var id: URL { folder }
    var audioURL: URL { folder.appendingPathComponent(info.audioFile) }
}

enum RecorderError: LocalizedError {
    case noMicrophone
    case micDevice(OSStatus)
    case noDisplay
    case appNotFound
    case audioFormat
    case nothingRecorded
    case exportFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "Tidak ada mikrofon yang terdeteksi."
        case .micDevice(let s): return "Mikrofon yang dipilih tidak bisa dipakai (kode \(s))."
        case .noDisplay: return "Tidak ada layar yang bisa dipakai untuk menangkap audio sistem."
        case .appNotFound: return "Aplikasi yang dipilih sudah tidak berjalan. Muat ulang daftar aplikasi."
        case .audioFormat: return "Format audio tidak didukung."
        case .nothingRecorded: return "Tidak ada audio yang tertangkap."
        case .exportFailed(let e): return "Gagal menggabungkan audio" + (e.map { ": \($0.localizedDescription)" } ?? ".")
        }
    }
}

/// Folder ~/Documents/Perekam Rapat; satu subfolder per rekaman berisi .m4a, info.json dan Tanda.txt.
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var items: [Recording] = []
    let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Perekam Rapat", isDirectory: true)
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("info.json")),
                  let info = try? decoder.decode(RecordingInfo.self, from: data) else { return nil }
            return Recording(folder: folder, info: info)
        }
        .sorted { $0.info.date > $1.info.date }
    }

    func makeFolder(title: String, date: Date) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = root.appendingPathComponent("\(stamp.string(from: date)) - \(Self.safeName(title))",
                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func save(_ info: RecordingInfo, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: folder.appendingPathComponent("info.json"))
        if !info.marks.isEmpty {
            let text = info.marks.map { "\(formatTime($0.time))  \($0.label)" }.joined(separator: "\n")
            try? (info.name + "\n\n" + text + "\n").write(to: folder.appendingPathComponent("Tanda.txt"),
                                                          atomically: true, encoding: .utf8)
        }
    }

    func trash(_ recording: Recording) {
        try? FileManager.default.trashItem(at: recording.folder, resultingItemURL: nil)
        refresh()
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.audioURL])
    }

    func openRoot() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Rapat" : String(cleaned.prefix(80))
    }
}

/// Menggabungkan beberapa track menjadi satu file .m4a dengan volume masing-masing.
enum Mixer {
    static func mix(_ tracks: [(url: URL, volume: Float)], to output: URL) async throws {
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for track in tracks {
            let asset = AVURLAsset(url: track.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            guard let target = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            let p = AVMutableAudioMixInputParameters(track: target)
            p.setVolume(track.volume, at: .zero)
            parameters.append(p)
        }
        guard !parameters.isEmpty else { throw RecorderError.nothingRecorded }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.exportFailed(nil)
        }
        export.outputURL = output
        export.outputFileType = .m4a
        export.audioMix = audioMix
        await export.export()
        guard export.status == .completed else { throw RecorderError.exportFailed(export.error) }
    }
}

/// Pemutar sederhana untuk daftar rekaman.
final class Player: ObservableObject {
    @Published private(set) var current: URL?
    @Published private(set) var isPlaying = false
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func toggle(_ url: URL) {
        if current == url, let player {
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
        } else {
            play(url, at: 0)
        }
    }

    func play(_ url: URL, at time: TimeInterval) {
        if current != url {
            stop()
            let item = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: item)
            current = url
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                self?.isPlaying = false
                self?.player?.seek(to: .zero)
            }
        }
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        player?.play()
        isPlaying = true
    }

    func stop() {
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        current = nil
        isPlaying = false
    }
}
