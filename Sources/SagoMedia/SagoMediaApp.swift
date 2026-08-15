import AppKit
import Security
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
    private let api = MediaAPI()

    func upload(_ urls: [URL]) {
        guard !urls.isEmpty, !isUploading else { return }
        isUploading = true
        message = urls.count == 1 ? "Uploading \(urls[0].lastPathComponent)…" : "Uploading \(urls.count) files…"
        Task {
            for url in urls {
                do {
                    let result = try await api.upload(url)
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
        guard !isUploading else { return }
        isUploading = true
        message = "Starting secure login…"
        Task {
            do {
                let device = try await api.startLogin()
                message = "Approve code \(device.userCode) in your browser"
                NSWorkspace.shared.open(device.verificationUri)
                let scope = try await api.waitForApproval(device)
                message = "Signed in with \(scope) access"
            } catch {
                message = error.localizedDescription
                NSSound.beep()
            }
            isUploading = false
        }
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

    func upload(_ fileURL: URL) async throws -> UploadResult {
        guard let token = try Keychain.load() else { throw MediaError.message("Sign in before uploading") }
        var request = URLRequest(url: baseURL.appending(path: "/v1/uploads"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(fileURL.lastPathComponent, forHTTPHeaderField: "X-Media-Filename")
        request.httpBody = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try await send(request, as: UploadResult.self)
    }

    private func send<Value: Decodable>(_ request: URLRequest, as type: Value.Type, acceptedStatuses: ClosedRange<Int> = 200...299) async throws -> Value {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, acceptedStatuses.contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MediaError.message(detail?.isEmpty == false ? detail! : "Sago Media request failed")
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw MediaError.message("Sago Media returned an invalid response") }
    }
}

enum Keychain {
    private static let service = "dev.hsichen.SagoMedia"
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
