import SwiftUI
import CoreAudio

private let micTint = Color.teal
private let systemTint = Color.orange

struct ContentView: View {
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Judul rapat, mis. Rapat Mingguan Tim Produk", text: $recorder.title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .disabled(recorder.isBusy)

            HStack(alignment: .top, spacing: 12) {
                SourceCard(title: "Audio eksternal",
                           subtitle: "Mikrofon / suara di ruangan",
                           icon: "mic.fill",
                           tint: micTint,
                           enabled: $recorder.micEnabled,
                           level: recorder.micLevel,
                           volume: $recorder.micVolume,
                           locked: recorder.isBusy) {
                    HStack {
                        Picker("Mikrofon", selection: $recorder.micDeviceID) {
                            Text("Mikrofon default sistem").tag(AudioDeviceID?.none)
                            ForEach(recorder.micDevices) { device in
                                Text(device.name).tag(AudioDeviceID?.some(device.id))
                            }
                        }
                        .labelsHidden()
                        RefreshButton()
                    }
                }

                SourceCard(title: "Audio internal",
                           subtitle: "Suara Zoom, Teams, Meet, dll.",
                           icon: "speaker.wave.2.fill",
                           tint: systemTint,
                           enabled: $recorder.systemEnabled,
                           level: recorder.systemLevel,
                           volume: $recorder.systemVolume,
                           locked: recorder.isBusy) {
                    HStack {
                        Picker("Sumber", selection: $recorder.appChoice) {
                            Text("Semua suara sistem").tag("")
                            ForEach(recorder.apps) { app in
                                Text("Hanya \(app.name)").tag(app.id)
                            }
                        }
                        .labelsHidden()
                        RefreshButton()
                    }
                }
            }

            Toggle("Simpan juga track mikrofon dan audio sistem secara terpisah", isOn: $recorder.keepTracks)
                .disabled(recorder.isBusy)
                .font(.callout)

            if let notice = recorder.notice {
                NoticeBar(notice: notice) { recorder.notice = nil }
            }

            ControlBar()

            Divider()

            RecordingsList()
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 640)
        .onAppear { recorder.refreshSources() }
    }
}

private struct RefreshButton: View {
    @EnvironmentObject var recorder: Recorder
    var body: some View {
        Button { recorder.refreshSources() } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("Muat ulang daftar perangkat dan aplikasi")
    }
}

struct SourceCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    @Binding var enabled: Bool
    let level: Float
    @Binding var volume: Double
    let locked: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(title, isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(locked)
            }
            content.disabled(locked || !enabled)
            LevelMeter(level: enabled ? level : 0, tint: tint)
            HStack {
                Text("Volume").foregroundStyle(.secondary)
                Slider(value: $volume, in: 0...1)
                Text("\(Int(volume * 100))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.callout)
            .disabled(!enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { tint.frame(height: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
        .opacity(enabled ? 1 : 0.6)
    }
}

struct LevelMeter: View {
    let level: Float
    let tint: Color

    private var normalized: Double {
        let db = 20 * log10(Double(max(level, 0.000_01)))
        return min(1, max(0, (db + 60) / 60))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(tint).frame(width: geo.size.width * normalized)
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.1), value: normalized)
        .accessibilityLabel("Level suara")
    }
}

struct NoticeBar: View {
    let notice: Notice
    let dismiss: () -> Void

    private var isError: Bool {
        if case .info = notice { return false }
        return true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.green)
            Text(notice.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer()
            if case .permission(_, let pane) = notice {
                Button("Buka Pengaturan") { Permissions.openSettings(pane) }
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Tutup pesan")
        }
        .padding(10)
        .background((isError ? Color.red : Color.green).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ControlBar: View {
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    StatusLabel(state: recorder.state)
                    Text(formatTime(recorder.elapsed))
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                }
                Spacer()
                switch recorder.state {
                case .idle:
                    Button { Task { await recorder.start() } } label: {
                        Label("Mulai rekam", systemImage: "record.circle")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .keyboardShortcut("r")
                case .starting, .saving:
                    ProgressView().controlSize(.small)
                    Text(recorder.state == .saving ? "Menyimpan…" : "Menyiapkan…")
                        .foregroundStyle(.secondary)
                case .recording, .paused:
                    Button(recorder.state == .paused ? "Lanjutkan" : "Jeda") { recorder.togglePause() }
                        .controlSize(.large)
                        .keyboardShortcut("p")
                    Button { Task { await recorder.stop() } } label: {
                        Label("Selesai", systemImage: "stop.fill")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(".")
                }
            }

            if recorder.isRecording {
                HStack {
                    TextField("Catatan untuk tanda (opsional), mis. Keputusan anggaran", text: $recorder.markNote)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { recorder.addMark() }
                    Button { recorder.addMark() } label: { Label("Tandai", systemImage: "bookmark") }
                        .keyboardShortcut("b")
                }
            }

            if !recorder.marks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(recorder.marks.enumerated()), id: \.offset) { _, mark in
                            HStack(spacing: 6) {
                                Text(formatTime(mark.time)).monospacedDigit().fontWeight(.semibold)
                                Text(mark.label)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
        }
    }
}

struct StatusLabel: View {
    let state: Recorder.State
    @State private var blink = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .opacity(state == .recording && blink ? 0.25 : 1)
            Text(text)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(state == .idle ? Color.secondary : color)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) { blink = true }
        }
    }

    private var color: Color {
        switch state {
        case .recording: return .red
        case .paused: return .orange
        case .starting, .saving: return .blue
        case .idle: return .secondary
        }
    }

    private var text: String {
        switch state {
        case .idle: return "Siap"
        case .starting: return "Menyiapkan"
        case .recording: return "Merekam"
        case .paused: return "Dijeda"
        case .saving: return "Menyimpan"
        }
    }
}

struct RecordingsList: View {
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rekaman tersimpan").font(.headline)
                Text("\(library.items.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Buka folder") { library.openRoot() }
            }
            if library.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Belum ada rekaman. Tekan Mulai rekam (⌘R) untuk membuat yang pertama.")
                        .foregroundStyle(.secondary)
                    Text("Rekaman disimpan di Dokumen › Perekam Rapat.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(library.items) { item in
                    RecordingRow(item: item)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct RecordingRow: View {
    let item: Recording
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @State private var confirmDelete = false

    private var isPlaying: Bool { player.current == item.audioURL && player.isPlaying }

    private var meta: String {
        let date = item.info.date.formatted(date: .abbreviated, time: .shortened)
        return ([date, formatTime(item.info.duration)] + item.info.sources).joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { player.toggle(item.audioURL) } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .help(isPlaying ? "Jeda" : "Putar")

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.info.name).fontWeight(.semibold).lineLimit(1)
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Tampilkan") { library.reveal(item) }
                    .help("Tampilkan file di Finder")
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash")
                }
                .help("Hapus rekaman")
            }
            if !item.info.marks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(item.info.marks.enumerated()), id: \.offset) { _, mark in
                            Button("\(formatTime(mark.time))  \(mark.label)") {
                                player.play(item.audioURL, at: mark.time)
                            }
                            .controlSize(.small)
                            .help("Putar dari tanda ini")
                        }
                    }
                }
                .padding(.leading, 38)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Hapus \"\(item.info.name)\"?", isPresented: $confirmDelete) {
            Button("Pindahkan ke Tong Sampah", role: .destructive) {
                if player.current == item.audioURL { player.stop() }
                library.trash(item)
            }
        } message: {
            Text("Folder rekaman ini akan dipindahkan ke Tong Sampah.")
        }
    }
}
