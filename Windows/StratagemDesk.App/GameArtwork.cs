using System.Security.Cryptography;
using System.Text.Json;
using System.Windows.Media.Imaging;
using System.Xml;
using System.Text.RegularExpressions;
using SharpVectors.Converters;
using SharpVectors.Dom;
using SharpVectors.Renderers.Wpf;

namespace StratagemDesk.App;

public sealed class GameArtwork
{
    private sealed record Index(Dictionary<string, string> Icons, Dictionary<string, string> DefaultIcons,
        Dictionary<string, string> AccentColors, Dictionary<string, string> DisplayNames, Dictionary<string, string> CatalogNames);
    private readonly List<(string Folder, Index Index)> packs = [];
    private readonly Dictionary<string, ImageSource?> images = [];
    private readonly ImageSource fallback = new DrawingImage(new GeometryDrawing(null, new Pen(Brushes.Goldenrod, 2), Geometry.Parse("M4,16 H28 M16,4 V28 M8,8 H24 V24 H8 Z")));
    public GameArtwork()
    {
        foreach (var folder in new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StratagemDesk-Public", "Artwork"), Path.Combine(AppContext.BaseDirectory, "Artwork") })
        {
            try
            {
                if (JsonSerializer.Deserialize<Index>(ReadLocalBytes(Path.Combine(folder, "index.json"), 1_000_000) ?? [], Json.Options) is { } index &&
                    index.Icons != null && index.DefaultIcons != null && index.AccentColors != null && index.DisplayNames != null && index.CatalogNames != null)
                    packs.Add((folder, index));
            }
            catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { }
        }
    }
    public ImageSource? Image(Stratagem e, bool useFallback = true)
    {
        if (string.IsNullOrWhiteSpace(e.Icon)) return useFallback ? fallback : null;
        if (Path.IsPathFullyQualified(e.Icon)) return Load(e.Icon) ?? (useFallback ? fallback : null);
        foreach (var pack in packs)
            if (pack.Index.DefaultIcons.GetValueOrDefault(e.Id) == e.Icon && pack.Index.Icons.GetValueOrDefault(e.Id) is { } file && Path.GetFileName(file) == file)
                if (Load(Path.Combine(pack.Folder, file)) is { } image) return image;
        return useFallback ? fallback : null;
    }
    public string Name(Stratagem e)
    {
        foreach (var pack in packs) if (pack.Index.CatalogNames.GetValueOrDefault(e.Id) == e.Name) return pack.Index.DisplayNames.GetValueOrDefault(e.Id) ?? e.Name;
        return e.Name;
    }
    public Brush Accent(Stratagem e)
    {
        foreach (var p in packs)
            if (p.Index.DefaultIcons.GetValueOrDefault(e.Id) == e.Icon && p.Index.AccentColors.GetValueOrDefault(e.Id) is { } hex)
                try { return new SolidColorBrush((Color)ColorConverter.ConvertFromString("#" + hex)); } catch (FormatException) { }
        return Brushes.Goldenrod;
    }
    // Check drive syntax before any filesystem access: a fully qualified path may be UNC.
    private static byte[]? ReadLocalBytes(string path, int limit)
    {
        if (path.Length < 3 || !char.IsAsciiLetter(path[0]) || path[1] != ':' ||
            (path[2] != '\\' && path[2] != '/') || path.AsSpan(2).Contains(':')) return null;
        var fullPath = Path.GetFullPath(path);
        if (new DriveInfo(fullPath[..3]).DriveType is not (DriveType.Fixed or DriveType.Removable or DriveType.CDRom or DriveType.Ram)) return null;
        var current = fullPath[..3];
        // Do not follow junctions, symlinks, mounted folders or cloud placeholders.
        foreach (var part in fullPath[3..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) return null;
        }
        using var stream = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length == 0 || stream.Length > limit) return null;
        var bytes = new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes); return bytes;
    }
    private static XmlReader SvgReader(byte[] bytes) => XmlReader.Create(new MemoryStream(bytes, writable: false),
        new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null,
            MaxCharactersInDocument = 500_000, CloseInput = true });
    private ImageSource? Load(string path)
    {
        if (images.TryGetValue(path, out var cached)) return cached;
        ImageSource? image = null;
        try
        {
            var extension = Path.GetExtension(path).ToLowerInvariant();
            if (extension is not (".svg" or ".png" or ".jpg" or ".jpeg" or ".bmp")) return null;
            var bytes = ReadLocalBytes(path, extension == ".svg" ? 500_000 : 10_000_000);
            if (bytes == null) return null;
            if (extension == ".svg")
            {
                using (var reader = SvgReader(bytes))
                    while (reader.Read())
                    {
                        if (reader.NodeType == XmlNodeType.ProcessingInstruction) throw new InvalidDataException("SVG 不允许处理指令");
                        if (reader.NodeType != XmlNodeType.Element) continue;
                        if (reader.LocalName is "script" or "foreignObject" or "image" or "style") throw new InvalidDataException("不支持此 SVG 内容");
                        while (reader.MoveToNextAttribute())
                            if (reader.LocalName.StartsWith("on", StringComparison.OrdinalIgnoreCase) ||
                                (reader.LocalName == "base" && reader.NamespaceURI == "http://www.w3.org/XML/1998/namespace") ||
                                (reader.LocalName == "href" && !reader.Value.StartsWith('#')) ||
                                (reader.Value.Contains("url(", StringComparison.OrdinalIgnoreCase) && !Regex.IsMatch(reader.Value, @"^url\(\s*#[A-Za-z0-9_-]+\s*\)$")))
                                throw new InvalidDataException("SVG 含外部引用");
                        reader.MoveToElement();
                    }
                // Render the same bounded bytes, never reopen the path or use the library's default resolver.
                using var source = SvgReader(bytes);
                var drawing = new FileSvgReader(new WpfDrawingSettings { IncludeRuntime = false, TextAsGeometry = true,
                    ExternalResourcesAccessMode = ExternalResourcesAccessModes.Ignore }).Read(source);
                if (drawing != null) image = new DrawingImage(drawing);
            }
            else
            {
                using var source = new MemoryStream(bytes, writable: false);
                var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.DecodePixelWidth = 256; bitmap.DecodePixelHeight = 256;
                bitmap.StreamSource = source; bitmap.EndInit(); image = bitmap;
            }
            image?.Freeze();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { image = null; }
        images[path] = image; return image;
    }
    public Dictionary<string, object> Validate(IReadOnlyList<Stratagem> entries)
    {
        var folder = Path.Combine(AppContext.BaseDirectory, "Artwork");
        using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(folder, "sources.json")));
        var checkedFiles = 0;
        foreach (var item in doc.RootElement.GetProperty("entries").EnumerateArray())
        {
            var file = item.GetProperty("file").GetString()!;
            if (Path.GetFileName(file) != file) throw new InvalidDataException("图标路径无效");
            if (Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(Path.Combine(folder, file)))) != item.GetProperty("sha256").GetString()) throw new InvalidDataException("图标校验失败");
            checkedFiles++;
        }
        var missing = entries.Where(e => Image(e, false) == null).Select(e => e.Id).ToArray();
        return new() { ["hashVerified"] = checkedFiles, ["loaded"] = entries.Count - missing.Length, ["missing"] = missing };
    }
}
