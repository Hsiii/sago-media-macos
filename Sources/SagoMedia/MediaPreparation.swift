@preconcurrency import AVFoundation
import Foundation

struct PreparedMedia {
    let url: URL
    let isTemporary: Bool

    func cleanUp() {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

private final class SendableExporter: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
        self.value = value
    }
}

enum MediaPreparation {
    static let maximumSourceBytes: Int64 = 500_000_000
    static let maximumUploadBytes: Int64 = 90_000_000
    private static let compressionTargetBytes: Int64 = 80_000_000

    static func prepare(_ sourceURL: URL) async throws -> PreparedMedia {
        let sourceBytes = try fileSize(of: sourceURL)
        let isQuickTimeMovie = sourceURL.pathExtension.lowercased() == "mov"

        guard isQuickTimeMovie else {
            guard sourceBytes <= maximumUploadBytes else {
                throw MediaError.message("This file is over the 90 MB upload limit")
            }
            return PreparedMedia(url: sourceURL, isTemporary: false)
        }

        guard sourceBytes <= maximumSourceBytes else {
            throw MediaError.message("Choose a MOV file smaller than 500 MB")
        }

        let identifier = UUID().uuidString
        let remuxedURL = FileManager.default.temporaryDirectory
            .appending(path: "sago-media-\(identifier)-remuxed.mp4")

        do {
            try await export(sourceURL, to: remuxedURL, preset: AVAssetExportPresetPassthrough)
            if try fileSize(of: remuxedURL) <= maximumUploadBytes {
                return PreparedMedia(url: remuxedURL, isTemporary: true)
            }
        } catch {
            // Some QuickTime codecs cannot be placed in an MP4 without re-encoding.
        }

        try? FileManager.default.removeItem(at: remuxedURL)
        let compressedURL = FileManager.default.temporaryDirectory
            .appending(path: "sago-media-\(identifier)-compressed.mp4")
        do {
            try await export(
                sourceURL,
                to: compressedURL,
                preset: AVAssetExportPreset1920x1080,
                fileLengthLimit: compressionTargetBytes,
                forceVideoEncoding: true
            )
            let outputBytes = try fileSize(of: compressedURL)
            guard outputBytes <= maximumUploadBytes else {
                let megabytes = outputBytes / 1_000_000
                throw MediaError.message("The converted video is still \(megabytes) MB")
            }
            return PreparedMedia(url: compressedURL, isTemporary: true)
        } catch {
            try? FileManager.default.removeItem(at: compressedURL)
            if let mediaError = error as? MediaError { throw mediaError }
            throw MediaError.message("This MOV file could not be converted to MP4")
        }
    }

    private static func export(
        _ sourceURL: URL,
        to outputURL: URL,
        preset: String,
        fileLengthLimit: Int64? = nil,
        forceVideoEncoding: Bool = false
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaError.message("This MOV format is not supported")
        }

        exporter.shouldOptimizeForNetworkUse = true
        if let fileLengthLimit { exporter.fileLengthLimit = fileLengthLimit }
        if forceVideoEncoding {
            exporter.videoComposition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        }

        if #available(macOS 15.0, *) {
            try await exporter.export(to: outputURL, as: .mp4)
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = .mp4
            let sendableExporter = SendableExporter(exporter)
            try await withCheckedThrowingContinuation { continuation in
                sendableExporter.value.exportAsynchronously {
                    switch sendableExporter.value.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(throwing: sendableExporter.value.error ?? MediaError.message("Video conversion failed"))
                    }
                }
            }
        }
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw MediaError.message("Could not read the selected file")
        }
        return Int64(size)
    }
}
