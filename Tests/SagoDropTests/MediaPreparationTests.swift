import AppKit
import Foundation
import Testing
@testable import SagoDrop

@Test func rejectsOversizedSourceBeforeConversion() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-oversized-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }

    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(MediaPreparation.maximumSourceBytes + 1))
    try handle.close()

    await #expect(throws: MediaError.self) {
        try await MediaPreparation.prepare(url)
    }
}

@Test func keepsSupportedSmallFilesInPlace() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-small-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("image".utf8).write(to: url)

    let prepared = try await MediaPreparation.prepare(url)

    #expect(prepared.url == url)
    #expect(!prepared.isTemporary)
}

@MainActor
@Test func acceptsSupportedDroppedFilesIncludingMOV() {
    let model = UploadModel()

    #expect(model.accepts([URL(fileURLWithPath: "/tmp/recording.mov")]))
    #expect(model.accepts([URL(fileURLWithPath: "/tmp/image.png")]))
    #expect(!model.accepts([URL(fileURLWithPath: "/tmp/archive.zip")]))
}

@Test func usesLayeredGearsWhilePreparingVideo() {
    #expect(MenuBarState.converting.symbolName == "gearshape.2")
}

@MainActor
@Test func createsTextClipboardFileWithoutOverwriting() throws {
    let pasteboard = NSPasteboard(name: .init("SagoDropTests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("hello clipboard", forType: .string)
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-clipboard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try #require(try ClipboardFile.create(from: pasteboard, in: directory))
    let second = try #require(try ClipboardFile.create(from: pasteboard, in: directory))

    #expect(first.lastPathComponent == "Clipboard.txt")
    #expect(second.lastPathComponent == "Clipboard 2.txt")
    #expect(try String(contentsOf: first, encoding: .utf8) == "hello clipboard")
}

@MainActor
@Test func preservesPngClipboardData() throws {
    let pasteboard = NSPasteboard(name: .init("SagoDropTests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    let png = Data([0x89, 0x50, 0x4e, 0x47])
    pasteboard.setData(png, forType: .png)
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-clipboard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = try #require(try ClipboardFile.create(from: pasteboard, in: directory))

    #expect(file.pathExtension == "png")
    #expect(try Data(contentsOf: file) == png)
}

@MainActor
@Test func savesAppSpecificClipboardData() throws {
    let pasteboard = NSPasteboard(name: .init("SagoDropTests-\(UUID().uuidString)"))
    pasteboard.clearContents()
    let payload = Data("opaque object".utf8)
    pasteboard.setData(payload, forType: .init("dev.hsichen.sago-test-object"))
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-clipboard-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = try #require(try ClipboardFile.create(from: pasteboard, in: directory))

    #expect(file.pathExtension == "data")
    #expect(try Data(contentsOf: file) == payload)
}
