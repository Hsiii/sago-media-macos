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
final class MenuBarController: NSObject, ObservableObject, NSPopoverDelegate {
    @Published private(set) var displayedState = MenuBarState.idle
    @Published private(set) var effectTrigger = 0

    private let model: UploadModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var activityState = MenuBarState.idle
    private var isDropTargeted = false
    private var resetTask: Task<Void, Never>?

    init(model: UploadModel) {
        self.model = model
        super.init()

        configureStatusItem()
        configurePopover()
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

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        let controller = NSHostingController(rootView: SharePanel(model: model))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
    }

    private func setActivityState(_ state: MenuBarState) {
        resetTask?.cancel()
        activityState = state
        effectTrigger += 1
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
        effectTrigger += 1
        display(targeted ? .targeted : activityState)
        statusItem.button?.highlight(targeted || popover.isShown)
    }

    fileprivate func receiveDrop(_ urls: [URL]) {
        setDropTargeted(false)
        model.upload(urls)
    }

    fileprivate func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        if activityState == .failure { setActivityState(.idle) }
        guard let button = statusItem.button else { return }
        statusItem.button?.highlight(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(isDropTargeted)
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
        delegate?.togglePopover()
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

    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                modernIcon
            } else {
                legacyIcon
            }
        }
        .font(.system(size: 14, weight: .regular))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityLabel(controller.displayedState.accessibilityLabel)
        .allowsHitTesting(false)
    }

    @available(macOS 15.0, *)
    @ViewBuilder
    private var modernIcon: some View {
        switch controller.displayedState {
        case .idle:
            Image(systemName: MenuBarState.idle.symbolName)
        case .targeted:
            Image(systemName: MenuBarState.targeted.symbolName)
                .symbolEffect(.wiggle.up.byLayer, options: .repeating)
        case .converting:
            Image(systemName: MenuBarState.converting.symbolName)
                .symbolEffect(.rotate.counterClockwise.byLayer, options: .repeating)
        case .uploading:
            Image(systemName: MenuBarState.uploading.symbolName)
                .symbolEffect(.breathe.pulse.byLayer, options: .repeating)
        case .success:
            Image(systemName: MenuBarState.success.symbolName)
                .symbolEffect(.bounce.up.byLayer, value: controller.effectTrigger)
        case .failure:
            Image(systemName: MenuBarState.failure.symbolName)
                .symbolEffect(.wiggle.byLayer, options: .repeat(2), value: controller.effectTrigger)
        }
    }

    @ViewBuilder
    private var legacyIcon: some View {
        switch controller.displayedState {
        case .idle:
            Image(systemName: MenuBarState.idle.symbolName)
        case .targeted:
            Image(systemName: MenuBarState.targeted.symbolName)
                .symbolEffect(.pulse, options: .repeating)
        case .converting:
            Image(systemName: MenuBarState.converting.symbolName)
                .symbolEffect(.pulse, options: .repeating)
        case .uploading:
            Image(systemName: MenuBarState.uploading.symbolName)
                .symbolEffect(.pulse, options: .repeating)
        case .success:
            Image(systemName: MenuBarState.success.symbolName)
                .symbolEffect(.bounce.up.byLayer, value: controller.effectTrigger)
        case .failure:
            Image(systemName: MenuBarState.failure.symbolName)
                .symbolEffect(.pulse, value: controller.effectTrigger)
        }
    }
}
