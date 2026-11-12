# Perekam Rapat untuk Windows

Port native (C# / WPF / .NET 8) dari versi macOS. Antarmuka, folder rekaman, `info.json` dan `Tanda.txt` sama.

- **Audio eksternal**: mikrofon apa pun (WASAPI)
- **Audio internal**: suara sistem dari perangkat output yang dipilih (WASAPI loopback). Tidak perlu driver tambahan
- Hasil digabung jadi satu `.m4a` (AAC) di `Dokumen\Perekam Rapat\`

## Beda dengan versi macOS

- Tidak ada pilihan "hanya aplikasi X": yang direkam seluruh suara dari perangkat output terpilih. Pakai headset agar suara peserta tidak terekam dua kali lewat mikrofon.
- Track mentah disimpan sebagai `.wav` (bukan `.m4a`) bila opsi simpan track diaktifkan.
- Tidak ada ikon menu bar.

## Syarat

- Windows 10/11. Edisi "N" butuh Media Feature Pack (untuk encoder AAC)
- Build: .NET 8 SDK

## Build

```powershell
cd windows
.\build.ps1        # hasil: windows\publish\PerekamRapat.exe
```

Atau push ke GitHub: workflow `build-windows.yml` menghasilkan artifact `PerekamRapat-Windows` di tab Actions.
Aplikasi tidak ditandatangani, jadi SmartScreen mungkin menampilkan peringatan: **Info lebih lanjut › Tetap jalankan**.

Izin mikrofon: Pengaturan › Privasi & keamanan › Mikrofon › izinkan aplikasi desktop.
