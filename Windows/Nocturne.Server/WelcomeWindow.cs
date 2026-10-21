using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
namespace Nocturne.Server;

internal sealed class WelcomeWindow : Window
{
    private readonly MainWindow main;
    private readonly Action complete;
    private readonly StackPanel content = new() { Margin = new(40) };
    private int step;
    public WelcomeWindow(MainWindow main, Action complete)
    {
        this.main = main; this.complete = complete; Owner = main; Title = "Welcome to Nocturne"; Width = 680; Height = 580;
        MinWidth = 600; MinHeight = 500; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Content = content; Draw();
    }
    private void Draw()
    {
        content.Children.Clear();
        content.Children.Add(new TextBlock { Text = "☾  NOCTURNE     " + (step + 1) + " / 3", FontSize = 15, Margin = new(0, 0, 0, 32) });
        var titles = new[] { "Your PC.\nOn every screen.", "Share what\nyou need.", "Ready when\nyou are." };
        var descriptions = new[] {
            "Bring your desktop and its sound to iPhone, iPad, Mac, or another PC. Connect to other Nocturne hosts from Computers.",
            "Screen sharing is ready in your signed-in Windows session. Enable PowerShell, files, and microphone forwarding separately in Sharing. You choose which devices to trust.",
            "On iPhone or iPad choose Add host → Scan QR code. On Mac or Windows choose Computers → Add host and paste a pairing code. Your host keeps working in the system tray."
        };
        content.Children.Add(new TextBlock { Text = titles[step], FontFamily = new FontFamily("Bahnschrift"), FontSize = 40, Margin = new(0, 0, 0, 22) });
        var detail = new TextBlock { Text = descriptions[step], FontSize = 16, LineHeight = 26, Margin = new(0, 0, 0, 22) }; detail.SetResourceReference(TextBlock.ForegroundProperty, "Muted"); content.Children.Add(detail);
        if (step == 1)
        {
            var setup = new Button { Content = "Review Windows setup", HorizontalAlignment = HorizontalAlignment.Left, Margin = new(0, 0, 0, 20) };
            setup.Click += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://github.com/iteufel/nocturne/blob/main/docs/WINDOWS.md") { UseShellExecute = true }); content.Children.Add(setup);
        }
        var buttons = new WrapPanel { Margin = new(0, 16, 0, 0) };
        if (step > 0) { var back = new Button { Content = "Back", Margin = new(0, 0, 12, 0) }; back.Click += (_, _) => { step--; Draw(); }; buttons.Children.Add(back); }
        var next = new Button { Content = step == 2 ? "Pair a device" : "Continue", IsDefault = true, Margin = new(0, 0, 12, 0) };
        next.Click += (_, _) => { if (step < 2) { step++; Draw(); } else { complete(); Close(); main.ShowPairing(); } }; buttons.Children.Add(next);
        var skip = new Button { Content = "Finish later" }; skip.Click += (_, _) => { complete(); Close(); }; buttons.Children.Add(skip); content.Children.Add(buttons);
        content.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(220)));
    }
}
