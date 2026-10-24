import XCTest
import AppKit
import Darwin
@testable import StratagemCore

final class ArtworkSafetyTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        // Keep failing cloud paths diagnosable without weakening the actual loader assertions.
        let probe = url.appendingPathComponent("probe.png")
        try Data([1]).write(to: probe)
        if LocalArtwork.read(probe.path, maximumBytes: 1) == nil {
            var volume = statfs()
            let volumeResult = statfs(probe.path, &volume)
            let descriptor = open(probe.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW_ANY)
            let openError = errno
            if descriptor >= 0 { close(descriptor) }
            print("Artwork fixture path=\(probe.path) resolved=\(probe.resolvingSymlinksInPath().path) statfs=\(volumeResult) flags=\(volume.f_flags) open=\(descriptor) errno=\(openError)")
        }
        return url
    }
    func testReadsOnlyBoundedRegularLocalBytes() throws {
        let root = try directory(), file = root.appendingPathComponent("image.png")
        try Data([1, 2, 3, 4]).write(to: file)
        XCTAssertEqual(LocalArtwork.read(file.path, maximumBytes: 4), Data([1, 2, 3, 4]))
        XCTAssertNil(LocalArtwork.read(file.path, maximumBytes: 3))
        try Data().write(to: file)
        XCTAssertNil(LocalArtwork.read(file.path, maximumBytes: 4))
        XCTAssertNil(LocalArtwork.read(root.path, maximumBytes: 100))
        XCTAssertNil(LocalArtwork.read("smb://example.invalid/icon.png", maximumBytes: 100))
        XCTAssertNil(LocalArtwork.read("//example.invalid/icon.png", maximumBytes: 100))
        XCTAssertNil(LocalArtwork.read(file.path + "\0ignored", maximumBytes: 100))
    }
    func testFileAndParentDirectorySymlinksAreRejected() throws {
        let root = try directory(), file = root.appendingPathComponent("image.png")
        try Data([1]).write(to: file)
        let link = root.appendingPathComponent("linked.png"), folderLink = root.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: root)
        XCTAssertNil(LocalArtwork.read(link.path, maximumBytes: 10))
        XCTAssertNil(LocalArtwork.read(folderLink.appendingPathComponent("image.png").path, maximumBytes: 10))
        XCTAssertEqual(LocalArtwork.read(file.path, maximumBytes: 10), Data([1]))
    }
    func testNamedPipeDoesNotBlockOrDecode() throws {
        let path = try directory().appendingPathComponent("pipe.png").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let start = Date()
        XCTAssertNil(LocalArtwork.image(path))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
    func testMountedNetworkPathsAreRejectedByPolicy() {
        let mounts = [(path: "/", local: true), (path: "/Volumes/Shared", local: false)]
        XCTAssertFalse(LocalArtwork.isLocalPath("/Volumes/Shared/icon.png", mounts: mounts))
        XCTAssertFalse(LocalArtwork.isLocalPath("/volumes/SHARED/icon.png", mounts: mounts))
        XCTAssertFalse(LocalArtwork.isLocalPath("/Volumes/Shared", mounts: mounts))
        XCTAssertTrue(LocalArtwork.isLocalPath("/Volumes/Shared-other/icon.png", mounts: mounts))
        XCTAssertTrue(LocalArtwork.isLocalPath("/private/tmp/local-icon.png", mounts: mounts))
        XCTAssertFalse(LocalArtwork.isLocalPath("/private/tmp/icon.png", mounts: []))
    }
    func testLocalPngAndSvgDecodeButUnsupportedAndOversizedFilesDoNot() throws {
        let root = try directory(), png = root.appendingPathComponent("local.png"), svg = root.appendingPathComponent("local.svg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: png)
        XCTAssertNotNil(LocalArtwork.image(png.path))
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><path fill=\"red\" d=\"M0 0H32V32H0Z\"/></svg>".utf8).write(to: svg)
        XCTAssertNotNil(LocalArtwork.image(svg.path))
        let unsupported = root.appendingPathComponent("image.pdf")
        try Data(contentsOf: png).write(to: unsupported)
        XCTAssertNil(LocalArtwork.image(unsupported.path))
        try Data(repeating: 32, count: 500_001).write(to: svg)
        XCTAssertNil(LocalArtwork.image(svg.path))
    }
    func testSvgActiveContentAndExternalReferencesAreRejected() throws {
        let root = try directory(), path = root.appendingPathComponent("unsafe.svg")
        let payloads = [
            "<?xml-stylesheet type=\"text/css\" href=\"https://example.invalid/style.css\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>",
            "<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/hosts'>]><svg xmlns=\"http://www.w3.org/2000/svg\">&x;</svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"https://example.invalid/image.png\"/></svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><use href=\"file:///etc/hosts\"/></svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" xml:base=\"https://example.invalid/\"/>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>path{fill:red}</style></svg>"
        ]
        for payload in payloads {
            try Data(payload.utf8).write(to: path)
            XCTAssertNil(LocalArtwork.image(path.path), payload)
        }
    }
    func testEveryBundledIconStillDecodesThroughSafeLoader() throws {
        let root = try XCTUnwrap(BundledArtwork.directory).resolvingSymlinksInPath()
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("sources.json"))) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 123)
        for entry in entries {
            let file = try XCTUnwrap(entry["file"] as? String)
            XCTAssertNotNil(LocalArtwork.image(root.appendingPathComponent(file).path), file)
        }
    }
    func testImportRetainsSafeSymbolsAndWorkflowReferences() throws {
        var custom = Stratagem(); custom.icon = "command.square"; custom.name = "Custom"
        var config = Configuration(); config.custom = [custom]
        let imported = try ConfigurationStore.quarantinedImport(JSONEncoder().encode(config), preserving: AppSettings())
        XCTAssertEqual(imported.custom[0].icon, "command.square")
    }
}
