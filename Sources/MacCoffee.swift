import SwiftUI
import Combine
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement

@main
enum MacCoffeeMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarItem: MenuBarItem?
    private var terminateSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarItem = MenuBarItem(model: AwakeModel.shared)

        // `kill` skips applicationWillTerminate, so clean up on SIGTERM too.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            AwakeModel.shared.prepareForQuit()
            exit(0)
        }
        source.resume()
        terminateSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the Mac unable to sleep after MacCoffee is gone (logout, restart, quit).
        AwakeModel.shared.prepareForQuit()
    }
}

// MARK: - Menu bar item

/// The menu bar icon and its panel, in plain AppKit.
@MainActor
final class MenuBarItem: NSObject {
    private let model: AwakeModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let steam = SteamView(frame: NSRect(origin: .zero, size: CupIcon.size))
    private let panel = MenuPanel()
    private var modelChanges: AnyCancellable?

    init(model: AwakeModel) {
        self.model = model
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.toolTip = "MacCoffee"
            // The steam sits exactly over the button's image, so it lines up with the cup.
            steam.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(steam)
            NSLayoutConstraint.activate([
                steam.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                steam.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                steam.widthAnchor.constraint(equalToConstant: CupIcon.size.width),
                steam.heightAnchor.constraint(equalToConstant: CupIcon.size.height),
            ])
        }
        panel.onClose = { [weak self] in self?.item.button?.highlight(false) }

        // objectWillChange fires just before the new value is stored.
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        // Tells us when the menu bar is hidden (full-screen app) or the display sleeps.
        NotificationCenter.default.addObserver(self, selector: #selector(updateIcon),
                                               name: NSWindow.didChangeOcclusionStateNotification,
                                               object: item.button?.window)
        updateIcon()
    }

    @objc private func updateIcon() {
        guard let button = item.button else { return }
        button.image = model.isActive ? CupIcon.filled : CupIcon.outline
        // The steam only moves while someone can see it: not with the lid shut, not while
        // the menu bar is hidden or the display is off.
        let visible = button.window?.occlusionState.contains(.visible) ?? false
        steam.show(model.lidClosedMode, moving: !model.lidClosed && visible)
    }

    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if panel.isVisible {
            panel.close()
            return
        }
        panel.show(MenuView(model: model), below: button)
        // The click un-highlights the icon once it ends, so highlight it after that.
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isVisible else { return }
            button.highlight(true)
        }
    }
}

/// The panel under the menu bar icon. Like a menu, it takes the keyboard without making
/// MacCoffee the active app, so its switches show as active, and it closes when you click
/// anywhere else or press Esc. (A popover can do neither: clicking a menu bar icon doesn't
/// activate its app.)
@MainActor
final class MenuPanel: NSPanel {
    var onClose: (() -> Void)?
    private var outsideClicks: Any?
    private var sizeChanges: NSObjectProtocol?
    private var closing = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }

    func show(_ content: some View, below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 10)
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
        ])
        contentView = background

        // Just below the menu bar, left edge under the icon like a menu, kept on screen.
        let icon = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? icon
        let size = host.fittingSize
        let x = min(max(icon.minX, screen.minX + 6), screen.maxX - size.width - 6)
        let top = buttonWindow.frame.minY - 2
        setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)

        // When a line of text wraps or unwraps, grow or shrink downwards, keeping the top in place.
        host.postsFrameChangedNotifications = true
        sizeChanges = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                             object: host, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit(to: host.frame.size) }
        }
        // Clicks in other apps, including their menu bar icons, close it like a menu.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        makeKeyAndOrderFront(nil)
        invalidateShadow()
    }

    private func fit(to size: NSSize) {
        guard size != frame.size else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        invalidateShadow()
    }

    override func close() {
        guard isVisible, !closing else { return }
        closing = true
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let sizeChanges { NotificationCenter.default.removeObserver(sizeChanges) }
        outsideClicks = nil
        sizeChanges = nil
        orderOut(nil)
        contentView = nil // the panel's views only exist while it's open
        closing = false
        onClose?()
    }

    // Focus moving to another window or app closes it too.
    override func resignKey() {
        super.resignKey()
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        return mask
    }
}

// MARK: - Model

@MainActor
final class AwakeModel: ObservableObject {
    static let shared = AwakeModel()

    // Everything starts off on every launch; only the safety setting is remembered.
    // These four only apply while the lid is open.
    @Published var preventSleep = false { didSet { applyAssertions() } }
    @Published var keepDisplayOn = false { didSet { applyAssertions() } }
    @Published var preventLock = false { didSet { applyAssertions() } }
    @Published var keepKeyboardLight = false { didSet { applyAssertions() } }
    /// In lid-closed mode: keep the screen on at minimum brightness instead of turning it off.
    @Published var keepScreenOnWhenClosed = false { didSet { applyAssertions() } }
    @Published var lowBatteryCutoff: Bool { didSet { UserDefaults.standard.set(lowBatteryCutoff, forKey: "lowBatteryCutoff") } }
    @Published private(set) var lidClosedMode = false { didSet { applyAssertions() } }
    @Published private(set) var lidClosed = false

    /// Minutes until everything turns off; 0 means no timer.
    @Published var timerMinutes = 0 {
        didSet { offAt = timerMinutes > 0 ? Date().addingTimeInterval(Double(timerMinutes) * 60) : nil }
    }
    @Published private(set) var offAt: Date? { didSet { scheduleOffTimer() } }

    static let timerChoices = [15, 30, 60, 120, 180, 240, 360, 480, 720]
    static let lowBatteryLevel = 10

    var isActive: Bool {
        preventSleep || keepDisplayOn || preventLock || keepKeyboardLight || lidClosedMode || keepScreenOnWhenClosed
    }

    private var systemAssertion = IOPMAssertionID(0)
    private var displayAssertion = IOPMAssertionID(0)
    private var activityAssertion = IOPMAssertionID(0)
    private var activityTimer: Timer?
    private var offTimer: Timer?
    private var keyboardLightHeld = false

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["lowBatteryCutoff": true])
        lowBatteryCutoff = defaults.bool(forKey: "lowBatteryCutoff")

        // Everything starts off. The one exception: relaunching with the lid shut must not
        // put a Mac to sleep that lid-closed mode is deliberately keeping awake.
        lidClosed = Lid.isClosed
        if lidClosed { lidClosedMode = LidSleep.isDisabled } else { restoreNormalSleep(askForPassword: false) }
        KeyboardLight.keepOn(false) // in case MacCoffee didn't get to undo it last time

        // No polling: macOS tells us about the lid, the battery and waking up.
        Lid.observe { MainActor.assumeIsolated { AwakeModel.shared.updateLidState() } }
        Battery.observe { MainActor.assumeIsolated { AwakeModel.shared.checkBattery() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { _ in
            // Timers don't run while the Mac sleeps, so catch up after waking.
            MainActor.assumeIsolated {
                let model = AwakeModel.shared
                model.updateLidState()
                model.checkOffTime()
                model.checkBattery()
            }
        }
    }

    /// Lid-closed mode needs root (`pmset disablesleep`), so the switch flips right away
    /// and the real state is read back once the change has gone through.
    var lidClosedSetting: Bool {
        get { lidClosedMode }
        set {
            lidClosedMode = newValue
            DispatchQueue.main.async { [self] in
                LidSleep.set(disabled: newValue, askForPassword: true)
                lidClosedMode = LidSleep.isDisabled
            }
        }
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("MacCoffee: open at login failed: \(error)")
            }
            objectWillChange.send()
        }
    }

    /// Picks up changes made outside the app, e.g. `sudo pmset -a disablesleep 0` in Terminal.
    func refresh() {
        lidClosedMode = LidSleep.isDisabled
        objectWillChange.send()
    }

    func turnEverythingOn() {
        preventSleep = true
        keepDisplayOn = true
        preventLock = true
        keepKeyboardLight = true
        keepScreenOnWhenClosed = true
        if !lidClosedMode { lidClosedSetting = true }
    }

    func turnEverythingOff(askForPassword: Bool) {
        preventSleep = false
        keepDisplayOn = false
        preventLock = false
        keepKeyboardLight = false
        keepScreenOnWhenClosed = false
        timerMinutes = 0
        restoreNormalSleep(askForPassword: askForPassword)
    }

    func restoreNormalSleep(askForPassword: Bool) {
        if LidSleep.isDisabled { LidSleep.set(disabled: false, askForPassword: askForPassword) }
        lidClosedMode = LidSleep.isDisabled
    }

    func prepareForQuit() {
        KeyboardLight.keepOn(false)
        ScreenBrightness.restoreAfterLidOpened()
        restoreNormalSleep(askForPassword: false)
    }

    private func scheduleOffTimer() {
        offTimer?.invalidate()
        offTimer = nil
        guard let offAt else { return }
        let timer = Timer(fire: offAt, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { AwakeModel.shared.checkOffTime() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        offTimer = timer
    }

    private func checkOffTime() {
        if let offAt, Date() >= offAt { turnEverythingOff(askForPassword: false) }
    }

    private func checkBattery() {
        guard lowBatteryCutoff, isActive,
              let level = Battery.levelIfDischarging, level <= Self.lowBatteryLevel else { return }
        turnEverythingOff(askForPassword: false)
    }

    private func updateLidState() {
        let closed = Lid.isClosed
        guard closed != lidClosed else { return }
        lidClosed = closed
        applyAssertions()
        if !closed {
            KeyboardLight.restoreAfterLidOpened()
            ScreenBrightness.restoreAfterLidOpened()
        } else if lidClosedMode {
            // Nothing needs the keyboard light with the lid shut, and the screen only when asked
            // for, so save the battery.
            KeyboardLight.turnOffForClosedLid()
            if keepScreenOnWhenClosed {
                ScreenBrightness.dimForClosedLid()
            } else {
                run("/usr/bin/pmset", "displaysleepnow")
            }
        }
    }

    // MARK: Power assertions

    private func applyAssertions() {
        let lidOpen = !lidClosed
        let screenOnBehindLid = lidClosed && lidClosedMode && keepScreenOnWhenClosed
        hold(&systemAssertion, type: "PreventUserIdleSystemSleep", name: "MacCoffee: Prevent Sleep",
             on: preventSleep && lidOpen)
        hold(&displayAssertion, type: "PreventUserIdleDisplaySleep", name: "MacCoffee: Keep Display On",
             on: ((keepDisplayOn || preventLock) && lidOpen) || screenOnBehindLid)

        // The screen locks when the screen saver starts or the display sleeps, and macOS turns
        // the screen off soon after the lid closes, so keep telling it the user is active.
        let declareActivity = (preventLock && lidOpen) || screenOnBehindLid
        if declareActivity, activityTimer == nil {
            declareUserActivity()
            let timer = Timer(timeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { AwakeModel.shared.declareUserActivity() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            activityTimer = timer
        } else if !declareActivity, let timer = activityTimer {
            timer.invalidate()
            activityTimer = nil
            IOPMAssertionRelease(activityAssertion)
            activityAssertion = 0
        }

        let keyboardOn = keepKeyboardLight && lidOpen
        if keyboardOn != keyboardLightHeld {
            KeyboardLight.keepOn(keyboardOn)
            keyboardLightHeld = keyboardOn
        }
    }

    private func hold(_ id: inout IOPMAssertionID, type: String, name: String, on: Bool) {
        if on, id == 0 {
            IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        } else if !on, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }

    private func declareUserActivity() {
        IOPMAssertionDeclareUserActivity("MacCoffee: Prevent Screen Lock" as CFString, kIOPMUserActiveLocal, &activityAssertion)
    }
}

// MARK: - Lid

enum Lid {
    private static let clamshellStateChange: UInt32 = 0xE0034100 // kIOPMMessageClamshellStateChange
    private static var onChange: (() -> Void)?
    private static var notifier: io_object_t = 0

    static var isClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    /// Calls `handler` on the main queue when the lid opens or closes.
    static func observe(_ handler: @escaping () -> Void) {
        onChange = handler
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { _, _, messageType, _ in
            if messageType == Lid.clamshellStateChange { Lid.onChange?() }
        }, nil, &notifier)
    }
}

// MARK: - Keyboard backlight

/// The built-in keyboard backlight, through CoreBrightness's KeyboardBrightnessClient
/// (a private framework; it's what Control Center uses).
@MainActor
enum KeyboardLight {
    private static let client: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }()
    private static let keyboardID: UInt64? = {
        let ids = client?.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeUnretainedValue() as? [NSNumber]
        return ids?.first?.uint64Value
    }()
    private static var levelBeforeLidClosed: Float?

    /// Stops the light from turning off after inactivity. This setting is system-wide and
    /// outlives the app, so MacCoffee always undoes it when quitting.
    static func keepOn(_ on: Bool) {
        typealias Fn = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
        guard let m = method("suspendIdleDimming:forKeyboard:", as: Fn.self) else { return }
        _ = m.fn(m.client, m.sel, on, m.id)
    }

    /// macOS normally darkens the keyboard by itself when the lid closes; this makes sure of it.
    static func turnOffForClosedLid() {
        typealias GetBool = @convention(c) (AnyObject, Selector, UInt64) -> Bool
        typealias GetFloat = @convention(c) (AnyObject, Selector, UInt64) -> Float
        guard let suppressed = method("isBacklightSuppressedOnKeyboard:", as: GetBool.self),
              let brightness = method("brightnessForKeyboard:", as: GetFloat.self),
              !suppressed.fn(suppressed.client, suppressed.sel, suppressed.id) else { return }
        let level = brightness.fn(brightness.client, brightness.sel, brightness.id)
        guard level > 0 else { return }
        levelBeforeLidClosed = level
        setBrightness(0)
    }

    static func restoreAfterLidOpened() {
        guard let level = levelBeforeLidClosed else { return }
        levelBeforeLidClosed = nil
        setBrightness(level)
    }

    private static func setBrightness(_ level: Float) {
        typealias Fn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        guard let m = method("setBrightness:forKeyboard:", as: Fn.self) else { return }
        _ = m.fn(m.client, m.sel, level, m.id)
    }

    private static func method<F>(_ name: String, as type: F.Type) -> (client: NSObject, id: UInt64, sel: Selector, fn: F)? {
        let sel = NSSelectorFromString(name)
        guard let client, let keyboardID, client.responds(to: sel) else { return nil }
        return (client, keyboardID, sel, unsafeBitCast(client.method(for: sel), to: type))
    }
}

// MARK: - Screen brightness

/// The built-in screen's brightness, through DisplayServices: a private framework, as macOS has
/// no public brightness API for Apple silicon (it's what the brightness keys use).
@MainActor
enum ScreenBrightness {
    /// The lowest step of the brightness keys: as dim as it gets while surely staying lit.
    static let minimum: Float = 1 / 16

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let get = dlsym(framework, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
    private static let set = dlsym(framework, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
    private static var levelBeforeLidClosed: Float?

    static func dimForClosedLid() {
        guard let display = builtInDisplay, let get, let set else { return }
        var level: Float = 0
        guard get(display, &level) == 0, level > minimum else { return }
        levelBeforeLidClosed = level
        _ = set(display, minimum)
    }

    static func restoreAfterLidOpened() {
        guard let level = levelBeforeLidClosed, let display = builtInDisplay, let set else { return }
        levelBeforeLidClosed = nil
        _ = set(display, level)
    }

    private static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

// MARK: - Lid closed (pmset disablesleep)

enum LidSleep {
    static let sudoersFile = "/etc/sudoers.d/maccoffee"

    static var isDisabled: Bool {
        run("/usr/bin/pmset", "-g").output.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count >= 2 && parts[0] == "SleepDisabled" && parts[1] == "1"
        }
    }

    /// Tries without a password first. If that isn't allowed yet, asks for the admin password once
    /// and installs a sudoers rule that permits exactly `pmset -a disablesleep 0|1`, nothing else.
    @discardableResult
    static func set(disabled: Bool, askForPassword: Bool) -> Bool {
        let value = disabled ? "1" : "0"
        if run("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", value).status == 0 { return true }
        guard askForPassword else { return false }

        var error: NSDictionary?
        NSAppleScript(source: adminAppleScript(value: value))?.executeAndReturnError(&error)
        return error == nil
    }

    static func adminAppleScript(value: String) -> String {
        var script = "/usr/bin/pmset -a disablesleep \(value)"
        let user = NSUserName()
        if user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil {
            let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
            script = "f=$(/usr/bin/mktemp) && echo '\(rule)' > \"$f\" && /usr/sbin/visudo -c -q -f \"$f\""
                + " && /usr/bin/install -m 0440 -o root -g wheel \"$f\" \(sudoersFile); /bin/rm -f \"$f\"; " + script
        }
        let prompt = "MacCoffee wants to change a power setting so your Mac stays awake with the lid closed. You'll only be asked once."
        return "do shell script \"\(escaped(script))\" with prompt \"\(escaped(prompt))\" with administrator privileges"
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

@discardableResult
private func run(_ path: String, _ args: String...) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

// MARK: - Battery

enum Battery {
    private static var onChange: (() -> Void)?

    /// Charge in percent while running on battery; nil when plugged in.
    static var levelIfDischarging: Int? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return current * 100 / max
        }
        return nil
    }

    /// Calls `handler` on the main thread whenever the charge or the power source changes.
    static func observe(_ handler: @escaping () -> Void) {
        onChange = handler
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in Battery.onChange?() }, nil)?
            .takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
}

// MARK: - Icons

/// The steam over the cup in lid-closed mode. Core Animation flips through the ready-made
/// frames by itself, so MacCoffee doesn't wake up at all while the steam moves.
final class SteamView: NSView {
    private let steam = CALayer()
    private var shown = false
    private var moving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer() // layer-hosting: AppKit never draws over the frames
        wantsLayer = true
        steam.frame = bounds
        layer?.addSublayer(steam)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the button

    // The menu bar turns light or dark with the wallpaper.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    func show(_ shown: Bool, moving: Bool) {
        guard shown != self.shown || moving != self.moving else { return }
        self.shown = shown
        self.moving = moving
        apply()
    }

    private func apply() {
        let dark = [.darkAqua, .vibrantDark].contains(
            effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]))
        let frames = dark ? CupIcon.darkSteam : CupIcon.lightSteam
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        steam.removeAnimation(forKey: "steam")
        steam.contents = shown ? frames.first : nil
        if shown, moving, !frames.isEmpty {
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = frames
            animation.keyTimes = (0...frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
            animation.calculationMode = .discrete
            animation.duration = 0.15 * Double(frames.count)
            animation.repeatCount = .infinity
            steam.add(animation, forKey: "steam")
        }
        CATransaction.commit()
    }
}

/// The menu bar icons, drawn once at launch. Every version shares one canvas with the cup in
/// the same place, and the steam is only ever added above it: the cup never moves or resizes.
enum CupIcon {
    static let size = NSSize(width: 18, height: 22)
    static let outline = template(drawingCup("cup.and.saucer"))
    static let filled = template(drawingCup("cup.and.saucer.fill"))
    /// Steam frames to lay over `filled`: white for a dark menu bar, black for a light one.
    static let darkSteam = steamFrames(color: .white)
    static let lightSteam = steamFrames(color: .black)

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }

    /// Where a plain 13 pt symbol sits when centered in the menu bar.
    private static func cupRect(_ cup: NSImage) -> NSRect {
        NSRect(x: (size.width - cup.size.width) / 2, y: (size.height - cup.size.height) / 2,
               width: cup.size.width, height: cup.size.height)
    }

    private static func drawingCup(_ name: String) -> NSBitmapImageRep {
        render {
            if let cup = symbol(name) { cup.draw(in: cupRect(cup)) }
        }
    }

    private static func template(_ rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    private static func steamFrames(color: NSColor) -> [CGImage] {
        guard let cup = symbol("cup.and.saucer.fill") else { return [] }
        let rect = cupRect(cup)
        let cupTop = rect.minY + cup.alignmentRect.maxY
        let centerX = rect.minX + cup.alignmentRect.width * 0.42 // over the cup, not the handle
        return (0..<12).compactMap { frame in
            render {
                // Three wisps, each rising and fading in turn.
                for wisp in 0..<3 {
                    let p = (Double(frame) / 12 + Double(wisp) / 3).truncatingRemainder(dividingBy: 1)
                    let bottom = cupTop + 0.9 + p * 1.5
                    let length = 4.2 - p * 0.9
                    let path = NSBezierPath()
                    for step in 0...20 {
                        let t = Double(step) / 20
                        let x = centerX + Double(wisp - 1) * 3.6 + 0.6 * sin(2 * .pi * (t * 0.6 + p * 0.5))
                        let point = NSPoint(x: x, y: bottom + t * length)
                        if step == 0 { path.move(to: point) } else { path.line(to: point) }
                    }
                    path.lineWidth = 1.2
                    path.lineCapStyle = .round
                    path.lineJoinStyle = .round
                    color.withAlphaComponent(sin(p * .pi)).setStroke()
                    path.stroke()
                }
            }.cgImage
        }
    }

    /// Draws straight into a Retina bitmap, so showing an icon later runs no drawing code.
    private static func render(_ draw: () -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

// MARK: - UI

struct MenuView: View {
    @ObservedObject var model: AwakeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("MacCoffee").font(.system(size: 13, weight: .semibold))
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Text(model.isActive ? "On" : "Off").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)

            // Never greyed out: next to a greyed one, the other button looks like the current state.
            HStack(spacing: 8) {
                Button { model.turnEverythingOn() } label: {
                    Text("Turn All On").frame(maxWidth: .infinity)
                }
                Button { model.turnEverythingOff(askForPassword: true) } label: {
                    Text("Turn All Off").frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)

            SectionHeader(title: "While the Lid Is Open")
            SettingRow(icon: "moon.zzz.fill", title: "Prevent Sleep",
                       detail: "Mac stays awake when idle", isOn: $model.preventSleep)
            SettingRow(icon: "sun.max.fill", title: "Keep Display On",
                       detail: "Screen won't dim or turn off", isOn: $model.keepDisplayOn)
            SettingRow(icon: "lock.open.fill", title: "Prevent Screen Lock",
                       detail: "No screen saver or idle lock", isOn: $model.preventLock)
            SettingRow(icon: "keyboard", title: "Keep Keyboard Light On",
                       detail: "Backlight won't turn off when idle", isOn: $model.keepKeyboardLight)

            Divider().padding(.vertical, 6)

            SectionHeader(title: "While the Lid Is Closed")
            SettingRow(icon: "laptopcomputer", title: "Stay Awake",
                       detail: "Keeps running. Keyboard light turns off to save battery.",
                       isOn: $model.lidClosedSetting)
            SettingRow(icon: "sun.min.fill", title: "Keep Screen On",
                       detail: model.keepScreenOnWhenClosed ? "Stays on at minimum brightness" : "Turns off to save battery",
                       isOn: $model.keepScreenOnWhenClosed)

            Divider().padding(.vertical, 6)

            SettingRow(icon: "timer", title: "Turn Off After",
                       detail: model.offAt.map { "All off at \($0.formatted(date: .omitted, time: .shortened))" }
                           ?? "Stays on until you turn it off",
                       highlighted: model.offAt != nil) {
                Picker("Turn Off After", selection: $model.timerMinutes) {
                    Text("Never").tag(0)
                    Divider()
                    ForEach(AwakeModel.timerChoices, id: \.self) { Text(durationLabel($0)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            SettingRow(icon: "battery.25", title: "Low Battery Safety",
                       detail: "Turns everything off at \(AwakeModel.lowBatteryLevel)%", isOn: $model.lowBatteryCutoff)

            Divider().padding(.vertical, 6)

            HStack {
                Toggle("Open at Login", isOn: $model.openAtLogin)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quit") {
                    model.restoreNormalSleep(askForPassword: true)
                    NSApp.terminate(nil)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
        }
        .padding(10)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
    }
}

struct SettingRow<Accessory: View>: View {
    let icon: String
    let title: String
    let detail: String
    let highlighted: Bool
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(highlighted ? Color.accentColor : Color.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

extension SettingRow where Accessory == SwitchToggle {
    init(icon: String, title: String, detail: String, isOn: Binding<Bool>) {
        self.init(icon: icon, title: title, detail: detail, highlighted: isOn.wrappedValue) {
            SwitchToggle(title: title, isOn: isOn)
        }
    }
}

struct SwitchToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}
