import AppKit

/// Controls only its own status items. Other apps stay running and keep their own menus.
final class MenuBarFolder: NSObject {
    static let expandedWidth: CGFloat = 20
    static func collapsedWidth(screenWidths: [CGFloat]) -> CGFloat {
        max(500, min((screenWidths.max() ?? 1440) * 2, 10_000))
    }
    private let defaults: UserDefaults
    private(set) var boundary: NSStatusItem!
    private(set) var toggleItem: NSStatusItem!
    private(set) var isCollapsed = false
    private var timer: Timer?
    private var idleCountdown = MenuIdleCountdown(now: ProcessInfo.processInfo.systemUptime)
    private var lastInputTimestamp: TimeInterval = 0
    private var lastKeyboardTimestamp: TimeInterval = 0
    private var lastMouseTimestamp: TimeInterval = 0
    private var pointerWasInMenu = false
    private var menuRects: [CGRect] = []
    private var menuRectsUpdated: TimeInterval = 0
    var onChange: (() -> Void)?
    var openSettings: (() -> Void)?
    var warning = ""
    var conflictingTools: [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            let name = app.localizedName ?? ""
            let known = ["ibar", "hidden bar", "dozer", "bartender", "ice", "vanilla"]
            return app.bundleIdentifier == "cn.better365.iBar" || known.contains(name.lowercased()) ? name : nil
        }
    }
    var autoCollapse: Bool {
        get { defaults.bool(forKey: "MenuFolder.autoCollapse") }
        set { defaults.set(newValue, forKey: "MenuFolder.autoCollapse"); schedule(); onChange?() }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // This release enables the requested idle behavior once; later user opt-outs persist.
        if !defaults.bool(forKey: "MenuFolder.idleCountdownV2") {
            defaults.set(true, forKey: "MenuFolder.autoCollapse")
            defaults.set(true, forKey: "MenuFolder.idleCountdownV2")
        }
        super.init()
        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggleItem.autosaveName = "TouchBarStocks.FolderToggle"
        toggleItem.behavior = []
        toggleItem.isVisible = true
        toggleItem.button?.target = self
        toggleItem.button?.action = #selector(clicked)
        toggleItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        toggleItem.button?.setAccessibilityLabel("展开或折叠菜单栏图标")
        boundary = NSStatusBar.system.statusItem(withLength: Self.expandedWidth)
        boundary.autosaveName = "TouchBarStocks.FolderBoundary"
        boundary.behavior = []
        boundary.isVisible = true
        boundary.button?.title = "│"
        boundary.button?.toolTip = "按住 ⌘ 拖动：左侧图标参与折叠，右侧图标始终显示"
        boundary.button?.setAccessibilityLabel("菜单栏折叠区域分隔线")
        boundary.button?.target = self
        boundary.button?.action = #selector(configure)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(otherAppsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(otherAppsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        updateAppearance()
        // Start expanded; users can arrange the boundary before the first idle timeout.
        schedule()
    }
    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func otherAppsChanged() {
        if !conflictingTools.isEmpty && isCollapsed { expand() }
        if timer == nil && autoCollapse && !isCollapsed && conflictingTools.isEmpty { schedule() }
        onChange?()
    }
    @objc private func configure() { expand(); openSettings?() }
    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            for (title, action) in [(isCollapsed ? "展开图标" : "折叠图标", #selector(toggle)), ("菜单栏折叠设置", #selector(configure))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            toggleItem.menu = menu
            toggleItem.button?.performClick(nil)
            toggleItem.menu = nil
        } else { toggle() }
    }
    @objc func toggle() { isCollapsed ? expand() : collapse() }
    func collapse() {
        timer?.invalidate(); timer = nil
        let conflicts = conflictingTools
        guard conflicts.isEmpty else {
            warning = "请先退出同类工具（" + conflicts.joined(separator: "、") + "），避免互相隐藏。"
            onChange?(); return
        }
        // If the user puts the arrow on the wrong side, hiding would hide our recovery control.
        guard let dividerFrame = boundary.button?.window?.frame, let toggleFrame = toggleItem.button?.window?.frame,
              dividerFrame.minX < toggleFrame.minX,
              NSScreen.screens.contains(where: { $0.frame.intersects(toggleFrame) }) else {
            warning = "请按住 ⌘，将分隔线 │ 拖到箭头左侧，然后再折叠。"
            onChange?(); return
        }
        warning = ""
        isCollapsed = true
        boundary.length = Self.collapsedWidth(screenWidths: NSScreen.screens.map { $0.frame.width })
        updateAppearance(); onChange?()
    }
    func expand() {
        isCollapsed = false; warning = ""; boundary.length = Self.expandedWidth
        updateAppearance(); schedule(); onChange?()
    }
    @objc private func screensChanged() {
        if isCollapsed { boundary.length = Self.collapsedWidth(screenWidths: NSScreen.screens.map { $0.frame.width }) }
    }
    func noteMenuActivity() {
        idleCountdown.noteActivity(at: ProcessInfo.processInfo.systemUptime)
    }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard autoCollapse && !isCollapsed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        idleCountdown = MenuIdleCountdown(now: now)
        lastInputTimestamp = now
        lastKeyboardTimestamp = now
        lastMouseTimestamp = now
        pointerWasInMenu = false
        let pollingTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.sampleActivity() }
        timer = pollingTimer
        RunLoop.main.add(pollingTimer, forMode: .common)
    }
    private func sampleActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        // Read event age only. No event tap, key contents, accessibility or recording permission.
        let inputAt = now - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        let keyAt = now - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let mouseTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mouseAt = mouseTypes.map { now - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.max() ?? 0
        let hasMouse = mouseAt > lastMouseTimestamp + 0.01
        let hasInput = inputAt > lastInputTimestamp + 0.01
        let hasKey = keyAt > lastKeyboardTimestamp + 0.01
        if hasInput || hasKey || hasMouse {
            let point = NSEvent.mouseLocation
            let inBar = NSScreen.screens.contains { screen in
                screen.frame.contains(point) && point.y >= screen.frame.maxY - NSStatusBar.system.thickness - 2
            }
            refreshMenuRects(now: now)
            let quartzPoint = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
            let inMenu = inBar || menuRects.contains { $0.contains(quartzPoint) }
            if let relevant = MenuActivityPolicy.relevantTimestamp(mouse: hasMouse ? mouseAt : nil,
                    keyboard: hasKey ? keyAt : nil, any: hasInput ? inputAt : nil,
                    pointerInMenu: inMenu, pointerWasInMenu: pointerWasInMenu,
                    hasOpenMenu: !menuRects.isEmpty, settingsActive: NSApp.isActive) {
                idleCountdown.noteActivity(at: relevant)
            }
            pointerWasInMenu = inMenu
        }
        lastInputTimestamp = max(lastInputTimestamp, inputAt)
        lastKeyboardTimestamp = max(lastKeyboardTimestamp, keyAt)
        lastMouseTimestamp = max(lastMouseTimestamp, mouseAt)
        if pointerWasInMenu && NSEvent.pressedMouseButtons != 0 { idleCountdown.noteActivity(at: now) }
        if idleCountdown.isExpired(at: now) { collapse() }
    }
    private func refreshMenuRects(now: TimeInterval) {
        guard now - menuRectsUpdated >= 0.5 else { return }
        menuRectsUpdated = now
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let barBottoms = NSScreen.screens.map { primaryTop - $0.frame.maxY + NSStatusBar.system.thickness }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let popupLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let floatingLevel = Int(CGWindowLevelForKey(.floatingWindow))
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let candidates: [CGRect] = windows.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), bounds.height > NSStatusBar.system.thickness,
                  layer == popupLevel || (layer >= floatingLevel && layer < statusLevel) else { return nil }
            return bounds
        }
        var connected = candidates.filter { rect in barBottoms.contains { abs(rect.minY - $0) <= 14 } }
        // Follow adjacent submenus, without treating unrelated context menus as bar activity.
        for _ in 0..<3 {
            let additional = candidates.filter { rect in !connected.contains(rect) && connected.contains { $0.insetBy(dx: -20, dy: -20).intersects(rect) } }
            if additional.isEmpty { break }
            connected.append(contentsOf: additional)
        }
        menuRects = connected
    }
    private func updateAppearance() {
        toggleItem.button?.image = NSImage(systemSymbolName: isCollapsed ? "chevron.left" : "chevron.right", accessibilityDescription: isCollapsed ? "展开图标" : "折叠图标")
        toggleItem.button?.toolTip = isCollapsed ? "点击展开隐藏图标；右键打开设置" : "点击折叠分隔线左侧图标；右键打开设置"
    }
    func restoreForExit() {
        timer?.invalidate(); timer = nil
        boundary.length = Self.expandedWidth
        NSStatusBar.system.removeStatusItem(boundary)
        NSStatusBar.system.removeStatusItem(toggleItem)
    }
}
