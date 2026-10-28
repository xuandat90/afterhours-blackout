import AppKit
import Carbon.HIToolbox
import IOKit
import SwiftUI

// MARK: - Hidden CoreGraphics display power control

private typealias ConfigureDisplayEnabledFn =
    @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32
private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias GetBrightnessFn =
    @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

enum DisplayPower {
    nonisolated(unsafe) private static let coreGraphics = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    nonisolated(unsafe) private static let displayServices = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    nonisolated(unsafe) private static let configureEnabled: ConfigureDisplayEnabledFn? = {
        guard let cg = coreGraphics, let sym = dlsym(cg, "CGSConfigureDisplayEnabled")
        else { return nil }
        return unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
    }()

    nonisolated(unsafe) private static let setBrightnessFn: SetBrightnessFn? = {
        guard let ds = displayServices, let sym = dlsym(ds, "DisplayServicesSetBrightness")
        else { return nil }
        return unsafeBitCast(sym, to: SetBrightnessFn.self)
    }()

    nonisolated(unsafe) private static let getBrightnessFn: GetBrightnessFn? = {
        guard let ds = displayServices, let sym = dlsym(ds, "DisplayServicesGetBrightness")
        else { return nil }
        return unsafeBitCast(sym, to: GetBrightnessFn.self)
    }()

    /// Whether this macOS build still exposes the disconnect API.
    static let canDisconnect = configureEnabled != nil

    /// Removes a display from the arrangement (or brings it back) exactly like
    /// unplugging its cable: the link drops, the panel loses signal and the GPU
    /// stops driving it. Scoped to this login session so a logout always undoes it.
    @discardableResult
    static func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        guard let configureEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        let changed = configureEnabled(config, id, enabled) == 0
        let applied = CGCompleteDisplayConfiguration(config, .forSession) == .success
        return changed && applied
    }

    /// A re-enabled panel can come back at brightness 0, which looks like a dead screen.
    static func makeBuiltInVisible() {
        for raw in UInt32(1)...UInt32(32) {
            let id = CGDirectDisplayID(raw)
            guard CGDisplayIsBuiltin(id) != 0, CGDisplayIsActive(id) == 1 else { continue }
            _ = Brightness.set(id, kind: .gamma, value: 1)
            if let level = brightness(id), level < 0.25 {
                _ = setBrightness(id, 0.5)
            }
        }
    }

    /// Last resort: find the built-in panel by ID scan and re-enable it.
    @discardableResult
    static func enableBuiltInByScan() -> Bool {
        for raw in UInt32(1)...UInt32(32) {
            let id = CGDirectDisplayID(raw)
            guard CGDisplayIsBuiltin(id) != 0 else { continue }
            if setEnabled(id, true) { return true }
        }
        return false
    }

    static func activeCount() -> Int {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        return Int(count)
    }

    @discardableResult
    static func setBrightness(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let setBrightnessFn else { return false }
        return setBrightnessFn(id, value) == 0
    }

    static func brightness(_ id: CGDirectDisplayID) -> Float? {
        guard let getBrightnessFn else { return nil }
        var value: Float = .nan
        return getBrightnessFn(id, &value) == 0 ? value : nil
    }
}

// MARK: - Brightness

enum BrightnessKind {
    case hardware  // real panel / backlight brightness
    case gamma  // software dimming through the gamma table
    case none
}

enum Brightness {
    static func kind(for id: CGDirectDisplayID) -> BrightnessKind {
        guard CGDisplayIsActive(id) != 0 else { return .none }
        return DisplayPower.brightness(id) != nil ? .hardware : .gamma
    }

    static func current(_ id: CGDirectDisplayID, kind: BrightnessKind) -> Float {
        if kind == .hardware, let value = DisplayPower.brightness(id) { return value }
        return 1
    }

    @discardableResult
    static func set(_ id: CGDirectDisplayID, kind: BrightnessKind, value: Float) -> Bool {
        switch kind {
        case .hardware:
            return DisplayPower.setBrightness(id, value)
        case .gamma:
            // Never fully black through gamma: keep the panel readable at 5%.
            let scale = max(0.05, min(1, value))
            return CGSetDisplayTransferByFormula(id, 0, scale, 1, 0, scale, 1, 0, scale, 1)
                == .success
        case .none:
            return false
        }
    }
}

/// Physical presence of external displays, straight from IOKit.
enum DisplayPresence {
    /// One DCPAVServiceProxy with Location=External exists per connected external panel.
    static func connectedExternalCount() -> Int {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
                == KERN_SUCCESS
        else { return -1 }
        defer { IOObjectRelease(iterator) }
        var count = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let location = IORegistryEntryCreateCFProperty(
                service, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String, location == "External" {
                count += 1
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return count
    }
}

/// Non-isolated restore path so termination handlers can always run it.
enum DisconnectLedger {
    nonisolated(unsafe) static var ids: [CGDirectDisplayID] = []

    static func restoreAll() {
        let pending = ids
        ids = []
        for id in pending { DisplayPower.setEnabled(id, true) }
    }
}

// MARK: - Model

struct OffRecord: Codable, Identifiable {
    let id: UInt32
    let uuid: String
    let name: String
    let isBuiltIn: Bool
    let detail: String

    var displayID: CGDirectDisplayID { id }
}

struct DisplayItem: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let detail: String
    let isBuiltIn: Bool
    let isOff: Bool
}

@MainActor
final class BlackoutModel: ObservableObject {
    static let shared = BlackoutModel()

    @Published private(set) var displays: [DisplayItem] = []
    @Published private(set) var status = "All displays active"
    @Published private(set) var lastError: String?
    @Published private(set) var brightness: [CGDirectDisplayID: Float] = [:]
    @Published private(set) var brightnessKind: [CGDirectDisplayID: BrightnessKind] = [:]
    @Published private(set) var autoOffBuiltIn: Bool

    private var offRecords: [OffRecord] = []
    private var recentlyDisabled: [String: Date] = [:]
    private var observer: NSObjectProtocol?
    private var monitors: [Any] = []
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var refreshWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var lastProbe = ""

    private static let storageKey = "AfterhoursDisconnectedDisplays"
    private static let autoKey = "AfterhoursAutoOffBuiltIn"
    private static let hotKeySignature: OSType = 0x4148_424F  // 'AHBO'

    init() {
        autoOffBuiltIn = UserDefaults.standard.bool(forKey: Self.autoKey)
        // Gamma dimming survives a crash, so start every panel at full output.
        for screen in NSScreen.screens where CGDisplayIsActive(screen.displayID) != 0 {
            _ = Brightness.set(screen.displayID, kind: .gamma, value: 1)
        }
        restoreFromPreviousRun()
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        installEscapeMonitors()
        installHotKey()
        startWatchdog()
        // Apply the saved rule once the app is fully launched.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            Task { @MainActor in self?.applyAutoRule() }
        }
    }

    // MARK: State

    var isAnythingOff: Bool { !offRecords.isEmpty }

    func refresh() {
        let now = Date()
        let activeUUIDs = Set(NSScreen.screens.map { Self.uuid(for: $0.displayID) })
        offRecords.removeAll { record in
            if let stamp = recentlyDisabled[record.uuid],
                now.timeIntervalSince(stamp) < 3
            {
                return false
            }
            // Display IDs are reassigned after a reconnect, so presence is decided by
            // the stable UUID only. A stale ID must never delete a still-disabled record.
            return activeUUIDs.contains(record.uuid)
        }
        recentlyDisabled = recentlyDisabled.filter { now.timeIntervalSince($0.value) < 10 }

        var items: [DisplayItem] = []
        for screen in NSScreen.screens {
            let id = screen.displayID
            let uuid = Self.uuid(for: id)
            guard !offRecords.contains(where: { $0.uuid == uuid }) else { continue }
            items.append(
                DisplayItem(
                    id: id,
                    uuid: uuid,
                    name: screen.localizedName.isEmpty ? "Display \(id)" : screen.localizedName,
                    detail: Self.describe(screen),
                    isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                    isOff: false
                )
            )
        }
        for record in offRecords {
            items.append(
                DisplayItem(
                    id: record.displayID,
                    uuid: record.uuid,
                    name: record.name,
                    detail: record.detail,
                    isBuiltIn: record.isBuiltIn,
                    isOff: true
                )
            )
        }
        displays = items.sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.id < rhs.id
        }
        syncBrightness()
        syncLedger()
        updateStatus()
    }

    /// Keeps the slider values in sync with the hardware, without fighting a drag.
    private func syncBrightness() {
        let activeIDs = Set(displays.filter { !$0.isOff }.map(\.id))
        brightnessKind = brightnessKind.filter { activeIDs.contains($0.key) }
        brightness = brightness.filter { activeIDs.contains($0.key) }
        for id in activeIDs {
            if brightnessKind[id] == .none || brightnessKind[id] == nil {
                brightnessKind[id] = Brightness.kind(for: id)
            }
            if brightness[id] == nil, let kind = brightnessKind[id] {
                brightness[id] = Brightness.current(id, kind: kind)
            }
        }
    }

    /// Re-reads hardware values (e.g. after the F1/F2 keys were used).
    func refreshBrightnessFromHardware() {
        for (id, kind) in brightnessKind where kind == .hardware {
            if let value = DisplayPower.brightness(id) { brightness[id] = value }
        }
    }

    func setBrightness(_ id: CGDirectDisplayID, _ value: Float) {
        let kind = brightnessKind[id] ?? Brightness.kind(for: id)
        brightnessKind[id] = kind
        brightness[id] = value
        Brightness.set(id, kind: kind, value: value)
    }

    func brightnessLabel(for id: CGDirectDisplayID) -> String {
        switch brightnessKind[id] ?? .none {
        case .hardware: return "brightness"
        case .gamma: return "dim (software)"
        case .none: return ""
        }
    }

    func scheduleRefresh(after delay: Double = 0.35) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.handleDisplaysChanged() }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handleDisplaysChanged() {
        // Emergency: never leave the Mac without a single active display.
        if DisplayPower.activeCount() == 0, !offRecords.isEmpty {
            restoreAll(userInitiated: false)
            lastError = "External display disappeared — restored every display automatically."
            return
        }
        log(
            "displaysChanged: screens=\(NSScreen.screens.count) active=\(DisplayPower.activeCount()) off=\(offRecords.map(\.name))"
        )
        refresh()
        ensureBuiltInVisibleIfAlone()
        applyAutoRule()
    }

    /// Safety rule, independent of the automation switch: never leave the user
    /// with a dark laptop panel when the last external display goes away.
    private func ensureBuiltInVisibleIfAlone() {
        guard let record = offRecords.first(where: { $0.isBuiltIn }) else { return }
        let externals = displays.filter { !$0.isBuiltIn && !$0.isOff }
        guard externals.isEmpty else { return }
        restore(id: record.displayID, userInitiated: false)
        lastError = "External display gone — built-in display turned back on."
    }

    /// Remembers "built-in off while an external screen is attached" and re-applies it
    /// when the external screen comes back after being unplugged.
    private func applyAutoRule() {
        guard autoOffBuiltIn else { return }
        guard let builtIn = displays.first(where: { $0.isBuiltIn }) else { return }
        let externals = displays.filter { !$0.isBuiltIn && !$0.isOff }
        if externals.isEmpty {
            if builtIn.isOff {
                restore(id: builtIn.id, userInitiated: false)
                lastError = "External display removed — built-in display restored."
            }
        } else if !builtIn.isOff {
            turnOff(builtIn, userInitiated: false)
        }
    }

    // MARK: Watchdog

    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
    }

    private func watchdogTick() {
        var builtInActive = false
        for raw in UInt32(1)...UInt32(32) {
            let id = CGDirectDisplayID(raw)
            if CGDisplayIsBuiltin(id) != 0, CGDisplayIsActive(id) == 1 {
                builtInActive = true
                break
            }
        }
        guard !builtInActive else { return }

        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        var onlineBuffer = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &onlineBuffer, &onlineCount)
        let online = Array(onlineBuffer.prefix(Int(onlineCount))).sorted()

        var activeCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &activeCount)
        var activeBuffer = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &activeBuffer, &activeCount)
        let active = Array(activeBuffer.prefix(Int(activeCount))).sorted()

        let externals = DisplayPresence.connectedExternalCount()
        let onlineExternal = online.contains { CGDisplayIsBuiltin($0) == 0 }

        let signature = "ext=\(externals) online=\(online) active=\(active)"
        if signature != lastProbe {
            log("probe \(signature)")
            lastProbe = signature
        }

        // Cable pulled: no external panel online anymore (CG may still list a phantom).
        guard externals <= 0 || !onlineExternal else { return }
        log("watchdog: external gone (ext=\(externals) online=\(online)) -> enabling built-in")
        _ = DisplayPower.enableBuiltInByScan()
        DisplayPower.makeBuiltInVisible()
        offRecords.removeAll { $0.isBuiltIn }
        syncLedger()
        refresh()
        lastError = "External display unplugged — built-in display turned back on."
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data("[\(stamp)] \(message)\n".utf8)
        let url = URL(fileURLWithPath: "/tmp/afterhours-blackout.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    func setAutoOff(_ on: Bool) {
        guard on != autoOffBuiltIn else { return }
        autoOffBuiltIn = on
        UserDefaults.standard.set(on, forKey: Self.autoKey)
        if on { applyAutoRule() }
    }

    // MARK: Actions

    func toggle(_ item: DisplayItem) {
        item.isOff ? restore(id: item.id) : turnOff(item)
    }

    func turnOff(_ item: DisplayItem, userInitiated: Bool = true) {
        guard DisplayPower.canDisconnect else {
            lastError = "This macOS build no longer exposes the disconnect API."
            return
        }
        guard !item.isOff else { return }
        guard DisplayPower.activeCount() > 1 else {
            lastError = "\(item.name) is the last active display — refusing to turn it off."
            return
        }
        let record = OffRecord(
            id: item.id, uuid: item.uuid, name: item.name, isBuiltIn: item.isBuiltIn,
            detail: item.detail)
        guard DisplayPower.setEnabled(item.id, false) else {
            lastError = "Could not disconnect \(item.name)."
            return
        }
        lastError = nil
        recentlyDisabled[item.uuid] = Date()
        if !offRecords.contains(where: { $0.uuid == item.uuid }) {
            offRecords.append(record)
        }
        // Turning the laptop panel off with a monitor attached becomes the auto rule.
        if userInitiated, item.isBuiltIn,
            displays.contains(where: { !$0.isBuiltIn && !$0.isOff })
        {
            autoOffBuiltIn = true
            UserDefaults.standard.set(true, forKey: Self.autoKey)
        }
        syncLedger()
        updateStatus()
        scheduleRefresh()
    }

    func restore(id: CGDirectDisplayID, userInitiated: Bool = true) {
        let uuid = Self.uuid(for: id)
        guard
            let record = offRecords.first(where: { $0.displayID == id || $0.uuid == uuid })
        else { return }
        var restored = DisplayPower.setEnabled(record.displayID, true)
        if !restored, id != record.displayID { restored = DisplayPower.setEnabled(id, true) }
        if !restored, record.isBuiltIn { restored = DisplayPower.enableBuiltInByScan() }
        if restored, record.isBuiltIn { DisplayPower.makeBuiltInVisible() }
        guard restored else {
            lastError = "Could not reconnect \(record.name)."
            return
        }
        lastError = nil
        offRecords.removeAll { $0.displayID == id || $0.uuid == record.uuid }
        recentlyDisabled[record.uuid] = nil
        if userInitiated, record.isBuiltIn {
            autoOffBuiltIn = false
            UserDefaults.standard.set(false, forKey: Self.autoKey)
        }
        syncLedger()
        updateStatus()
        refreshBurst()
    }

    func restoreAll(userInitiated: Bool = true) {
        let pending = offRecords
        for record in pending { _ = DisplayPower.setEnabled(record.displayID, true) }
        offRecords.removeAll()
        recentlyDisabled.removeAll()
        lastError = nil
        if userInitiated {
            autoOffBuiltIn = false
            UserDefaults.standard.set(false, forKey: Self.autoKey)
        }
        syncLedger()
        updateStatus()
        refreshBurst()
    }

    /// WindowServer re-adds a reconnected display asynchronously, so poll a few times.
    private func refreshBurst() {
        for delay in [0.8, 2.0, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in
                    self?.refresh()
                    self?.ensureBuiltInVisibleIfAlone()
                    self?.applyAutoRule()
                }
            }
        }
    }

    /// Most common case: laptop panel off while an external monitor is attached.
    func toggleBuiltIn() {
        if let off = displays.first(where: { $0.isBuiltIn && $0.isOff }) {
            restore(id: off.id)
        } else if let builtIn = displays.first(where: { $0.isBuiltIn }) {
            turnOff(builtIn)
        } else {
            lastError = "No built-in display found."
        }
    }

    // MARK: Lifecycle

    func shutdown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKeyHandler = nil
        watchdog?.invalidate()
        watchdog = nil
        resetSoftwareDimming()
        restoreAll(userInitiated: false)
    }

    /// Gamma dimming outlives the process, so always put the panels back to normal.
    private func resetSoftwareDimming() {
        for (id, kind) in brightnessKind where kind == .gamma {
            _ = Brightness.set(id, kind: .gamma, value: 1)
        }
    }

    // MARK: Persistence / crash recovery

    private func syncLedger() {
        DisconnectLedger.ids = offRecords.map(\.displayID)
        let encoded = try? JSONEncoder().encode(offRecords)
        UserDefaults.standard.set(encoded, forKey: Self.storageKey)
    }

    private func restoreFromPreviousRun() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let records = try? JSONDecoder().decode([OffRecord].self, from: data),
            !records.isEmpty
        else { return }
        for record in records { _ = DisplayPower.setEnabled(record.displayID, true) }
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        log("startup: re-enabled \(records.count) display(s) left off by a previous run")
    }

    // MARK: Status text

    private func updateStatus() {
        guard !offRecords.isEmpty else {
            status = "All displays active"
            return
        }
        let names = offRecords.map(\.name).joined(separator: ", ")
        status = "\(names) disconnected"
    }

    static func uuid(for id: CGDirectDisplayID) -> String {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            return "id-\(id)"
        }
        return CFUUIDCreateString(nil, cf) as String
    }

    private static func describe(_ screen: NSScreen) -> String {
        let id = screen.displayID
        let width = Int(screen.frame.width)
        let height = Int(screen.frame.height)
        var parts = ["\(width)×\(height)"]
        if let mode = CGDisplayCopyDisplayMode(id) {
            if mode.pixelWidth != width || mode.pixelHeight != height {
                parts.append("\(mode.pixelWidth)×\(mode.pixelHeight)px")
            }
            if mode.refreshRate > 0 { parts.append("\(Int(mode.refreshRate.rounded()))Hz") }
        }
        if CGDisplayIsMain(id) != 0 { parts.append("main") }
        return parts.joined(separator: " · ")
    }

    // MARK: Input

    private func installEscapeMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.restoreAll() }
            return nil
        }) {
            monitors.append(local)
        }
        // Best effort only: global key events need Accessibility permission.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.restoreAll() }
        }) {
            monitors.append(global)
        }
    }

    private func installHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let size = MemoryLayout<EventHotKeyID>.size
                guard
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil, size, nil, &hotKeyID) == noErr
                else { return OSStatus(eventNotHandledErr) }
                let model = Unmanaged<BlackoutModel>.fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in model.restoreAll() }
                return noErr
            },
            1, &eventType, context, &hotKeyHandler
        )
        guard installStatus == noErr else {
            lastError = "Could not install the global restore hotkey."
            return
        }
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_6), UInt32(controlKey | cmdKey), hotKeyID,
            GetApplicationEventTarget(), 0, &hotKey)
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = BlackoutModel.shared
        let hosting = NSHostingController(
            rootView: MenuBarView(model: model).fixedSize(horizontal: false, vertical: true)
        )
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "moon.stars", accessibilityDescription: "Afterhours displays"
            )
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        let model = BlackoutModel.shared
        model.refresh()
        model.refreshBrightnessFromHardware()
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            popover.contentSize = NSSize(width: 300, height: ceil(size.height))
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func applicationWillTerminate(_ notification: Notification) {
        DisconnectLedger.restoreAll()
    }
}

@main
struct AfterhoursApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() {
        if CommandLine.arguments.contains("--snapshot") {
            Task { @MainActor in Snapshot.run() }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.run()
            exit(0)
        }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
enum Snapshot {
    static func run() {
        let model = BlackoutModel.shared
        model.refresh()
        let hosting = NSHostingView(rootView: MenuBarView(model: model))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 120, y: 120))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/afterhours-panel.png"))
                print("wrote /tmp/afterhours-panel.png size=\(hosting.bounds.size)")
            }
        }
        exit(0)
    }
}

enum SelfTest {
    static func run() {
        print("canDisconnect=\(DisplayPower.canDisconnect)")
        print("--- brightness")
        for screen in NSScreen.screens {
            let id = screen.displayID
            let kind = Brightness.kind(for: id)
            let before = Brightness.current(id, kind: kind)
            let ok = Brightness.set(id, kind: kind, value: 0.35)
            Thread.sleep(forTimeInterval: 0.5)
            let after = Brightness.current(id, kind: kind)
            Brightness.set(id, kind: kind, value: before)
            print(
                "id=\(id) name=\(screen.localizedName) kind=\(kind) before=\(before) set=\(ok) after=\(after)"
            )
        }
        guard
            let builtIn = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 })
        else {
            print("no built-in display")
            return
        }
        let id = builtIn.displayID
        print("--- disconnect")
        print("builtin=\(id) activeBefore=\(DisplayPower.activeCount())")
        print("disconnect=\(DisplayPower.setEnabled(id, false))")
        Thread.sleep(forTimeInterval: 1.5)
        print(
            "after: active=\(DisplayPower.activeCount()) isActive=\(CGDisplayIsActive(id)) screens=\(NSScreen.screens.count)"
        )
        print("reconnect=\(DisplayPower.setEnabled(id, true))")
        Thread.sleep(forTimeInterval: 2.5)
        print(
            "final: active=\(DisplayPower.activeCount()) isActive=\(CGDisplayIsActive(id)) screens=\(NSScreen.screens.count)"
        )
    }
}

// MARK: - UI

struct MenuBarView: View {
    @ObservedObject var model: BlackoutModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            actions
        }
        .frame(width: 300)
        .onAppear {
            model.refresh()
            model.refreshBrightnessFromHardware()
        }
        .onExitCommand { model.restoreAll() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: model.isAnythingOff ? "moon.zzz.fill" : "moon.stars.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("Afterhours")
                    .font(.headline)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Text("\(model.displays.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var list: some View {
        VStack(spacing: 8) {
            ForEach(model.displays) { display in
                DisplayRow(display: display, model: model) { model.toggle(display) }
            }
        }
        .padding(14)
    }

    private var actions: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Button("Restore All") { model.restoreAll() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("Built-in") { model.toggleBuiltIn() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer(minLength: 0)

                Button("Quit") {
                    model.shutdown()
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Toggle(
                "Turn off built-in with external display",
                isOn: Binding(
                    get: { model.autoOffBuiltIn },
                    set: { model.setAutoOff($0) })
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
        }
        .padding(14)
    }
}

struct DisplayRow: View {
    let display: DisplayItem
    @ObservedObject var model: BlackoutModel
    let action: () -> Void

    private var level: Binding<Double> {
        Binding(
            get: { Double(model.brightness[display.id] ?? 1) },
            set: { model.setBrightness(display.id, Float($0)) }
        )
    }

    private var modeLabel: String {
        model.brightnessKind[display.id] == .gamma ? "software dim" : "hardware brightness"
    }

    private var statusLabel: String {
        display.isOff ? "Disconnected" : "Active · \(modeLabel)"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(
                    systemName: display.isOff
                        ? "powersleep" : (display.isBuiltIn ? "laptopcomputer" : "display")
                )
                .font(.body)
                .foregroundStyle(display.isOff ? .secondary : .primary)
                .frame(width: 20, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(display.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if display.isBuiltIn {
                            Text("Built-in")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(display.detail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(statusLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Toggle(
                    "Display \(display.name)",
                    isOn: Binding(get: { !display.isOff }, set: { _ in action() })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if !display.isOff {
                HStack(spacing: 6) {
                    Image(systemName: "sun.min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: level, in: 0...1)
                        .controlSize(.mini)
                    Image(systemName: "sun.max.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(Int((model.brightness[display.id] ?? 1) * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

    }
}
