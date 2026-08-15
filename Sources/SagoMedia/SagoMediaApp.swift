import AppKit
import SwiftUI

@main
struct SagoMediaApp: App {
    @StateObject private var model = UploadModel()

    var body: some Scene {
        MenuBarExtra {
            SharePanel(model: model)
        } label: {
            Image(systemName: model.isUploading ? "arrow.up.circle.fill" : "square.and.arrow.up")
                .symbolEffect(.pulse, isActive: model.isUploading)
                .dropDestination(for: URL.self) { urls, _ in
                    model.upload(urls.filter(\.isFileURL))
                    return !urls.isEmpty
                }
        }
        .menuBarExtraStyle(.window)
    }
}

struct UploadResult: Identifiable, Decodable {
    let id = UUID()
    let url: String
    let markdown: String
    let previewUrl: String?

    enum CodingKeys: String, CodingKey { case url, markdown, previewUrl }
}

@MainActor
final class UploadModel: ObservableObject {
    @Published var isUploading = false
    @Published var isDropTargeted = false
    @Published var message = "Drop a file to copy its share link"
    @Published var recent: [UploadResult] = []

    func upload(_ urls: [URL]) {
        guard !urls.isEmpty, !isUploading else { return }
        isUploading = true
        message = urls.count == 1 ? "Uploading \(urls[0].lastPathComponent)…" : "Uploading \(urls.count) files…"
        Task {
            for url in urls {
                do {
                    let result = try await MediaCLI.upload(url)
                    recent.insert(result, at: 0)
                    copy(result.url)
                    message = "Copied \(url.lastPathComponent)"
                } catch {
                    message = error.localizedDescription
                    NSSound.beep()
                }
            }
            isUploading = false
        }
    }

    func login() {
        MediaCLI.launchLogin()
        message = "Complete login in your browser"
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

enum MediaCLI {
    static func command(arguments: [String]) -> Process {
        let process = Process()
        if let installed = ["/opt/homebrew/bin/sago-media", "/usr/local/bin/sago-media"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            process.executableURL = URL(fileURLWithPath: installed)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["npx", "--yes", "sago-media@0.1.0"] + arguments
        }
        return process
    }

    static func upload(_ url: URL) async throws -> UploadResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = command(arguments: ["upload", url.path, "--output", "json"])
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.terminationHandler = { process in
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    do { continuation.resume(returning: try JSONDecoder().decode(UploadResult.self, from: stdout)) }
                    catch { continuation.resume(throwing: error) }
                } else {
                    let detail = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: NSError(domain: "SagoMedia", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "Upload failed"] ))
                }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }

    static func launchLogin() {
        let process = command(arguments: ["auth", "login"])
        try? process.run()
    }
}

struct SharePanel: View {
    @ObservedObject var model: UploadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sago Media").font(.headline)
                Text(model.message).font(.subheadline).foregroundStyle(.secondary)
            }

            dropTarget

            if !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.recent.prefix(5)) { item in
                        Button {
                            model.copy(item.url)
                            model.message = "Copied link"
                        } label: {
                            HStack {
                                Image(systemName: "link")
                                Text(URL(string: item.url)?.lastPathComponent ?? item.url).lineLimit(1)
                                Spacer()
                                Image(systemName: "doc.on.doc")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 40)
                    }
                }
            }

            HStack {
                Button("Sign in", action: model.login)
                Button("Access requests") { NSWorkspace.shared.open(URL(string: "https://media.hsichen.dev/admin")!) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var dropTarget: some View {
        VStack(spacing: 8) {
            Image(systemName: model.isUploading ? "arrow.up.circle.fill" : "tray.and.arrow.up")
                .font(.system(size: 28))
                .symbolEffect(.pulse, isActive: model.isUploading)
            Text(model.isUploading ? "Uploading" : "Drop files here").fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(model.isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)))
        .dropDestination(for: URL.self, action: { urls, _ in
            model.upload(urls.filter(\.isFileURL))
            return !urls.isEmpty
        }, isTargeted: { model.isDropTargeted = $0 })
    }
}
