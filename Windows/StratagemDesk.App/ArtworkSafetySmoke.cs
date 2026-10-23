using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Media.Imaging;

namespace StratagemDesk.App;

internal static class ArtworkSafetySmoke
{
    public static async Task<Dictionary<string, bool>> RunAsync(GameArtwork artwork, string directory)
    {
        var checks = new Dictionary<string, bool>();
        var root = Path.Combine(directory, "artwork-safety"); Directory.CreateDirectory(root);
        ImageSource? Load(string path) => artwork.Image(new Stratagem { Icon = path }, useFallback: false);
        checks["nullAndEmptyArtworkUseFallback"] = artwork.Image(new Stratagem { Icon = null! }, false) == null &&
            artwork.Image(new Stratagem { Icon = "" }, false) == null && artwork.Image(new Stratagem { Icon = null! }) != null;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        checks["uncAndDeviceArtworkBlocked"] = new[] { @"\\127.0.0.1\StratagemDeskNoShare\icon.png", @"\\127.0.0.1\StratagemDeskNoShare\icon.svg",
            @"\\?\UNC\127.0.0.1\StratagemDeskNoShare\icon.png", @"\\.\pipe\StratagemDeskNoPipe.svg", @"//127.0.0.1/StratagemDeskNoShare/icon.png" }.All(p => Load(p) == null);
        checks["remoteArtworkRejectedPromptly"] = clock.Elapsed < TimeSpan.FromSeconds(1);

        var localSvg = Path.Combine(root, "local.svg");
        File.WriteAllText(localSvg, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><defs><linearGradient id=\"g\"><stop stop-color=\"red\"/><stop offset=\"1\" stop-color=\"blue\"/></linearGradient></defs><rect width=\"32\" height=\"32\" fill=\"url(#g)\"/></svg>");
        checks["localSvgWithInternalReferenceLoads"] = Load(localSvg) != null;
        var localPng = Path.Combine(root, "local.png");
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(BitmapSource.Create(1, 1, 96, 96, PixelFormats.Bgra32, null, new byte[] { 0, 0, 255, 255 }, 4)));
        using (var file = File.Create(localPng)) encoder.Save(file);
        checks["localPngLoadsFromBoundedBytes"] = Load(localPng) != null;

        var requests = 0;
        using var stop = new CancellationTokenSource();
        var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var server = Task.Run(async () =>
        {
            try
            {
                while (!stop.IsCancellationRequested)
                {
                    using var client = await listener.AcceptTcpClientAsync(stop.Token);
                    Interlocked.Increment(ref requests);
                    var response = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 15\r\nContent-Type: text/css\r\nConnection: close\r\n\r\nrect{fill:red;}");
                    await client.GetStream().WriteAsync(response, stop.Token);
                }
            }
            catch (Exception ex) when (ex is OperationCanceledException or SocketException or ObjectDisposedException or IOException) { }
        });
        try
        {
            var url = $"http://127.0.0.1:{port}/probe.css";
            var pi = Path.Combine(root, "stylesheet.svg");
            File.WriteAllText(pi, $"<?xml-stylesheet type=\"text/css\" href=\"{url}\"?><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\"/></svg>");
            checks["svgStylesheetInstructionRejected"] = Load(pi) == null;
            var external = Path.Combine(root, "external.svg");
            File.WriteAllText(external, $"<svg xmlns=\"http://www.w3.org/2000/svg\"><use href=\"{url}#shape\"/></svg>");
            checks["svgExternalReferenceRejected"] = Load(external) == null;
            var dtd = Path.Combine(root, "dtd.svg");
            File.WriteAllText(dtd, $"<!DOCTYPE svg SYSTEM \"{url}\"><svg xmlns=\"http://www.w3.org/2000/svg\"/>");
            checks["svgDtdRejected"] = Load(dtd) == null;
            await Task.Delay(200);
            checks["artworkMadeNoHttpRequests"] = Volatile.Read(ref requests) == 0;
        }
        finally { stop.Cancel(); listener.Stop(); await server; }

        var link = Path.Combine(root, "linked.svg"); File.CreateSymbolicLink(link, localSvg);
        checks["symlinkArtworkRejected"] = Load(link) == null;
        var big = Path.Combine(root, "oversized.svg"); File.WriteAllText(big, new string(' ', 500_001));
        checks["oversizedSvgRejected"] = Load(big) == null;

        var configPath = Path.Combine(root, "model", "configuration.json");
        var model = new AppModel(configPath); model.Add(); model.SaveAll();
        var before = File.ReadAllBytes(configPath); var invalidPath = Path.Combine(root, "invalid-import.json");
        var rejects = true;
        foreach (var field in new[] { "icon", "category", "description" })
        {
            var document = JsonNode.Parse(before)!; document["custom"]![0]![field] = null; File.WriteAllText(invalidPath, document.ToJsonString());
            try { model.Import(invalidPath); rejects = false; } catch (InvalidDataException) { }
            rejects &= before.SequenceEqual(File.ReadAllBytes(configPath));
        }
        checks["invalidMetadataImportPreservesSavedFile"] = rejects;
        var documentWithNull = JsonNode.Parse(before)!; documentWithNull["custom"]![0]!["icon"] = null;
        File.WriteAllText(configPath, documentWithNull.ToJsonString());
        var recovery = new AppModel(configPath);
        checks["invalidMetadataStartupAllowsRecovery"] = recovery.LoadFailed && recovery.Entries.All(e => e.Icon != null && e.Category != null && e.Description != null);
        var manager = new MainWindow(recovery, artwork) { AllowClose = true }; manager.Show();
        recovery.ResetDefaults(); checks["invalidMetadataCanResetAndRestart"] = !new AppModel(configPath).LoadFailed; manager.Close();
        return checks;
    }
}
