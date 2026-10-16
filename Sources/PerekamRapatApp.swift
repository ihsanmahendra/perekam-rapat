import SwiftUI
import AppKit

@main
struct PerekamRapatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = Recorder.shared
    @StateObject private var library = Library.shared
    @StateObject private var player = Player()

    var body: some Scene {
        Window("Perekam Rapat", id: "main") {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(library)
                .environmentObject(player)
        }
        .defaultSize(width: 780, height: 780)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(recorder)
        } label: {
            if recorder.isRecording {
                Image(systemName: recorder.state == .paused ? "pause.circle.fill" : "record.circle.fill")
                Text(formatTime(recorder.elapsed))
            } else {
                Image(systemName: "waveform")
            }
        }
    }
}

/// Jangan biarkan rekaman hilang saat aplikasi ditutup: simpan dulu, baru keluar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorder = Recorder.shared
        guard recorder.isRecording else { return .terminateNow }
        Task { @MainActor in
            await recorder.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var recorder: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch recorder.state {
        case .idle:
            Text("Siap merekam")
            Button("Mulai rekam") { Task { await recorder.start() } }
        case .starting:
            Text("Menyiapkan…")
        case .recording, .paused:
            Text(recorder.state == .paused ? "Dijeda · \(formatTime(recorder.elapsed))" : "Merekam · \(formatTime(recorder.elapsed))")
            Button(recorder.state == .paused ? "Lanjutkan" : "Jeda") { recorder.togglePause() }
            Button("Tandai momen") { recorder.addMark() }
            Button("Selesai & simpan") { Task { await recorder.stop() } }
        case .saving:
            Text("Menyimpan rekaman…")
        }
        Divider()
        Button("Buka jendela Perekam Rapat") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Keluar") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}
