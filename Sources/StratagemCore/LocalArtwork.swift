import Foundation
import AppKit
import ImageIO
import Darwin

/// Artwork is data, not permission to follow a network path or resolve external resources.
public enum LocalArtwork {
    public static func read(_ path: String, maximumBytes: Int) -> Data? {
        guard (1...10_000_000).contains(maximumBytes), path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("\0"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let mounts = mountedFileSystems(), isLocalPath(path, mounts: mounts) else { return nil }
        // O_NOFOLLOW_ANY rejects links in every component, not only the final filename.
        // Nonblocking open lets us reject a named pipe without waiting for a writer.
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var file = stat(), volume = statfs()
        guard fstat(descriptor, &file) == 0, file.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              file.st_flags & UInt32(SF_DATALESS) == 0, file.st_size > 0, file.st_size <= Int64(maximumBytes),
              fstatfs(descriptor, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else { return nil }
        // Decode these exact bytes later; never reopen the pathname after validation.
        var data = Data(count: Int(file.st_size))
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        return complete ? data : nil
    }
    public static func image(_ path: String) -> NSImage? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ["svg", "png", "jpg", "jpeg", "bmp"].contains(ext),
              let data = read(path, maximumBytes: ext == "svg" ? 500_000 : 10_000_000) else { return nil }
        if ext == "svg" {
            guard SVGArtworkCheck.accepts(data), let image = NSImage(data: data),
                  image.size.width.isFinite, image.size.height.isFinite,
                  image.size.width > 0, image.size.height > 0,
                  image.size.width <= 16_384, image.size.height <= 16_384 else { return nil }
            return image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 16_777_216,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
    // Inspect the cached mount table before opening a path on a known network volume.
    // fstatfs on the opened descriptor additionally verifies the actual filesystem.
    private static func mountedFileSystems() -> [(path: String, local: Bool)]? {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let mounts = buffer else { return nil }
        defer { free(mounts) }
        return (0..<Int(count)).map { index in
            let path = withUnsafeBytes(of: mounts[index].f_mntonname) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return (path, mounts[index].f_flags & UInt32(MNT_LOCAL) != 0)
        }
    }
    static func isLocalPath(_ path: String, mounts: [(path: String, local: Bool)]) -> Bool {
        let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
        let containing = mounts.filter {
            let mount = $0.path.precomposedStringWithCanonicalMapping.lowercased()
            return mount == "/" || normalized == mount || normalized.hasPrefix(mount + "/")
        }
        return !containing.isEmpty && containing.allSatisfy(\.local)
    }
}

private final class SVGArtworkCheck: NSObject, XMLParserDelegate {
    private var safe = true
    private var sawRoot = false
    static func accepts(_ data: Data) -> Bool {
        // Reject unsupported encodings and DTDs before invoking either XML or image parsers.
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              text.range(of: "<!DOCTYPE|<!ENTITY", options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        let check = SVGArtworkCheck(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
        parser.delegate = check
        return parser.parse() && check.safe && check.sawRoot
    }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        safe = false; parser.abortParsing()
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if !sawRoot {
            sawRoot = true
            if elementName != "svg" || namespaceURI != "http://www.w3.org/2000/svg" { safe = false }
        }
        if ["script", "foreignobject", "image", "style"].contains(elementName.lowercased()) { safe = false }
        for (key, value) in attributes {
            let name = key.split(separator: ":").last.map(String.init)?.lowercased() ?? key.lowercased()
            if name.hasPrefix("on") || name == "base" || (name == "href" && !value.hasPrefix("#")) { safe = false }
            if value.range(of: "url(", options: .caseInsensitive) != nil &&
                value.range(of: #"^url\(\s*#[A-Za-z0-9_-]+\s*\)$"#, options: .regularExpression) == nil { safe = false }
        }
        if !safe { parser.abortParsing() }
    }
}
