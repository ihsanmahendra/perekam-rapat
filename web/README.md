# Perekam Rapat

Aplikasi web satu file untuk merekam rapat: **audio eksternal** (mikrofon) dan **audio internal** (suara sistem / tab Zoom, Meet, Teams) digabung jadi satu rekaman.

## Menjalankan

Mikrofon hanya bisa diakses dari `localhost` atau `https`, jadi jalankan server lokal:

```bash
cd meeting-recorder
python3 -m http.server 8000
# buka http://localhost:8000 di Chrome atau Edge
```

## Fitur

- Rekam mikrofon + audio sistem sekaligus, masing-masing bisa dinyalakan/dimatikan dan diatur volumenya
- Indikator level suara untuk tiap sumber
- Jeda / lanjutkan, timer, dan **Tandai** momen penting (tombol atau tekan `M`)
- Rekaman disimpan otomatis di browser (IndexedDB), bisa diputar, diganti nama, dihapus
- Unduh sebagai WEBM (Opus) atau WAV

## Audio internal per sistem operasi

| OS | Cara |
|---|---|
| Windows (Chrome/Edge) | Klik "Pilih sumber audio sistem" → **Seluruh Layar** → centang **Bagikan audio sistem** |
| Rapat di browser (Meet, Zoom web) | Pilih tab rapat → centang **Bagikan audio tab** |
| macOS | Browser hanya bisa audio tab. Untuk aplikasi desktop, pasang [BlackHole](https://github.com/ExistentialAudio/BlackHole) dan pilih sebagai input |
| Linux | Pilih tab, atau pilih perangkat "Monitor of …" di daftar mikrofon |

Pakai headset agar suara peserta tidak terekam dua kali.
