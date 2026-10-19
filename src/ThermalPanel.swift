import AppKit

final class ThermalPanel: NSObject {
    private var window: NSWindow!
    private var timer: Timer?
    private var connection: NSXPCConnection?
    private var inFlight = false
    private var connected = false
    private var active = false
    private let readings = NSTextField(wrappingLabelWithString: "正在读取…")
    private let state = NSTextField(wrappingLabelWithString: "")
    private let low = NSTextField(string: "60")
    private let high = NSTextField(string: "85")
    private var enable: NSButton!
    private var restore: NSButton!
    private var serviceText = "尚未连接温控服务；当前只监测，不会修改风扇。"
    private var requestID = UUID()
    override init() {
        super.init()
        if UserDefaults.standard.object(forKey: "Thermal.low") != nil {
            low.doubleValue = UserDefaults.standard.double(forKey: "Thermal.low")
            high.doubleValue = UserDefaults.standard.double(forKey: "Thermal.high")
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 450), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "CPU 温度与风扇"; window.isReleasedWhenClosed = false; window.center()
        let root = window.contentView!
        func label(_ text: String, _ y: CGFloat, _ size: CGFloat = 14) {
            let v = NSTextField(wrappingLabelWithString: text); v.font = .systemFont(ofSize: size); v.frame = NSRect(x: 25, y: y, width: 600, height: 42); root.addSubview(v)
        }
        label("温度与风扇", 385, 24)
        readings.font = .monospacedSystemFont(ofSize: 17, weight: .medium); readings.frame = NSRect(x: 25, y: 296, width: 600, height: 84); root.addSubview(readings)
        label("起始温度 °C                     全速温度 °C", 245)
        low.frame = NSRect(x: 25, y: 225, width: 120, height: 28); high.frame = NSRect(x: 220, y: 225, width: 120, height: 28)
        root.addSubview(low); root.addSubview(high)
        func button(_ title: String, _ action: Selector, _ x: CGFloat, _ width: CGFloat) -> NSButton {
            let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; b.frame = NSRect(x: x, y: 175, width: width, height: 34); root.addSubview(b); return b
        }
        enable = button("启用温度曲线", #selector(start), 25, 160)
        restore = button("恢复系统自动", #selector(stop), 195, 160)
        _ = button("安装 / 更新温控服务", #selector(install), 365, 250)
        state.frame = NSRect(x: 25, y: 105, width: 600, height: 60); state.font = .systemFont(ofSize: 13); root.addSubview(state)
        label("低于起始温度：系统自动控制；达到全速温度：硬件允许的最高转速。\n每 2 秒采样。退出、休眠或读数异常时尝试恢复系统控制。请勿同时启用其他风扇工具。", 32, 12)
        update(); send("status")
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }; self.update(); self.send(self.active ? "heartbeat" : "status")
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    private func update() {
        if let s = ThermalSample.read() {
            let temperature = s.temperature.map { String(format: "%.1f°C", $0) } ?? "不可用"
            readings.stringValue = String(format: "CPU 最高温度  %@\n风扇  %.0f RPM   目标 %.0f RPM\n硬件范围 %.0f～%.0f RPM · %@", temperature, s.actual, s.target, s.minimum, s.maximum, s.mode == 0 ? "系统自动" : "手动模式")
            enable.isEnabled = connected && s.temperature != nil
        } else { readings.stringValue = "无法读取受支持的风扇（当前支持 Apple Silicon 单风扇机型）"; enable.isEnabled = false }
        restore.isEnabled = connected
        state.stringValue = serviceText
    }
    private func connect() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: thermalServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: ThermalService.self)
        c.invalidationHandler = { [weak self, weak c] in DispatchQueue.main.async {
            guard self?.connection === c else { return }; self?.connection = nil; self?.disconnected()
        } }
        c.interruptionHandler = { [weak self] in DispatchQueue.main.async { self?.disconnected() } }
        c.resume(); connection = c; return c
    }
    private func disconnected() {
        connected = false; active = false; inFlight = false
        serviceText = "温控服务未连接或版本授权不匹配；当前只监测。安装/更新服务后可启用曲线。"
        update()
    }
    private func send(_ command: String) {
        // User commands must never be swallowed by a pending heartbeat.
        if inFlight && (command == "status" || command == "heartbeat") { return }
        let c = connect(); let id = UUID(); requestID = id; inFlight = true
        let remote = c.remoteObjectProxyWithErrorHandler { [weak self] _ in DispatchQueue.main.async {
            guard self?.requestID == id else { return }; self?.disconnected()
        } } as? ThermalService
        remote?.request(command, low: low.doubleValue, high: high.doubleValue) { [weak self] json in DispatchQueue.main.async {
            guard let self = self, self.requestID == id else { return }; self.inFlight = false
            guard let data = json.data(using: .utf8), let status = try? JSONDecoder().decode(ThermalStatus.self, from: data) else { self.disconnected(); return }
            self.connected = true; self.active = status.enabled; self.serviceText = status.message; self.update()
        } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.requestID == id, self.inFlight else { return }
            self.connection?.invalidate(); self.connection = nil; self.disconnected()
        }
    }
    @objc private func start() {
        guard FanCurve(low: low.doubleValue, high: high.doubleValue).valid else {
            serviceText = "起始温度须为 45～75°C；全速温度须高出至少 5°C，且不超过 90°C。"; update(); return
        }
        let other = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.lowercased().contains("macsfancontrol") == true }
        guard !other else { serviceText = "请先退出 Macs Fan Control 并将其恢复为自动控制，再启用曲线。"; update(); return }
        UserDefaults.standard.set(low.doubleValue, forKey: "Thermal.low")
        UserDefaults.standard.set(high.doubleValue, forKey: "Thermal.high")
        send("enable")
    }
    @objc private func stop() { send("restore") }
    @objc private func install() {
        guard Bundle.main.bundleURL.path == "/Applications/TouchBarStocks.app" else {
            let a = NSAlert(); a.messageText = "请先将此版本放入 /Applications/TouchBarStocks.app"; a.informativeText = "服务只授权该位置的当前 App 版本。"; a.runModal(); return
        }
        guard let script = Bundle.main.url(forResource: "InstallThermalService", withExtension: "command") else { return }
        NSWorkspace.shared.open(script)
    }
    func shutdown() {
        timer?.invalidate(); active = false
        if connected { send("restore") }
        // The authenticated helper also restores on disconnect, with an 8-second lease fallback.
        connection?.invalidate(); connection = nil
    }
}
