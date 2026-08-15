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
        case .converting: "arrow.triangle.2.circlepath"
        case .uploading: "arrow.up.circle.fill"
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "Sago Media, ready to upload"
        case .targeted: "Sago Media, release to upload"
        case .converting: "Sago Media, converting video"
        case .uploading: "Sago Media, uploading"
        case .success: "Sago Media, link copied"
        case .failure: "Sago Media, upload failed"
        }
    }

    var isBusy: Bool { self == .converting || self == .uploading }
}

@MainActor
final class MenuBarController: NSObject, ObservableObject {
    @Published private(set) var displayedState = MenuBarState.idle
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

    init(model: UploadModel) {
        self.model = model
        super.init()

        configureStatusItem()
        model.onMenuBarStateChange = { [weak self] state in
            self?.setActivityState(state)
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = ""

        let iconView = NSHostingView(rootView: MenuBarIcon(controller: self))
        iconView.frame = button.bounds
        iconView.autoresizingMask = [.width, .height]
        button.addSubview(iconView)

        let dropView = StatusItemDropView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.delegate = self
        button.addSubview(dropView)
        updateAccessibility()
    }

    private func setActivityState(_ state: MenuBarState) {
        resetTask?.cancel()
        activityState = state
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
        statusItem.button?.toolTip = displayedState.accessibilityLabel
        statusItem.button?.setAccessibilityLabel(displayedState.accessibilityLabel)
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

        if !model.message.isEmpty {
            let status = NSMenuItem(title: model.message, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
        }

        menu.addItem(actionItem("Paste Files", action: #selector(pasteFiles), keyEquivalent: "v", enabled: !model.isUploading))
        menu.addItem(actionItem("Choose Files…", action: #selector(chooseFiles), keyEquivalent: "o", enabled: !model.isUploading))

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
        menu.addItem(actionItem("Quit Sago Media", action: #selector(quit)))
    }

    private func actionItem(_ title: String, action: Selector, keyEquivalent: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = enabled
        if !keyEquivalent.isEmpty { item.keyEquivalentModifierMask = [.command] }
        return item
    }

    @objc private func pasteFiles() {
        model.pasteFiles()
    }

    @objc private func chooseFiles() {
        model.chooseFiles()
    }

    @objc private func copyRecentLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        model.copy(url)
        model.message = "Copied link"
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
                currentIcon
                    .contentTransition(.symbolEffect(.automatic))
                    .symbolEffect(
                        .wiggle.up.byLayer,
                        value: controller.targetedEffectTrigger
                    )
                    .symbolEffect(
                        .rotate,
                        options: .repeating,
                        isActive: controller.displayedState == .converting
                    )
                    .symbolEffect(
                        .breathe.byLayer,
                        options: .repeating,
                        isActive: controller.displayedState == .uploading
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.displayedState)
        .accessibilityLabel(controller.displayedState.accessibilityLabel)
        .allowsHitTesting(false)
    }

    private var currentIcon: Image {
        Image(systemName: controller.displayedState.symbolName)
    }

    @available(macOS 15.0, *)
    private var modernIcon: some View {
        currentIcon
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(
                .wiggle.up.byLayer,
                value: controller.targetedEffectTrigger
            )
            .symbolEffect(
                .rotate,
                options: .repeating,
                isActive: controller.displayedState == .converting
            )
            .symbolEffect(
                .breathe.byLayer,
                options: .repeating,
                isActive: controller.displayedState == .uploading
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
        currentIcon
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
                isActive: controller.displayedState == .uploading
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
