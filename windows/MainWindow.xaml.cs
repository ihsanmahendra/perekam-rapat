using System.IO;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using NAudio.CoreAudioApi;

namespace PerekamRapat;

public partial class MainWindow : Window
{
    private readonly Recorder _rec = new();
    private readonly Player _player = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private Notice? _shownNotice;
    private List<Mark>? _chipsList;
    private int _chipsCount = -1;
    private bool _closing;

    public MainWindow()
    {
        InitializeComponent();
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        LoadDevices();
        Library.Shared.Refresh();
        RebuildList();
        _player.Changed += RebuildList;
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
    }

    // ---------- Perangkat ----------

    private void LoadDevices()
    {
        try
        {
            Fill(MicCombo, "Mikrofon default sistem", AudioDevices.List(DataFlow.Capture));
            Fill(SystemCombo, "Semua suara sistem (output default)", AudioDevices.List(DataFlow.Render));
        }
        catch (Exception ex)
        {
            ShowNotice(new Notice(NoticeKind.Error, $"Daftar perangkat audio tidak bisa dibaca: {ex.Message}"));
        }
    }

    private static void Fill(ComboBox box, string first, List<AudioDevice> devices)
    {
        var previous = (box.SelectedItem as AudioDevice)?.Id ?? "";
        box.Items.Clear();
        box.Items.Add(new AudioDevice("", first));
        foreach (var d in devices) box.Items.Add(d);
        box.SelectedItem = box.Items.Cast<AudioDevice>().FirstOrDefault(d => d.Id == previous) ?? box.Items[0];
    }

    private void Refresh_Click(object sender, RoutedEventArgs e) => LoadDevices();

    private void Volume_Changed(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (MicVolText == null || SystemVolText == null) return;
        MicVolText.Text = $"{(int)Math.Round(MicVolume.Value * 100)}%";
        SystemVolText.Text = $"{(int)Math.Round(SystemVolume.Value * 100)}%";
    }

    // ---------- Kontrol rekam ----------

    private void Start_Click(object sender, RoutedEventArgs e) => StartRecording();
    private void Pause_Click(object sender, RoutedEventArgs e) => _rec.TogglePause();
    private async void Stop_Click(object sender, RoutedEventArgs e) => await _rec.StopAsync();
    private void Mark_Click(object sender, RoutedEventArgs e) => AddMark();

    private void StartRecording()
    {
        if (_rec.State != RecState.Idle) return;
        _rec.Title = TitleBox.Text;
        _rec.MicEnabled = MicEnabled.IsChecked == true;
        _rec.SystemEnabled = SystemEnabled.IsChecked == true;
        _rec.MicDeviceId = (MicCombo.SelectedItem as AudioDevice)?.Id ?? "";
        _rec.SystemDeviceId = (SystemCombo.SelectedItem as AudioDevice)?.Id ?? "";
        _rec.MicVolume = MicVolume.Value;
        _rec.SystemVolume = SystemVolume.Value;
        _rec.KeepTracks = KeepTracks.IsChecked == true;
        _player.Stop();
        _rec.Start();
    }

    private void AddMark()
    {
        _rec.AddMark(MarkNote.Text);
        MarkNote.Clear();
    }

    private void MarkNote_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { AddMark(); e.Handled = true; }
    }

    private async void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers != ModifierKeys.Control) return;
        switch (e.Key)
        {
            case Key.R: StartRecording(); e.Handled = true; break;
            case Key.P: _rec.TogglePause(); e.Handled = true; break;
            case Key.B: AddMark(); e.Handled = true; break;
            case Key.OemPeriod: e.Handled = true; await _rec.StopAsync(); break;
        }
    }

    private async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (_closing) return;
        if (_rec.State == RecState.Saving) { e.Cancel = true; return; }
        if (!_rec.IsRecording) { _player.Stop(); return; }
        // Simpan dulu rekaman yang sedang berjalan, baru tutup.
        e.Cancel = true;
        _closing = true;
        await _rec.StopAsync();
        Close();
    }

    // ---------- Pembaruan tampilan ----------

    private void Tick()
    {
        var state = _rec.State;
        var busy = _rec.IsBusy;

        TimerText.Text = Fmt.Time(state == RecState.Idle ? 0 : _rec.Elapsed.TotalSeconds);
        (StatusText.Text, StatusText.Foreground) = state switch
        {
            RecState.Recording => ("MEREKAM", Brushes.Red),
            RecState.Paused => ("DIJEDA", Brushes.DarkOrange),
            RecState.Starting => ("MENYIAPKAN", Brushes.RoyalBlue),
            RecState.Saving => ("MENYIMPAN…", Brushes.RoyalBlue),
            _ => ("SIAP", Brushes.Gray),
        };

        MicMeter.Value = MicEnabled.IsChecked == true ? Normalize(_rec.MicLevel) : 0;
        SystemMeter.Value = SystemEnabled.IsChecked == true ? Normalize(_rec.SystemLevel) : 0;

        StartBtn.Visibility = state == RecState.Idle ? Visibility.Visible : Visibility.Collapsed;
        PauseBtn.Visibility = _rec.IsRecording ? Visibility.Visible : Visibility.Collapsed;
        StopBtn.Visibility = _rec.IsRecording ? Visibility.Visible : Visibility.Collapsed;
        PauseBtn.Content = state == RecState.Paused ? "Lanjutkan (Ctrl+P)" : "Jeda (Ctrl+P)";
        MarkRow.Visibility = _rec.IsRecording ? Visibility.Visible : Visibility.Collapsed;

        foreach (var c in new Control[] { TitleBox, MicEnabled, SystemEnabled, MicCombo, SystemCombo,
                                          KeepTracks, RefreshMic, RefreshSystem })
            c.IsEnabled = !busy;

        if (!ReferenceEquals(_chipsList, _rec.Marks) || _chipsCount != _rec.Marks.Count) RebuildChips();

        var notice = _rec.Notice;
        if (!ReferenceEquals(notice, _shownNotice))
        {
            _shownNotice = notice;
            if (notice != null) ShowNotice(notice); else NoticeBar.Visibility = Visibility.Collapsed;
        }
        CountText.Text = Library.Shared.Items.Count.ToString();
    }

    private static double Normalize(float level)
    {
        var db = 20 * Math.Log10(Math.Max(level, 0.00001));
        return Math.Min(1, Math.Max(0, (db + 60) / 60));
    }

    private void ShowNotice(Notice n)
    {
        var isError = n.Kind != NoticeKind.Info;
        NoticeBar.Background = new SolidColorBrush(isError ? Color.FromArgb(0x22, 0xFF, 0x30, 0x30)
                                                           : Color.FromArgb(0x22, 0x30, 0xB0, 0x40));
        NoticeText.Text = (isError ? "⚠ " : "✔ ") + n.Text;
        NoticeSettings.Visibility = n.SettingsUri != null ? Visibility.Visible : Visibility.Collapsed;
        NoticeBar.Visibility = Visibility.Visible;
    }

    private void NoticeClose_Click(object sender, RoutedEventArgs e)
    {
        _rec.Notice = null;
        NoticeBar.Visibility = Visibility.Collapsed;
        _shownNotice = null;
    }

    private void NoticeSettings_Click(object sender, RoutedEventArgs e)
    {
        if (_rec.Notice?.SettingsUri is { } uri)
            Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
    }

    private void RebuildChips()
    {
        _chipsList = _rec.Marks;
        _chipsCount = _rec.Marks.Count;
        MarkChips.Children.Clear();
        foreach (var m in _rec.Marks.ToList())
        {
            MarkChips.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x20, 0x80, 0x80, 0x80)),
                CornerRadius = new CornerRadius(5), Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(0, 0, 6, 0),
                Child = new TextBlock { Text = $"{Fmt.Time(m.Time)}  {m.Label}", FontSize = 12 },
            });
        }
    }

    // ---------- Daftar rekaman ----------

    private void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(Library.Shared.Root);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Library.Shared.Root}\"") { UseShellExecute = true });
    }

    private void RebuildList()
    {
        RecordingsPanel.Children.Clear();
        if (Library.Shared.Items.Count == 0)
        {
            RecordingsPanel.Children.Add(new TextBlock
            {
                Text = "Belum ada rekaman. Tekan Mulai rekam (Ctrl+R) untuk membuat yang pertama.\nRekaman disimpan di Dokumen › Perekam Rapat.",
                Foreground = Brushes.Gray, Margin = new Thickness(0, 20, 0, 0), TextWrapping = TextWrapping.Wrap,
            });
            return;
        }

        foreach (var item in Library.Shared.Items)
        {
            var playing = _player.Current == item.AudioPath && _player.IsPlaying;
            var meta = string.Join(" · ", new[] { item.Info.Date.ToLocalTime().ToString("g"), Fmt.Time(item.Info.Duration) }
                                          .Concat(item.Info.Sources));

            var play = new Button { Content = playing ? "⏸" : "▶", Width = 34, Height = 34, FontSize = 16,
                                    ToolTip = playing ? "Jeda" : "Putar" };
            play.Click += (_, _) => TryPlay(item, 0);

            var reveal = new Button { Content = "Tampilkan", Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(0, 0, 6, 0),
                                      ToolTip = "Tampilkan file di Explorer" };
            reveal.Click += (_, _) => Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{item.AudioPath}\"") { UseShellExecute = true });

            var delete = new Button { Content = "🗑", Width = 30, ToolTip = "Hapus rekaman" };
            delete.Click += (_, _) =>
            {
                var ok = MessageBox.Show(this, $"Pindahkan \"{item.Info.Name}\" ke Recycle Bin?", "Hapus rekaman",
                                         MessageBoxButton.OKCancel, MessageBoxImage.Question);
                if (ok != MessageBoxResult.OK) return;
                if (_player.Current == item.AudioPath) _player.Stop();
                Library.Shared.Trash(item);
                RebuildList();
            };

            var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            buttons.Children.Add(reveal);
            buttons.Children.Add(delete);

            var text = new StackPanel { Margin = new Thickness(10, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = item.Info.Name, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
            text.Children.Add(new TextBlock { Text = meta, FontSize = 12, Foreground = Brushes.Gray, TextTrimming = TextTrimming.CharacterEllipsis });

            var row = new DockPanel();
            DockPanel.SetDock(play, Dock.Left);
            DockPanel.SetDock(buttons, Dock.Right);
            row.Children.Add(play);
            row.Children.Add(buttons);
            row.Children.Add(text);

            var card = new StackPanel { Margin = new Thickness(0, 0, 0, 4) };
            card.Children.Add(row);

            if (item.Info.Marks.Count > 0)
            {
                var chips = new WrapPanel { Margin = new Thickness(44, 4, 0, 0) };
                foreach (var m in item.Info.Marks)
                {
                    var chip = new Button
                    {
                        Content = $"{Fmt.Time(m.Time)}  {m.Label}", FontSize = 12,
                        Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(0, 0, 6, 4),
                        ToolTip = "Putar dari tanda ini",
                    };
                    var time = m.Time;
                    chip.Click += (_, _) => TryPlay(item, time);
                    chips.Children.Add(chip);
                }
                card.Children.Add(chips);
            }

            RecordingsPanel.Children.Add(new Border
            {
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0x80, 0x80, 0x80)),
                BorderThickness = new Thickness(0, 0, 0, 1), Padding = new Thickness(0, 6, 0, 6), Child = card,
            });
        }
    }

    private void TryPlay(Recording item, double at)
    {
        try
        {
            if (at == 0) _player.Toggle(item.AudioPath); else _player.Play(item.AudioPath, at);
        }
        catch (Exception ex)
        {
            _rec.Notice = new Notice(NoticeKind.Error, $"Rekaman tidak bisa diputar: {ex.Message}");
        }
    }
}
