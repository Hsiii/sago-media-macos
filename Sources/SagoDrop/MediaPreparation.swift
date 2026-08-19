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
    static let maximumUploadBytes: Int64 = 90_000_000
    private static let compressionTargetBytes: Int64 = 80_000_000
    private static let videoExtensions = Set(["mov", "mp4"])

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func prepare(_ sourceURL: URL) async throws -> PreparedMedia {
        let sourceBytes = try fileSize(of: sourceURL)

        guard isVideo(sourceURL) else {
            guard sourceBytes <= maximumUploadBytes else {
                throw MediaError.message("This file is over the 90 MB upload limit")
            }
            return PreparedMedia(url: sourceURL, isTemporary: false)
        }

        let identifier = UUID().uuidString
        let compressedURL = FileManager.default.temporaryDirectory
            .appending(path: "sago-drop-\(identifier)-compressed.mp4")
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
            throw MediaError.message("This video could not be converted to MP4")
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
            throw MediaError.message("This video format is not supported")
        }

        exporter.shouldOptimizeForNetworkUse = true
        exporter.metadata = []
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

        let movie = AVMutableMovie(url: outputURL, options: nil)
        movie.metadata = []
        try movie.writeHeader(to: outputURL, fileType: .mp4, options: .addMovieHeaderToDestination)
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw MediaError.message("Could not read the selected file")
        }
        return Int64(size)
    }
}
