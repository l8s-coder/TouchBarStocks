import AppKit

var smokeExitCode: Int32 = 0

struct Stock: Codable, Equatable {
    let symbol: String
    let name: String
    var hongKong: Bool { symbol.hasPrefix("hk") }
    var label: String { "\(name) \(hongKong ? "H" : "A")" }
    static let defaults = [Stock(symbol: "sh601988", name: "中国银行"), Stock(symbol: "hk03988", name: "中国银行"), Stock(symbol: "sh600028", name: "中国石化"), Stock(symbol: "hk00386", name: "中国石化"), Stock(symbol: "sh601668", name: "中国建筑")]
    static func parseList(_ text: String) throws -> [Stock] {
        var result: [Stock] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0].range(of: "^(sh[0-9]{6}|sz[0-9]{6}|hk[0-9]{5})$", options: .regularExpression) != nil else { throw Failure.message("每行填写：市场代码 名称，例如 sh601988 中国银行") }
            guard !result.contains(where: { $0.symbol == parts[0] }) else { throw Failure.message("股票代码重复：\(parts[0])") }
            result.append(Stock(symbol: parts[0], name: parts.dropFirst().joined(separator: " ")))
        }
        guard !result.isEmpty && result.count <= 30 else { throw Failure.message("请设置 1～30 只自选股") }
        return result
    }
}
enum Failure: Error { case message(String) }
struct Quote {
    let price: Double
    let percent: Double
    let time: Date
    let timeText: String
    static func parse(_ data: Data) -> [String: Quote] {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let text = String(data: data, encoding: encoding) else { return [:] }
        var result: [String: Quote] = [:]
        for line in text.components(separatedBy: ";") {
            let halves = line.components(separatedBy: "=\"")
            guard halves.count == 2 else { continue }
            let symbol = halves[0].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v_", with: "")
            let fields = halves[1].replacingOccurrences(of: "\"", with: "").components(separatedBy: "~")
            guard fields.count > 32, let price = Double(fields[3]), price > 0, let percent = Double(fields[32]), price.isFinite, percent.isFinite else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = symbol.hasPrefix("hk") ? "yyyy/MM/dd HH:mm:ss" : "yyyyMMddHHmmss"
            formatter.isLenient = false
            guard let date = formatter.date(from: fields[30]) else { continue }
            formatter.dateFormat = "MM-dd HH:mm"
            result[symbol] = Quote(price: price, percent: percent, time: date, timeText: formatter.string(from: date))
        }
        return result
    }
}
import CoreFoundation

final class TickerView: NSView {
    var text = NSAttributedString(string: "正在获取行情…", attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 16, weight: .medium)])
    var offset: CGFloat = 0
    var paused = false
    var timer: Timer?
    var lastTick = ProcessInfo.processInfo.systemUptime
    var onTap: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let delta = min(now - self.lastTick, 0.15)
            self.lastTick = now
            if !self.paused { self.offset += CGFloat(delta * 32); self.needsDisplay = true }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        let width = text.size().width + 60
        guard width > 60 else { return }
        offset = offset.truncatingRemainder(dividingBy: width)
        let y = (bounds.height - text.size().height) / 2
        var x = -offset
        while x < bounds.width { text.draw(at: NSPoint(x: x, y: y)); x += width }
    }
    override func mouseDown(with event: NSEvent) { onTap?() }
    func update(_ value: NSAttributedString) { text = value; needsDisplay = true }
}

final class Controller: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSWindowDelegate {
    var stocks = Stock.defaults
    var quotes: [String: Quote] = [:]
    var errors = Set<String>()
    var inFlight = false
    var generation = 0
    var task: URLSessionDataTask?
    var window: NSWindow!
    var status: NSStatusItem!
    var folder: MenuBarFolder!
    var foldButton: NSButton!
    var autoFoldButton: NSButton!
    var refreshControl: NSButton!
    var thermalPanel: ThermalPanel?
    @objc func showThermalPanel() {
        if thermalPanel == nil { thermalPanel = ThermalPanel() }
        thermalPanel?.show()
    }
    var lastUserRefreshUptime: TimeInterval = 0
    var foldInfo = NSTextField(wrappingLabelWithString: "")
    var editor = NSTextView()
    var info = NSTextField(wrappingLabelWithString: "")
    var preview = TickerView(frame: NSRect(x: 0, y: 0, width: 690, height: 44))
    var touchTicker = TickerView(frame: NSRect(x: 0, y: 0, width: 540, height: 30))
    var bar: NSTouchBar!
    var refreshTimer: Timer?
    var paused = false
    var visible = false
    let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TouchBarStocks/watchlist.json")
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = try? Data(contentsOf: configURL), let saved = try? JSONDecoder().decode([Stock].self, from: data),
           let valid = try? Stock.parseList(saved.map { "\($0.symbol) \($0.name)" }.joined(separator: "\n")) { stocks = valid }
        buildMenu()
        folder = MenuBarFolder()
        folder.openSettings = { [weak self] in self?.showWindow() }
        folder.onChange = { [weak self] in self?.updateFolderControls() }
        buildWindow(); buildBar()
        preview.onTap = { [weak self] in self?.togglePause() }
        touchTicker.onTap = { [weak self] in self?.togglePause() }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        showWindow()
        if !CommandLine.arguments.contains("--smoke-test") && !CommandLine.arguments.contains("--folder-smoke-test") && !CommandLine.arguments.contains("--auto-folder-smoke-test") && !CommandLine.arguments.contains("--idle-folder-smoke-test") && TBSupported() { showBar() }
        if CommandLine.arguments.contains("--auto-folder-smoke-test") || CommandLine.arguments.contains("--idle-folder-smoke-test") { runAutoFolderSmokeTest() }
        if CommandLine.arguments.contains("--folder-smoke-test") { runFolderSmokeTest() }
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if let bitmap = self.window.contentView?.bitmapImageRepForCachingDisplay(in: self.window.contentView!.bounds) {
                    self.window.contentView!.cacheDisplay(in: self.window.contentView!.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: "/tmp/touchbar-stocks-preview.png")) }
                }
                let presented = TBSystemStatus() != 0 && TBShow(self.bar)
                print("SMOKE: systemStatus=\(TBSystemStatus()) presented=\(presented) window=\(self.window.isVisible) quotes=\(self.quotes.count) systemTouchBarAPI=\(TBSupported())")
                NSApp.terminate(nil)
            }
        }
    }
    func runAutoFolderSmokeTest() {
        let previous = folder.autoCollapse
        let probe = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        probe.button?.title = "测"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.folder.autoCollapse = true
            NSApp.hide(nil)
            let resetting = CommandLine.arguments.contains("--idle-folder-smoke-test")
            var remainedOpenAfterOriginalDeadline = true
            if resetting {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.refreshControl.performClick(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 17) { remainedOpenAfterOriginalDeadline = !self.folder.isCollapsed }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (resetting ? 27 : 17)) {
                let screen = NSScreen.screens.map { $0.frame }.reduce(NSRect.zero) { $0.union($1) }
                let hiddenFrame = probe.button?.window?.frame ?? .zero
                let passed = self.folder.isCollapsed && !screen.intersects(hiddenFrame) && remainedOpenAfterOriginalDeadline && (!resetting || self.lastUserRefreshUptime > 0)
                let evidence: [String: Any] = ["passed": passed, "nativeButtonActionInvoked": self.lastUserRefreshUptime > 0, "resetAtTenSeconds": resetting, "openAfterOriginalDeadline": remainedOpenAfterOriginalDeadline, "autoCollapsed": self.folder.isCollapsed,
                    "appActive": NSApp.isActive, "appHidden": NSApp.isHidden,
                    "systemMenuBarVisible": NSMenu.menuBarVisible(),
                    "pressedMouseButtons": NSEvent.pressedMouseButtons,
                    "mouseInMenuBar": NSScreen.screens.contains { $0.frame.contains(NSEvent.mouseLocation) && NSEvent.mouseLocation.y >= $0.frame.maxY - NSStatusBar.system.thickness - 2 },
                    "refusal": self.folder.warning, "testFrame": NSStringFromRect(hiddenFrame)]
                self.folder.autoCollapse = previous
                self.folder.expand()
                if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/touchbar-stocks-auto-folder-test.json"))
                    print(String(data: data, encoding: .utf8)!)
                }
                smokeExitCode = passed ? 0 : 1
                NSStatusBar.system.removeStatusItem(probe)
                NSApp.terminate(nil)
            }
        }
    }
    func runFolderSmokeTest() {
        let probe = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        probe.button?.title = "测"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let before = probe.button?.window?.frame ?? .zero
            let dividerBefore = self.folder.boundary.button?.window?.frame ?? .zero
            let toggleBefore = self.folder.toggleItem.button?.window?.frame ?? .zero
            self.folder.collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let after = probe.button?.window?.frame ?? .zero
                let collapsed = self.folder.isCollapsed
                let conflicts = self.folder.conflictingTools
                let refusal = self.folder.warning
                let dividerWidth = self.folder.boundary.length
                self.folder.expand()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let restored = probe.button?.window?.frame ?? .zero
                    let screen = NSScreen.screens.map { $0.frame }.reduce(NSRect.zero) { $0.union($1) }
                    let arrowVisible = screen.intersects(self.folder.toggleItem.button?.window?.frame ?? .zero)
                    let passed = conflicts.isEmpty ? (collapsed && !screen.intersects(after) && screen.intersects(restored) && arrowVisible && screen.intersects(before)) : (!collapsed && !refusal.isEmpty && dividerWidth == MenuBarFolder.expandedWidth)
                    smokeExitCode = passed ? 0 : 1
                    let evidence: [String: Any] = ["passed": passed, "conflicts": conflicts, "refusal": refusal, "collapsed": collapsed, "dividerWidth": dividerWidth,
                        "testBefore": NSStringFromRect(before), "testCollapsed": NSStringFromRect(after),
                        "testRestored": NSStringFromRect(restored), "dividerBefore": NSStringFromRect(dividerBefore),
                        "toggleBefore": NSStringFromRect(toggleBefore),
                        "testMovedOffscreen": !screen.intersects(after),
                        "testRestoredOnscreen": screen.intersects(restored),
                        "arrowStillOnscreen": screen.intersects(self.folder.toggleItem.button?.window?.frame ?? .zero)]
                    if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/touchbar-stocks-folder-test.json"))
                        print(String(data: data, encoding: .utf8)!)
                    }
                    NSStatusBar.system.removeStatusItem(probe)
                    NSApp.terminate(nil)
                }
            }
        }
    }
    func buildMenu() {
        let main = NSMenu(); let item = NSMenuItem(); main.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        let quit = NSMenuItem(title: "退出行情条", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; appMenu.addItem(quit); NSApp.mainMenu = main
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.autosaveName = "TouchBarStocks.StockMenu"
        status.button?.title = "股"
        let menu = NSMenu()
        for (title, action) in [("自选股与菜单栏设置", #selector(showWindow)), ("CPU 温度与风扇", #selector(showThermalPanel)), ("折叠 / 展开菜单栏图标", #selector(toggleFolder)), ("展开全部图标", #selector(expandFolder)), ("显示 Touch Bar", #selector(showBar)), ("隐藏 Touch Bar", #selector(hideBar)), ("暂停 / 继续滚动", #selector(togglePause)), ("刷新行情", #selector(userRefresh)), ("退出", #selector(quitApp))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        status.menu = menu
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "自选股与菜单栏"; window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        let host = window.contentView!
        let root = NSView(frame: NSRect(x: 0, y: 195, width: 750, height: 525))
        host.addSubview(root)
        func label(_ text: String, _ y: CGFloat, size: CGFloat = 14) {
            let v = NSTextField(labelWithString: text); v.font = .systemFont(ofSize: size); v.frame = NSRect(x: 30, y: y, width: 690, height: 28); root.addSubview(v)
        }
        label("你的自选股，沿 Touch Bar 连续滚动", 465, size: 23)
        label("点击行情暂停 / 继续 · 红涨绿跌 · 每 30 秒更新", 431)
        preview.frame.origin = NSPoint(x: 30, y: 377); preview.wantsLayer = true; preview.layer?.cornerRadius = 8; root.addSubview(preview)
        info.frame = NSRect(x: 30, y: 311, width: 690, height: 62); info.font = .systemFont(ofSize: 12); info.textColor = .secondaryLabelColor; root.addSubview(info)
        label("自选股：每行填写 市场代码 名称（sh / sz 为 A 股，hk 为港股）", 286)
        let scroll = NSScrollView(frame: NSRect(x: 30, y: 125, width: 690, height: 155)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        editor.frame = scroll.bounds; editor.isRichText = false; editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.string = stocks.map { "\($0.symbol) \($0.name)" }.joined(separator: "\n"); editor.autoresizingMask = [.width]; scroll.documentView = editor; root.addSubview(scroll)
        let controls: [(String, Selector, CGFloat, CGFloat)] = [("保存自选股", #selector(save), 30, 130), ("显示到 Touch Bar", #selector(showBar), 175, 180), ("隐藏", #selector(hideBar), 370, 100), ("刷新", #selector(userRefresh), 485, 100), ("温度与风扇", #selector(showThermalPanel), 600, 130)]
        for (title, action, x, width) in controls { let b = NSButton(title: title, target: self, action: action); if title == "刷新" { refreshControl = b }; b.bezelStyle = .rounded; b.frame = NSRect(x: x, y: 75, width: width, height: 32); root.addSubview(b) }
        label("港股为延迟行情；以标注的数据时间为准。关闭窗口后，仍可从菜单栏「股」打开。", 27, size: 12)
        let divider = NSBox(frame: NSRect(x: 30, y: 185, width: 690, height: 1)); divider.boxType = .separator; host.addSubview(divider)
        let title = NSTextField(labelWithString: "菜单栏图标折叠")
        title.font = .systemFont(ofSize: 19, weight: .semibold); title.frame = NSRect(x: 30, y: 145, width: 660, height: 28); host.addSubview(title)
        let instructions = NSTextField(wrappingLabelWithString: "按住 ⌘ 拖动顶部图标：把需要折叠的图标放到 │ 左侧，箭头和「股」放在右侧。点击箭头展开 / 收起，右键箭头打开设置。")
        instructions.font = .systemFont(ofSize: 13); instructions.frame = NSRect(x: 30, y: 91, width: 690, height: 48); host.addSubview(instructions)
        foldButton = NSButton(title: "折叠图标", target: self, action: #selector(toggleFolder)); foldButton.bezelStyle = .rounded; foldButton.frame = NSRect(x: 30, y: 53, width: 130, height: 32); host.addSubview(foldButton)
        let recover = NSButton(title: "展开全部", target: self, action: #selector(expandFolder)); recover.bezelStyle = .rounded; recover.frame = NSRect(x: 175, y: 53, width: 130, height: 32); host.addSubview(recover)
        autoFoldButton = NSButton(checkboxWithTitle: "无操作 15 秒后自动收起", target: self, action: #selector(setAutoFolder))
        autoFoldButton.frame = NSRect(x: 330, y: 53, width: 320, height: 32); host.addSubview(autoFoldButton)
        foldInfo.font = .systemFont(ofSize: 12); foldInfo.frame = NSRect(x: 30, y: 12, width: 690, height: 34); host.addSubview(foldInfo)
        updateFolderControls()
    }
    @objc func toggleFolder() { folder.toggle() }
    @objc func expandFolder() { folder.expand() }
    @objc func setAutoFolder() { folder.noteMenuActivity(); folder.autoCollapse = autoFoldButton.state == .on }
    func updateFolderControls() {
        guard foldButton != nil else { return }
        foldButton.title = folder.isCollapsed ? "展开图标" : "折叠图标"
        autoFoldButton.state = folder.autoCollapse ? .on : .off
        if !folder.conflictingTools.isEmpty {
            foldInfo.textColor = .systemOrange
            foldInfo.stringValue = "检测到 " + folder.conflictingTools.joined(separator: "、") + " 正在运行，请只启用一个折叠工具。"
            return
        }
        foldInfo.textColor = folder.warning.isEmpty ? .secondaryLabelColor : .systemOrange
        foldInfo.stringValue = folder.warning.isEmpty ? (folder.isCollapsed ? "已折叠分隔线左侧图标；应用仍在运行。" : "图标已展开。拖好分隔线后即可折叠；退出本 App 自动恢复。") : folder.warning
    }
    func buildBar() {
        bar = NSTouchBar(); bar.delegate = self
        bar.defaultItemIdentifiers = [NSTouchBarItem.Identifier("stocks.ticker"), NSTouchBarItem.Identifier("stocks.refresh"), NSTouchBarItem.Identifier("stocks.hide")]
        window.touchBar = bar
    }
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        if identifier.rawValue == "stocks.ticker" {
            item.view = touchTicker
            touchTicker.widthAnchor.constraint(equalToConstant: 540).isActive = true
            touchTicker.heightAnchor.constraint(equalToConstant: 30).isActive = true
        } else {
            let refreshItem = identifier.rawValue == "stocks.refresh"
            item.view = NSButton(title: refreshItem ? "↻" : "收起", target: self, action: refreshItem ? #selector(userRefresh) : #selector(hideBar))
        }
        return item
    }
    func diagnose(_ phase: String) {
        let item = bar.item(forIdentifier: NSTouchBarItem.Identifier("stocks.ticker"))
        let state: [String: Any] = ["phase": phase, "systemDFRStatus": TBSystemStatus(), "barVisible": bar.isVisible,
            "itemVisible": item?.isVisible ?? false, "tickerInWindow": touchTicker.window != nil,
            "tickerWidth": touchTicker.frame.width, "tickerHeight": touchTicker.frame.height,
            "appActive": NSApp.isActive, "quotes": quotes.count,
            "systemMode": UserDefaults(suiteName: "com.apple.touchbar.agent")?.string(forKey: "PresentationModeGlobal") ?? "default"]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: configURL.deletingLastPathComponent().appendingPathComponent("touchbar-diagnostics.json"), options: .atomic)
        }
    }
    @objc func showWindow() { folder?.noteMenuActivity(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func showBar() {
        folder?.noteMenuActivity()
        guard TBSystemStatus() != 0 else {
            visible = false; render(); diagnose("system-touchbar-inactive")
            return
        }
        if TBShow(bar) {
            visible = true; render()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.diagnose("after-present") }
        }
        else { showWindow(); alert("当前系统不支持跨应用显示。窗口在前台时使用标准 Touch Bar；可在 Xcode 的 Touch Bar 模拟器中检查。") }
    }
    @objc func hideBar() { folder?.noteMenuActivity(); TBHide(bar); visible = false }
    @objc func togglePause() { folder?.noteMenuActivity(); paused.toggle(); touchTicker.paused = paused; preview.paused = paused; render() }
    @objc func wake() { refresh() }
    @objc func save() {
        folder.noteMenuActivity()
        do {
            let updated = try Stock.parseList(editor.string)
            let data = try JSONEncoder().encode(updated)
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: configURL, options: .atomic)
            generation += 1; task?.cancel(); inFlight = false
            stocks = updated; quotes = quotes.filter { key, _ in updated.contains { $0.symbol == key } }; errors = []; refresh()
        } catch Failure.message(let message) { alert(message) }
        catch { alert("保存失败：\(error.localizedDescription)") }
    }
    func alert(_ message: String) { let a = NSAlert(); a.messageText = message; a.runModal() }
    @objc func userRefresh() { lastUserRefreshUptime = ProcessInfo.processInfo.systemUptime; folder.noteMenuActivity(); refresh() }
    @objc func refresh() {
        guard !inFlight else { return }; inFlight = true
        let current = generation; let requested = stocks
        let url = URL(string: "https://qt.gtimg.cn/q=" + requested.map(\.symbol).joined(separator: ","))!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let valid = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            let parsed = valid ? Quote.parse(data ?? Data()) : [:]
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                self.inFlight = false; self.errors = []
                for stock in requested {
                    if let quote = parsed[stock.symbol] { self.quotes[stock.symbol] = quote }
                    else { self.errors.insert(stock.symbol) }
                }
                self.render()
            }
        }
        task?.resume(); render()
    }
    func render() {
        let line = NSMutableAttributedString()
        for stock in stocks {
            var text = "\(stock.label) 等待行情"
            var color = NSColor.lightGray
            if let quote = quotes[stock.symbol] {
                let price = String(format: stock.hongKong ? "%.3f" : "%.2f", quote.price)
                let percent = String(format: "%+.2f%%", quote.percent)
                text = "\(stock.label) \(stock.hongKong ? "HK$" : "¥")\(price)  \(percent)  [\(quote.timeText)\(stock.hongKong ? " 延迟" : "")]"
                color = quote.percent > 0 ? NSColor.systemRed : quote.percent < 0 ? NSColor.systemGreen : NSColor.white
                if Date().timeIntervalSince(quote.time) > (stock.hongKong ? 20 * 60 : 5 * 60) { text += " 旧行情" }
            }
            if errors.contains(stock.symbol) { text += " 更新失败"; color = .systemOrange }
            line.append(NSAttributedString(string: text + "     •     ", attributes: [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)]))
        }
        preview.update(line); touchTicker.update(line)
        let systemState = TBSystemStatus() == 0 ? "系统 Touch Bar 未启用（状态 0），需恢复系统服务；当前仅显示窗口预览。\n" : ""
        info.textColor = TBSystemStatus() == 0 ? .systemOrange : .secondaryLabelColor
        info.stringValue = systemState + "\(paused ? "已暂停滚动" : "连续滚动中") · \(inFlight ? "正在刷新" : "30 秒刷新") · 腾讯公开行情 · \(stocks.count) 个标的\n显示来源数据时间（北京时间），港股可能延迟约 15 分钟；旧行情 / 更新失败会单独标注。"
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { thermalPanel?.shutdown(); task?.cancel(); folder?.restoreForExit(); TBHide(bar) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

if CommandLine.arguments.contains("--thermal-status") {
    let status = ThermalStatus(sample: ThermalSample.read(), enabled: false, message: "只读探测，未修改风扇")
    if let data = try? JSONEncoder().encode(status) { print(String(decoding: data, as: UTF8.self)) }
    exit(status.sample == nil ? 1 : 0)
}
if CommandLine.arguments.contains("--self-test") {
    runThermalTests()
    func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
    check(Stock.defaults.count == 5, "default count")
    check((try? Stock.parseList("sh601988 中国银行\nhk03988 中国银行"))?.count == 2, "A/H distinct")
    check((try? Stock.parseList("sh601988 中国银行\nsh601988 重复")) == nil, "duplicate reject")
    check((try? Stock.parseList("garbage 无效")) == nil, "invalid reject")
    check((try? Stock.parseList("")) == nil, "empty reject")
    var fields = Array(repeating: "0", count: 33); fields[3] = "6.190"; fields[30] = "2026/10/14 13:54:09"; fields[32] = "-1.20"
    let payload = "v_hk03988=\"" + fields.joined(separator: "~") + "\";"
    let parsed = Quote.parse(Data(payload.utf8)); check(parsed["hk03988"]?.price == 6.19, "HK price"); check(parsed["hk03988"]?.percent == -1.2, "HK change")
    fields[30] = "20261014140917"; fields[3] = "7.00"; fields[32] = "0.99"
    let aPayload = "v_sh601988=\"" + fields.joined(separator: "~") + "\";"
    check(Quote.parse(Data(aPayload.utf8))["sh601988"]?.percent == 0.99, "A change")
    check(Quote.parse(Data("v_sh601988=\"bad\";".utf8)).isEmpty, "malformed reject")
    fields[3] = "nan"; check(Quote.parse(Data(("v_sh601988=\"" + fields.joined(separator: "~") + "\";").utf8)).isEmpty, "nonfinite reject")
    check(MenuActivityPolicy.relevantTimestamp(mouse: nil, keyboard: 110, any: 110, pointerInMenu: true, pointerWasInMenu: true, hasOpenMenu: false, settingsActive: false) == nil, "typing elsewhere is not menu activity even when pointer rests on bar")
    check(MenuActivityPolicy.relevantTimestamp(mouse: 110, keyboard: nil, any: 110, pointerInMenu: true, pointerWasInMenu: false, hasOpenMenu: false, settingsActive: false) == 110, "mouse interaction in menu resets deadline")
    check(MenuActivityPolicy.relevantTimestamp(mouse: nil, keyboard: 110, any: 110, pointerInMenu: false, pointerWasInMenu: false, hasOpenMenu: true, settingsActive: false) == 110, "keyboard navigation in open menu resets deadline")
    var idle = MenuIdleCountdown(now: 100)
    check(!idle.isExpired(at: 114.99), "idle must not collapse early")
    idle.noteActivity(at: 114)
    check(!idle.isExpired(at: 115), "activity restarts the 15-second deadline")
    check(!idle.isExpired(at: 128.99), "new deadline stays open")
    check(idle.isExpired(at: 129), "15 seconds after latest activity collapses")
    idle.noteActivity(at: 110)
    check(idle.lastActivity == 114, "late samples cannot shorten the deadline")
    check(MenuBarFolder.collapsedWidth(screenWidths: [1440, 2560]) == 5120, "widest display")
    check(MenuBarFolder.collapsedWidth(screenWidths: [7680]) == 10000, "system width bound")
    check(MenuBarFolder.collapsedWidth(screenWidths: [100]) == 500, "minimum width")
    print("PASS: watchlist validation, A/H quote parsing, malformed / nonfinite quotes")
} else {
    let app = NSApplication.shared
    let controller = Controller(); app.delegate = controller; app.setActivationPolicy(.regular); app.run(); exit(smokeExitCode)
}
