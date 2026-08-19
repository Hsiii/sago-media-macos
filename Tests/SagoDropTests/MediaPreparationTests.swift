import AppKit
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SagoDrop

@Test func rejectsOversizedNonVideoBeforeUpload() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-oversized-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }

    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(MediaPreparation.maximumUploadBytes + 1))
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
@Test func preparesMp4AsANewLocalUpload() async throws {
    let source = FileManager.default.temporaryDirectory
        .appending(path: "sago-drop-source-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: source) }
    try await createTestVideo(at: source)

    let prepared = try await MediaPreparation.prepare(source)
    defer { prepared.cleanUp() }

    #expect(prepared.isTemporary)
    #expect(prepared.url != source)
    #expect(prepared.url.pathExtension == "mp4")
    #expect(FileManager.default.fileExists(atPath: prepared.url.path))
    #expect((try prepared.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= MediaPreparation.maximumUploadBytes)

    let asset = AVURLAsset(url: prepared.url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
    let metadata = try await asset.load(.commonMetadata)
    #expect(AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).isEmpty)
}

@MainActor
@Test func acceptsLocallyPreparedVideoFormats() {
    let model = UploadModel()

    #expect(model.accepts([URL(fileURLWithPath: "/tmp/recording.mov")]))
    #expect(model.accepts([URL(fileURLWithPath: "/tmp/recording.mp4")]))
    #expect(model.accepts([URL(fileURLWithPath: "/tmp/image.png")]))
    #expect(!model.accepts([URL(fileURLWithPath: "/tmp/recording.webm")]))
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

@MainActor
private func createTestVideo(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let title = AVMutableMetadataItem()
    title.identifier = .commonIdentifierTitle
    title.value = "Private title" as NSString
    writer.metadata = [title]
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640,
            AVVideoHeightKey: 480,
        ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input)
    guard writer.canAdd(input) else { throw MediaError.message("Could not create test video") }
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess,
          let pixelBuffer else {
        throw MediaError.message("Could not create test video frame")
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
    }
    guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        throw writer.error ?? MediaError.message("Could not write test video frame")
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    input.markAsFinished()
    await writer.finishWriting()
    if let error = writer.error { throw error }
}
