import AppKit
import StratagemCore

/// Explicit custom images and installed packs take precedence over bundled artwork.
@MainActor final class GameArtwork {
    static let shared = GameArtwork()
    private struct Index: Decodable {
        var icons: [String: String]
        var defaultIcons: [String: String]
        var accentColors: [String: String]?
        var displayNames: [String: String]?
        var catalogNames: [String: String]?
    }
    private var packs: [(directory: URL, index: Index)] = []
    private var cache: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private init() {
        var directories = [ConfigurationStore.defaultURL.deletingLastPathComponent().appendingPathComponent("Artwork")]
        #if DEBUG
        if CommandLine.arguments.contains("--bundled-artwork-only") { directories = [] }
        #endif
        if let bundled = BundledArtwork.directory { directories.append(bundled) }
        for directory in directories {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
               let index = try? JSONDecoder().decode(Index.self, from: data) {
                packs.append((directory, index))
            }
        }
    }
    func image(for entry: Stratagem) -> NSImage? {
        if entry.icon.hasPrefix("/") { return load(entry.icon) }
        for pack in packs {
            guard pack.index.defaultIcons[entry.id] == entry.icon,
                  let filename = pack.index.icons[entry.id],
                  filename == URL(fileURLWithPath: filename).lastPathComponent else { continue }
            if let image = load(pack.directory.appendingPathComponent(filename).path) { return image }
        }
        return nil
    }
    func displayName(for entry: Stratagem) -> String {
        for pack in packs where pack.index.catalogNames?[entry.id] == entry.name {
            if let name = pack.index.displayNames?[entry.id] { return name }
        }
        return entry.name
    }
    func accent(for entry: Stratagem) -> NSColor? {
        for pack in packs {
            guard pack.index.defaultIcons[entry.id] == entry.icon,
                  let hex = pack.index.accentColors?[entry.id], hex.count == 6,
                  let rgb = UInt32(hex, radix: 16) else { continue }
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        return nil
    }
    private func load(_ path: String) -> NSImage? {
        if let image = cache[path] { return image }
        if missing.contains(path) { return nil }
        guard let image = NSImage(contentsOfFile: path) else { missing.insert(path); return nil }
        cache[path] = image
        return image
    }
}
