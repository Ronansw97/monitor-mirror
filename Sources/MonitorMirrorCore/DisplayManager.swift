import AppKit
import Combine
import CoreGraphics
import Foundation

/// Owns the app's view of the displays: reads the window server, merges it with the
/// remembered registry, applies toggles off the main thread, and republishes.
@MainActor
public final class DisplayManager: ObservableObject {

    @Published public private(set) var displays: [ManagedDisplay] = []
    /// Keys of displays with a toggle in flight. Their cells stop responding to clicks.
    @Published public private(set) var busyKeys: Set<String> = []
    /// Human-readable text for the most recent failure; cleared on the next success.
    @Published public private(set) var lastError: String?

    public var activeCount: Int { displays.filter(\.isOn).count }
    public var totalCount: Int { displays.count }
    public var anyOn: Bool { displays.contains(where: \.isOn) }
    public var supportsHardOff: Bool { controller.supportsHardOff }
    public var isBusy: Bool { !busyKeys.isEmpty }

    private let provider: DisplaySnapshotProviding
    private let controller: DisplayPowerControlling
    private let store: RememberedDisplayStore
    private let now: () -> Date

    private var remembered: [RememberedDisplay]
    private var refreshGeneration = 0
    private var reconfigurationObserver: DisplayReconfigurationObserver?
    private var screenParametersToken: NSObjectProtocol?

    public init(
        provider: DisplaySnapshotProviding = SystemDisplayProvider(),
        controller: DisplayPowerControlling? = nil,
        store: RememberedDisplayStore = UserDefaultsDisplayStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.controller = controller ?? DisplayPowerController(provider: provider)
        self.store = store
        self.now = now
        self.remembered = store.load()
        refresh()
    }

    deinit {
        // Both observers hold a pointer back to this object, so a late window-server
        // callback would otherwise reach a deallocated manager.
        reconfigurationObserver?.stop()
        if let screenParametersToken {
            NotificationCenter.default.removeObserver(screenParametersToken)
        }
    }

    /// Starts listening for displays being attached, detached, or reconfigured by
    /// anything else on the system (System Settings, sleep/wake, a KVM switch).
    public func startObserving() {
        guard reconfigurationObserver == nil else { return }

        let observer = DisplayReconfigurationObserver { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        observer.start()
        reconfigurationObserver = observer

        // Belt and braces: the CoreGraphics callback covers hardware changes, this covers
        // arrangement changes that only surface through AppKit.
        screenParametersToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    /// Coalesces the burst of callbacks the window server emits for a single change.
    public func scheduleRefresh(after delay: TimeInterval = 0.25) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, generation == self.refreshGeneration else { return }
            self.refresh()
        }
    }

    /// Re-reads the window server and republishes. Cheap enough to call freely.
    public func refresh() {
        // A toggle in flight is already showing its optimistic state; letting a
        // mid-transition snapshot overwrite it would flicker the cell.
        guard busyKeys.isEmpty else { return }

        let output = DisplayReducer.reconcile(
            online: provider.snapshot(),
            remembered: remembered,
            now: now()
        )
        remembered = output.remembered
        store.save(output.remembered)
        if displays != output.displays { displays = output.displays }
    }

    /// Flips one display, optimistically updating the cell so the .25s animation starts
    /// on the click rather than when the window server catches up.
    public func toggle(_ display: ManagedDisplay) {
        let desiredOn = !display.isOn
        guard !busyKeys.contains(display.key) else { return }

        if let reason = DisplayReducer.rejectionReason(toggling: display, to: desiredOn, in: displays) {
            lastError = reason.errorDescription
            return
        }

        // Record the intent before the change lands. If the display powers down hard it
        // disappears from the window server, and this flag is the only thing that keeps
        // its cell in the popover.
        setIntent(wantsOff: !desiredOn, forKey: display.key)

        busyKeys.insert(display.key)
        lastError = nil
        applyOptimistic(isOn: desiredOn, toKey: display.key)

        let controller = self.controller
        let displayID = display.displayID
        let key = display.key
        Task.detached(priority: .userInitiated) {
            let result = Result { try controller.setOn(desiredOn, displayID: displayID) }
            await MainActor.run {
                self.finishToggle(key: key, desiredOn: desiredOn, result: result)
            }
        }
    }

    private func finishToggle(
        key: String,
        desiredOn: Bool,
        result: Result<DisplayControlStrategy, Error>
    ) {
        busyKeys.remove(key)
        switch result {
        case .success:
            lastError = nil
        case .failure(let error):
            // The change did not happen, so the recorded intent was wrong. Undo it before
            // refreshing, otherwise a failed switch-off would leave a ghost cell behind.
            setIntent(wantsOff: desiredOn, forKey: key)
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        refresh()
    }

    /// Restores every display currently off. The escape hatch for when a display was
    /// switched off and will not come back through its own cell.
    ///
    /// Intent is cleared only for displays the controller confirms came back on, so a
    /// display that fails to restore keeps both its cell and its remembered entry — the
    /// user can try again rather than losing the only way to reach it.
    public func restoreAllDisplays() {
        guard busyKeys.isEmpty else { return }

        // Everything the popover shows as off: online-but-mirrored plus remembered-offline.
        let targets = displays.filter { !$0.isOn }
        guard !targets.isEmpty else { return }

        let ids = targets.map(\.displayID)
        let keysByID = Dictionary(targets.map { ($0.displayID, $0.key) }, uniquingKeysWith: { a, _ in a })

        busyKeys.formUnion(targets.map(\.key))
        lastError = nil

        let controller = self.controller
        Task.detached(priority: .userInitiated) {
            let restored = controller.restore(displayIDs: ids)
            await MainActor.run {
                self.busyKeys.subtract(targets.map(\.key))
                for id in restored {
                    if let key = keysByID[id] { self.setIntent(wantsOff: false, forKey: key) }
                }
                if restored.count < ids.count {
                    self.lastError = "Some displays did not come back. Try again, or check the cable."
                }
                self.refresh()
            }
        }
    }

    /// Makes one display the main display — the one that owns the menu bar. Only a lit,
    /// online display can hold the menu bar, so off/offline cells reject the request.
    public func setMain(_ display: ManagedDisplay) {
        guard busyKeys.isEmpty else { return }
        guard display.isOn, display.isOnline else {
            lastError = DisplayControlError.cannotMakeOffDisplayMain.errorDescription
            return
        }
        guard !display.isMain else { return }

        busyKeys.insert(display.key)
        lastError = nil
        // Optimistic: light up the new main's indicator immediately, clear the old one.
        for index in displays.indices {
            displays[index].isMain = (displays[index].key == display.key)
        }

        let controller = self.controller
        let displayID = display.displayID
        let key = display.key
        Task.detached(priority: .userInitiated) {
            let result = Result { try controller.setMain(displayID: displayID) }
            await MainActor.run {
                self.busyKeys.remove(key)
                if case .failure(let error) = result {
                    self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                self.refresh()
            }
        }
    }

    private func setIntent(wantsOff: Bool, forKey key: String) {
        guard let index = remembered.firstIndex(where: { $0.key == key }) else { return }
        remembered[index].wantsOff = wantsOff
        remembered[index].lastSeen = now()
        store.save(remembered)
    }

    private func applyOptimistic(isOn: Bool, toKey key: String) {
        guard let index = displays.firstIndex(where: { $0.key == key }) else { return }
        displays[index].isOn = isOn
    }

    /// A text dump of everything the app can see, for `--diagnose` and the right-click menu.
    public func diagnosticsReport() -> String {
        var lines: [String] = []
        lines.append("MONITOR MIRROR — DIAGNOSTICS")
        lines.append("hard power-off available: \(controller.supportsHardOff)")
        lines.append("main display id: \(provider.mainDisplayID())")
        lines.append("")
        lines.append("WINDOW SERVER")
        for display in provider.snapshot() {
            lines.append("  id=\(display.displayID)  \(display.localizedName ?? "—")")
            lines.append("    key=\(display.key)")
            lines.append("    \(display.pixelWidth)x\(display.pixelHeight) @ \(display.refreshHz)Hz"
                + "  main=\(display.isMain) builtIn=\(display.isBuiltIn)"
                + "  mirrors=\(display.mirrorsDisplay) originX=\(display.originX)")
        }
        lines.append("")
        lines.append("POPOVER")
        for display in displays {
            lines.append("  \(display.name) [\(display.spec)]"
                + "  on=\(display.isOn) online=\(display.isOnline) id=\(display.displayID)")
        }
        lines.append("")
        lines.append("REMEMBERED")
        for entry in remembered {
            lines.append("  \(entry.name) key=\(entry.key) wantsOff=\(entry.wantsOff) lastSeen=\(entry.lastSeen)")
        }
        if let lastError {
            lines.append("")
            lines.append("LAST ERROR: \(lastError)")
        }
        return lines.joined(separator: "\n")
    }
}

/// The C callback has to be a single stable function pointer: CoreGraphics matches
/// registration and removal on (function, context), so a fresh closure literal at
/// removal time would not unregister anything.
private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard let userInfo else { return }
    // `beginConfiguration` fires before anything has actually changed; reading the
    // display list then would just give us the old state.
    guard !flags.contains(.beginConfigurationFlag) else { return }
    Unmanaged<DisplayReconfigurationObserver>.fromOpaque(userInfo)
        .takeUnretainedValue()
        .fire()
}

/// Wraps `CGDisplayRegisterReconfigurationCallback`, which takes a bare C function
/// pointer and so cannot capture context on its own.
final class DisplayReconfigurationObserver {

    private let handler: @Sendable () -> Void
    private var registered = false

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func fire() { handler() }

    func start() {
        guard !registered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        registered = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context) == .success
    }

    func stop() {
        guard registered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context)
        registered = false
    }
}
