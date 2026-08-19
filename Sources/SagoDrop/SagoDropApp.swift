import AppKit
import Security
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
func smokeLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["SAGO_MEDIA_SMOKE_LOG"] == "1" else { return }
    FileHandle.standardError.write(Data("SMOKE \(message)\n".utf8))
}
#endif

@main
struct SagoDropApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: SagoDropAppDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class SagoDropAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = UploadModel()
        menuBarController = MenuBarController(model: model)
#if DEBUG
        if let testFile = ProcessInfo.processInfo.environment["SAGO_MEDIA_SMOKE_FILE"] {
            model.onSmokeTestComplete = { succeeded in
                smokeLog("complete success=\(succeeded)")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    NSApplication.shared.terminate(nil)
                }
            }
            Task { @MainActor in model.upload([URL(fileURLWithPath: testFile)]) }
        }
#endif
    }
}

struct UploadResult: Identifiable, Decodable {
    let id = UUID()
    let url: String
    let markdown: String
    let previewUrl: String?

    enum CodingKeys: String, CodingKey { case url, markdown, previewUrl }
}

enum UploadProgressUpdate {
    case transferring(Double)
    case processing
}

@MainActor
final class UploadModel {
    var isUploading = false
    var message = ""
    var recent: [UploadResult] = []
    var onMenuBarStateChange: ((MenuBarState) -> Void)?
    var onStatus: ((String) -> Void)?
    var isSignedIn: Bool { (try? Keychain.load()) != nil }
    var onUploadProgressChange: ((UploadProgressUpdate?) -> Void)?
#if DEBUG
    var onSmokeTestComplete: ((Bool) -> Void)?
#endif
    private let api = MediaAPI()
    private let supportedExtensions = Set(["gif", "jpeg", "jpg", "mov", "mp4", "png", "webm", "webp"])
    private var processingStartedAt: Date?

    func accepts(_ urls: [URL]) -> Bool {
        !isUploading && !urls.isEmpty && urls.allSatisfy {
            $0.isFileURL && supportedExtensions.contains($0.pathExtension.lowercased())
        }
    }

    func chooseFiles() {
        guard !isUploading else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose images or videos to upload"
        panel.prompt = "Upload"
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    func uploadCopiedFiles() {
        guard !isUploading else { return }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL])?
            .map { $0 as URL } ?? []
        guard !urls.isEmpty else {
            report("Copy a supported file first")
            NSSound.beep()
            return
        }
        upload(urls)
    }

    func downloadClipboard() {
        guard !isUploading else { return }
        do {
            guard let url = try ClipboardFile.create() else {
                report("Clipboard is empty or unsupported")
                NSSound.beep()
                return
            }
            report("Saved \(url.lastPathComponent) to Downloads")
        } catch {
            report("Couldn’t save to Downloads")
            NSSound.beep()
        }
    }

    func upload(_ urls: [URL]) {
        let urls = urls.filter { $0.isFileURL && supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !isUploading else { return }
        guard !urls.isEmpty else {
            report("Choose PNG, JPEG, GIF, WebP, MOV, MP4, or WebM files")
            NSSound.beep()
            return
        }
        isUploading = true
        message = urls.count == 1 ? "Uploading \(urls[0].lastPathComponent)…" : "Uploading \(urls.count) files…"
        Task {
            var failed = false
            var completionStatus = message
            var failureStatus: String?
            for url in urls {
                do {
                    let isMOV = url.pathExtension.lowercased() == "mov"
                    message = isMOV ? "Preparing \(url.lastPathComponent)…" : "Uploading \(url.lastPathComponent)…"
                    onMenuBarStateChange?(isMOV ? .converting : .uploading)
                    let prepared = try await MediaPreparation.prepare(url)
                    defer { prepared.cleanUp() }
                    if prepared.isTemporary { message = "Uploading converted MP4…" }
                    onMenuBarStateChange?(.uploading)
                    processingStartedAt = nil
                    onUploadProgressChange?(.transferring(0))
                    let result = try await api.upload(prepared.url) { [weak self] progress in
                        guard let self else { return }
                        let percentage = Int((progress * 100).rounded())
                        message = progress < 1
                            ? "Uploading \(url.lastPathComponent)… \(percentage)%"
                            : "Finishing \(url.lastPathComponent)…"
                        if progress < 1 {
                            onUploadProgressChange?(.transferring(progress))
                        } else {
                            processingStartedAt = processingStartedAt ?? Date()
                            onUploadProgressChange?(.processing)
                        }
                    }
                    let processingStart = processingStartedAt ?? Date()
                    processingStartedAt = processingStart
                    onUploadProgressChange?(.processing)
                    let remainingFeedback = 0.45 - Date().timeIntervalSince(processingStart)
                    if remainingFeedback > 0 {
                        try? await Task.sleep(for: .seconds(remainingFeedback))
                    }
                    onUploadProgressChange?(.transferring(1))
                    try? await Task.sleep(for: .milliseconds(150))
                    onUploadProgressChange?(nil)
                    processingStartedAt = nil
                    recent.insert(result, at: 0)
                    copy(result.url)
                    completionStatus = "Copied \(url.lastPathComponent)"
                    message = completionStatus
                } catch {
                    failed = true
                    processingStartedAt = nil
                    onUploadProgressChange?(nil)
                    failureStatus = error.localizedDescription
                    message = error.localizedDescription
                    NSSound.beep()
                }
            }
            isUploading = false
            report(failureStatus ?? completionStatus)
            onMenuBarStateChange?(failed ? .failure : .success)
#if DEBUG
            onSmokeTestComplete?(!failed)
#endif
        }
    }

    func login() {
        guard !isUploading else { return }
        isUploading = true
        message = "Starting secure login…"
        Task {
            do {
                let device = try await api.startLogin()
                message = "Approve code \(device.userCode) in your browser"
                NSWorkspace.shared.open(device.verificationUri)
                onStatus?(message)
                _ = try await api.waitForApproval(device)
                report("Signed in")
            } catch {
                report(error.localizedDescription)
                NSSound.beep()
            }
            isUploading = false
        }
    }

    func logout() {
        guard !isUploading else { return }
        do {
            try Keychain.delete()
            report("Signed out")
        } catch {
            report(error.localizedDescription)
            NSSound.beep()
        }
    }

    func report(_ status: String) {
        message = status
        onStatus?(status)
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct DeviceRequest: Decodable {
    let deviceCode: String
    let deviceSecret: String
    let userCode: String
    let verificationUri: URL
    let expiresIn: Int
    let interval: Int
}

private struct DeviceStatus: Decodable {
    let status: String
    let token: String?
    let scope: String?
}

enum MediaError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

struct MediaAPI {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: ProcessInfo.processInfo.environment["MEDIA_URL"] ?? "https://media.hsichen.dev")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func startLogin() async throws -> DeviceRequest {
        var request = URLRequest(url: baseURL.appending(path: "/v1/auth/device"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceName": Host.current().localizedName ?? "Mac"])
        return try await send(request, as: DeviceRequest.self)
    }

    func waitForApproval(_ device: DeviceRequest) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(device.interval))
            var request = URLRequest(url: baseURL.appending(path: "/v1/auth/device/\(device.deviceCode)"))
            request.setValue("Device \(device.deviceSecret)", forHTTPHeaderField: "Authorization")
            let status = try await send(request, as: DeviceStatus.self, acceptedStatuses: 200...499)
            if status.status == "approved", let token = status.token {
                try Keychain.save(token)
                return status.scope ?? "upload"
            }
            if status.status == "denied" { throw MediaError.message("Access was denied") }
        }
        throw MediaError.message("The access request expired")
    }

    func upload(_ fileURL: URL, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> UploadResult {
        guard let token = try uploadToken() else { throw MediaError.message("Sign in before uploading") }
        var request = URLRequest(url: baseURL.appending(path: "/v1/uploads"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(fileURL.lastPathComponent, forHTTPHeaderField: "X-Media-Filename")
        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        return try decode(data, response: response, as: UploadResult.self)
    }

    private func uploadToken() throws -> String? {
#if DEBUG
        if let smokeToken = ProcessInfo.processInfo.environment["SAGO_MEDIA_SMOKE_TOKEN"] {
            return smokeToken
        }
#endif
        return try Keychain.load()
    }

    private func send<Value: Decodable>(_ request: URLRequest, as type: Value.Type, acceptedStatuses: ClosedRange<Int> = 200...299) async throws -> Value {
        let (data, response) = try await session.data(for: request)
        return try decode(data, response: response, as: type, acceptedStatuses: acceptedStatuses)
    }

    private func decode<Value: Decodable>(_ data: Data, response: URLResponse, as type: Value.Type, acceptedStatuses: ClosedRange<Int> = 200...299) throws -> Value {
        guard let http = response as? HTTPURLResponse, acceptedStatuses.contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MediaError.message(detail?.isEmpty == false ? detail! : "Sago Drop request failed")
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw MediaError.message("Sago Drop returned an invalid response") }
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @MainActor @Sendable (Double) -> Void

    init(onProgress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        Task { @MainActor [onProgress] in onProgress(progress) }
    }
}

enum Keychain {
    private static let service = "dev.hsichen.SagoDrop"
    private static let account = "upload-token"

    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var value = query
        value[kSecValueData as String] = Data(token.utf8)
        guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else { throw MediaError.message("Could not save credentials in Keychain") }
    }

    static func load() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw MediaError.message("Could not read credentials from Keychain") }
        return token
    }

    static func delete() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MediaError.message("Could not remove credentials from Keychain") }
    }
}
