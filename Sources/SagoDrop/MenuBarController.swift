import AppKit
import SwiftUI

enum MenuBarState: Equatable {
    case idle
    case targeted
    case converting
    case uploading
    case success
    case failure

    var symbolName: String {
        switch self {
        case .idle, .targeted: "square.and.arrow.up"
        case .converting: "gearshape.2"
        case .uploading: "arrow.up.circle.fill"
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "Sago Drop, ready to upload"
        case .targeted: "Sago Drop, release to upload"
        case .converting: "Sago Drop, converting video"
        case .uploading: "Sago Drop, uploading"
        case .success: "Sago Drop, link copied"
        case .failure: "Sago Drop, upload failed"
        }
    }

    var isBusy: Bool { self == .converting || self == .uploading }
}

@MainActor
final class MenuBarController: NSObject, ObservableObject {
    private static let suppressStatusDialogsKey = "suppressStatusDialogs"

    @Published private(set) var displayedState = MenuBarState.idle
    @Published private(set) var uploadProgress: Double?
    @Published private(set) var targetedEffectTrigger = 0
    @Published private(set) var successEffectTrigger = 0
    @Published private(set) var failureEffectTrigger = 0

    private let model: UploadModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var activityState = MenuBarState.idle
    private var isDropTargeted = false
    private var isMenuPresented = false
    private var resetTask: Task<Void, Never>?
    private var progressTailTask: Task<Void, Never>?
    private var uploadPercentage: Int?
    private var isFinishingUpload = false
    private var statusAlert: NSAlert?

    init(model: UploadModel) {
        self.model = model
        super.init()

        configureStatusItem()
        model.onMenuBarStateChange = { [weak self] state in
            self?.setActivityState(state)
        }
        model.onUploadProgressChange = { [weak self] update in
            self?.updateUploadProgress(update)
        }
        model.onStatus = { [weak self] status in
            self?.presentStatus(status)
        }
    }

    private func configureStatusItem() {
        statusItem.autosaveName = "SagoMedia"
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = NSImage(size: NSSize(width: 14, height: 14))

        let iconView = NSHostingView(rootView: MenuBarIcon(controller: self))
        iconView.frame = button.bounds
        iconView.autoresizingMask = [.width, .height]
        button.addSubview(iconView)

        let dropView = StatusItemDropView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.delegate = self
        button.addSubview(dropView)
        updateAccessibility()
#if DEBUG
        Task { @MainActor [weak self, weak button] in
            await Task.yield()
            guard let self, let button else { return }
            smokeLog("status visible=\(statusItem.isVisible) button=\(button.frame) window=\(String(describing: button.window?.frame))")
        }
#endif
    }

    private func setActivityState(_ state: MenuBarState) {
        resetTask?.cancel()
        activityState = state
#if DEBUG
        smokeLog("state=\(String(describing: state))")
#endif
        switch state {
        case .success:
            successEffectTrigger += 1
        case .failure:
            failureEffectTrigger += 1
        default:
            break
        }
        if !isDropTargeted { display(state) }

        guard state == .success else { return }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, self?.activityState == .success else { return }
            self?.setActivityState(.idle)
        }
    }

    private func display(_ state: MenuBarState) {
        displayedState = state
        updateAccessibility()
    }

    private func updateAccessibility() {
        let label: String
        if displayedState == .uploading, isFinishingUpload {
            label = "Sago Media, finishing upload"
        } else if displayedState == .uploading, let uploadPercentage {
            label = "\(displayedState.accessibilityLabel), \(uploadPercentage) percent"
        } else {
            label = displayedState.accessibilityLabel
        }
        statusItem.button?.toolTip = label
        statusItem.button?.setAccessibilityLabel(label)
    }

    private func updateUploadProgress(_ update: UploadProgressUpdate?) {
        progressTailTask?.cancel()

        switch update {
        case .transferring(let progress):
            let clampedProgress = min(1, max(0, progress))
            uploadPercentage = Int((clampedProgress * 100).rounded())
            isFinishingUpload = false
            uploadProgress = clampedProgress == 1 ? 1 : 0.06 + (clampedProgress * 0.86)
        case .processing:
            uploadPercentage = nil
            isFinishingUpload = true
            uploadProgress = max(uploadProgress ?? 0, 0.92)
            progressTailTask = Task { [weak self] in
                for target in [0.95, 0.97, 0.98] {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled, self?.isFinishingUpload == true else { return }
                    self?.uploadProgress = target
#if DEBUG
                    smokeLog("tail displayed=\(target)")
#endif
                }
            }
        case nil:
            uploadPercentage = nil
            isFinishingUpload = false
            uploadProgress = nil
        }

#if DEBUG
        let displayedProgress = uploadProgress.map { String($0) } ?? "none"
        let actualProgress = uploadPercentage.map { String($0) } ?? "none"
        smokeLog("progress displayed=\(displayedProgress) actual=\(actualProgress) finishing=\(isFinishingUpload)")
#endif
        updateAccessibility()
    }

    fileprivate func acceptsDrop(_ urls: [URL]) -> Bool {
        !activityState.isBusy && model.accepts(urls)
    }

    fileprivate func setDropTargeted(_ targeted: Bool) {
        guard targeted != isDropTargeted else { return }
        isDropTargeted = targeted
        if targeted { targetedEffectTrigger += 1 }
        display(targeted ? .targeted : activityState)
        statusItem.button?.highlight(targeted || isMenuPresented)
    }

    fileprivate func receiveDrop(_ urls: [URL]) {
        setDropTargeted(false)
        model.upload(urls)
    }

    fileprivate func showMenu() {
        if activityState == .failure { setActivityState(.idle) }
        guard let button = statusItem.button else { return }
        rebuildMenu()
        isMenuPresented = true
        button.highlight(true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        isMenuPresented = false
        button.highlight(isDropTargeted)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(actionItem("Upload Files…", action: #selector(chooseFiles), keyEquivalent: "o", enabled: !model.isUploading))
        menu.addItem(actionItem(
            "Upload Copied Files",
            action: #selector(uploadCopiedFiles),
            keyEquivalent: "v",
            modifiers: [.command, .shift],
            enabled: !model.isUploading
        ))
        menu.addItem(actionItem(
            "Save Clipboard",
            action: #selector(downloadClipboard),
            keyEquivalent: "v",
            enabled: !model.isUploading
        ))

        if !model.recent.isEmpty {
            menu.addItem(.separator())
            let recentItem = NSMenuItem(title: "Recent Uploads", action: nil, keyEquivalent: "")
            let recentMenu = NSMenu(title: "Recent Uploads")
            for result in model.recent.prefix(5) {
                let title = URL(string: result.url)?.lastPathComponent.removingPercentEncoding ?? result.url
                let item = actionItem(title, action: #selector(copyRecentLink))
                item.representedObject = result.url
                recentMenu.addItem(item)
            }
            recentItem.submenu = recentMenu
            menu.addItem(recentItem)
        }

        menu.addItem(.separator())
        if model.isSignedIn {
            menu.addItem(actionItem("Sign Out", action: #selector(signOut), enabled: !model.isUploading))
        } else {
            menu.addItem(actionItem("Sign In", action: #selector(signIn), enabled: !model.isUploading))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit", action: #selector(quit)))
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = enabled
        if !keyEquivalent.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    private func presentStatus(_ status: String) {
        guard !UserDefaults.standard.bool(forKey: Self.suppressStatusDialogsKey) else { return }

        if let statusAlert {
            statusAlert.informativeText = status
            return
        }

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !UserDefaults.standard.bool(forKey: Self.suppressStatusDialogsKey),
                  statusAlert == nil else { return }

            let alert = NSAlert()
            alert.messageText = "Sago Drop"
            alert.informativeText = status
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show this again"
            statusAlert = alert

            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.runModal()

            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Self.suppressStatusDialogsKey)
            }
            statusAlert = nil
        }
    }

    @objc private func uploadCopiedFiles() {
        model.uploadCopiedFiles()
    }

    @objc private func downloadClipboard() {
        model.downloadClipboard()
    }

    @objc private func chooseFiles() {
        model.chooseFiles()
    }

    @objc private func copyRecentLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        model.copy(url)
        model.report("Copied link")
    }

    @objc private func signIn() {
        model.login()
    }

    @objc private func signOut() {
        model.logout()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
private final class StatusItemDropView: NSView {
    weak var delegate: MenuBarController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApplication.shared.currentEvent?.modifierFlags.contains(.command) != true else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        delegate?.showMenu()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard delegate?.acceptsDrop(urls(from: sender)) == true else { return [] }
        delegate?.setDropTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        delegate?.acceptsDrop(urls(from: sender)) == true ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        delegate?.setDropTargeted(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        delegate?.setDropTargeted(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = urls(from: sender)
        guard delegate?.acceptsDrop(urls) == true else { return false }
        delegate?.receiveDrop(urls)
        return true
    }

    private func urls(from sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL])?
            .map { $0 as URL } ?? []
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var controller: MenuBarController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                iconContent
                    .symbolEffect(
                        .wiggle.up.byLayer,
                        value: controller.targetedEffectTrigger
                    )
                    .symbolEffect(
                        .rotate.byLayer,
                        options: .repeating,
                        isActive: controller.displayedState == .converting
                    )
                    .symbolEffect(
                        .breathe.byLayer,
                        options: .repeating,
                        isActive: controller.displayedState == .uploading && controller.uploadProgress == nil
                    )
                    .symbolEffect(
                        .bounce.up.byLayer,
                        value: controller.successEffectTrigger
                    )
                    .symbolEffect(
                        .wiggle.byLayer,
                        options: .repeat(2),
                        value: controller.failureEffectTrigger
                    )
            } else if #available(macOS 15.0, *) {
                modernIcon
            } else {
                legacyIcon
            }
        }
        .font(.system(size: 14, weight: .regular))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .symbolEffectsRemoved(reduceMotion)
        .accessibilityLabel(controller.displayedState.accessibilityLabel)
        .allowsHitTesting(false)
    }

    private var currentIcon: Image {
        Image(systemName: controller.displayedState.symbolName)
    }

    @ViewBuilder
    private var iconContent: some View {
        if controller.displayedState == .uploading, let progress = controller.uploadProgress {
            UploadProgressIcon(progress: progress)
        } else {
            currentIcon
        }
    }

    @available(macOS 15.0, *)
    private var modernIcon: some View {
        iconContent
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(
                .wiggle.up.byLayer,
                value: controller.targetedEffectTrigger
            )
            .symbolEffect(
                .rotate.byLayer,
                options: .repeating,
                isActive: controller.displayedState == .converting
            )
            .symbolEffect(
                .breathe.byLayer,
                options: .repeating,
                isActive: controller.displayedState == .uploading && controller.uploadProgress == nil
            )
            .symbolEffect(
                .bounce.up.byLayer,
                value: controller.successEffectTrigger
            )
            .symbolEffect(
                .wiggle.byLayer,
                options: .repeat(2),
                value: controller.failureEffectTrigger
            )
    }

    private var legacyIcon: some View {
        iconContent
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(
                .pulse,
                value: controller.targetedEffectTrigger
            )
            .symbolEffect(
                .pulse,
                options: .repeating,
                isActive: controller.displayedState == .converting
            )
            .symbolEffect(
                .variableColor.iterative.reversing,
                options: .repeating,
                isActive: controller.displayedState == .uploading && controller.uploadProgress == nil
            )
            .symbolEffect(
                .bounce.up.byLayer,
                value: controller.successEffectTrigger
            )
            .symbolEffect(
                .pulse,
                options: .repeat(2),
                value: controller.failureEffectTrigger
            )
    }
}

private struct UploadProgressIcon: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.24), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.primary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.up")
                .font(.system(size: 8, weight: .semibold))
        }
        .frame(width: 14, height: 14)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: progress)
        .accessibilityHidden(true)
    }
}
