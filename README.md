# Perekam Rapat untuk macOS

Aplikasi macOS native (Swift + SwiftUI) untuk merekam rapat:

- **Audio eksternal**: mikrofon, headset, atau perangkat input lain (AVAudioEngine)
- **Audio internal**: suara sistem atau hanya satu aplikasi seperti Zoom, Teams, Chrome (ScreenCaptureKit). **Tidak perlu BlackHole.**

Kedua sumber direkam sinkron lalu digabung jadi satu file `.m4a`.

## Fitur

- Pilih mikrofon dan sumber audio internal: semua suara sistem atau *hanya* aplikasi tertentu
- Indikator level suara dan pengatur volume untuk tiap sumber
- Jeda/lanjutkan, timer, dan **Tandai** momen penting dengan catatan (⌘B)
- Ikon di menu bar dengan timer, jadi Anda bisa merekam sambil jendela ditutup
- Daftar rekaman dengan pemutar; klik tanda untuk lompat ke momen itu
- Opsional: simpan track mikrofon dan sistem secara terpisah
- Aman saat keluar: rekaman yang sedang berjalan disimpan dulu

Rekaman disimpan di `~/Documents/Perekam Rapat/`, satu folder per rapat:

```
2026-10-16 14.05.33 - Rapat Mingguan/
├── Rapat Mingguan.m4a     ← hasil gabungan
├── Tanda.txt              ← daftar tanda waktu
├── info.json
└── Track/                 ← (opsional) mikrofon.m4a, sistem.m4a
```

## Syarat

- macOS 13 Ventura atau lebih baru
- Xcode atau Command Line Tools (`xcode-select --install`) untuk build

## Build & instal

```bash
cd PerekamRapat-mac
./build.sh                 # atau ./build.sh --universal untuk Apple Silicon + Intel
cp -R "build/Perekam Rapat.app" /Applications/
open "/Applications/Perekam Rapat.app"
```

Tidak punya Mac untuk build? Push folder ini ke GitHub. Workflow di `.github/workflows/build.yml` akan membuat `PerekamRapat.zip` di tab **Actions → Artifacts**. Karena aplikasi tidak dinotarisasi, pada pembukaan pertama klik kanan → **Buka**, atau jalankan `xattr -dr com.apple.quarantine "/Applications/Perekam Rapat.app"`.

## Izin yang diminta

| Izin | Untuk | Lokasi di Pengaturan Sistem |
|---|---|---|
| Mikrofon | Audio eksternal | Privasi & Keamanan › Mikrofon |
| Perekaman Layar & Audio Sistem | Audio internal | Privasi & Keamanan › Perekaman Layar & Audio Sistem |

Setelah mengizinkan Perekaman Layar, **tutup dan buka ulang** aplikasi. Aplikasi hanya memakai audionya; layar tidak disimpan.

Setiap kali di-build ulang, tanda tangan ad-hoc berubah. Akibatnya macOS bisa meminta izin Perekaman Layar lagi; hapus entri lama lalu izinkan ulang.

## Tips

- Pakai headset supaya suara peserta tidak terekam dua kali lewat mikrofon.
- Pilih "Hanya zoom.us" atau "Hanya Microsoft Teams" agar notifikasi dan musik dari aplikasi lain tidak ikut terekam.
- Untuk rapat di browser, pilih browser yang dipakai (mis. "Hanya Google Chrome").

## Struktur kode

| File | Isi |
|---|---|
| `PerekamRapatApp.swift` | Entry point, jendela, menu bar, penanganan keluar |
| `ContentView.swift` | Antarmuka SwiftUI |
| `Recorder.swift` | Alur rekam: izin, mulai, jeda, tanda, selesai |
| `MicCapture.swift` | Mikrofon via AVAudioEngine + daftar perangkat Core Audio |
| `SystemAudioCapture.swift` | Audio internal via ScreenCaptureKit |
| `TrackWriter.swift` | Tulis track ke AAC, sinkronisasi dengan jam bersama |
| `RecordingClock.swift` | Jam rekaman (menangani jeda) |
| `Library.swift` | Penyimpanan, penggabungan (Mixer), pemutar |

## Versi web

Folder [`web/`](web/) berisi versi browser (satu file HTML) untuk Windows/Linux/Chrome. Lihat `web/README.md`.
