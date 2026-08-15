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
