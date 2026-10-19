import Foundation
import IOKit.pwr_mgt
import Darwin

private let marker = thermalStateDirectory + "/manual-control"
private let engine = ThermalEngine(hardware: NativeFanHardware(), mark: {
    do { try Data("owned\n".utf8).write(to: URL(fileURLWithPath: marker), options: .atomic); return true }
    catch { return false }
}, clear: { try? FileManager.default.removeItem(atPath: marker) })

final class ThermalSession: NSObject, ThermalService {
    weak var connection: NSXPCConnection?
    weak var server: ThermalListener?
    let identity = UUID()
    func request(_ command: String, low: Double, high: Double, reply: @escaping (String) -> Void) {
        DispatchQueue.main.async { [self] in
            guard let c = connection, ThermalClientAllowed(c), let server = server else { cInvalid(); reply("{}"); return }
            let now = ProcessInfo.processInfo.systemUptime
            switch command {
            case "enable":
                if server.owner == nil || server.owner == identity {
                    engine.enable(low: low, high: high, now: now)
                    if engine.enabled { server.owner = identity }
                }
            case "heartbeat": if server.owner == identity && engine.enabled { engine.heartbeat = now }
            case "restore":
                // An authenticated copy may always release this service's own manual control.
                engine.restore("已交还系统自动控制"); server.owner = nil
            case "status": break
            default: cInvalid(); reply("{}"); return
            }
            let data = try? JSONEncoder().encode(engine.status())
            reply(data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
        }
    }
    func cInvalid() { connection?.invalidate() }
}
final class ThermalListener: NSObject, NSXPCListenerDelegate {
    var owner: UUID?
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ThermalClientAllowed(connection) else { return false }
        let session = ThermalSession(); session.connection = connection; session.server = self
        connection.exportedInterface = NSXPCInterface(with: ThermalService.self)
        connection.exportedObject = session
        let identity = session.identity
        connection.invalidationHandler = { [weak self] in DispatchQueue.main.async {
            if self?.owner == identity { engine.restore("App 已断开，已交还系统控制"); self?.owner = nil }
        } }
        connection.resume(); return true
    }
}
private var powerConnection: io_connect_t = 0
private var notifier: io_object_t = 0
private var notificationPort: IONotificationPortRef?
private func powerEvent(_ ref: UnsafeMutableRawPointer?, _ service: io_service_t, _ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
    if type == UInt32(ThermalWillSleep) {
        engine.restore("休眠前已停止曲线，唤醒后需手动启用")
        IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
    } else if type == UInt32(ThermalCanSleep) {
        IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
    }
}

@main struct ThermalHelperMain {
    static func main() {
        guard geteuid() == 0 else { fputs("Thermal helper requires its administrator-installed launch daemon.\n", stderr); exit(1) }
        // A root-owned marker survives a crash. Never reset another utility's manual mode at startup.
        if FileManager.default.fileExists(atPath: marker) { engine.recoverOwnedControl() }
        let delegate = ThermalListener()
        let listener = NSXPCListener(machServiceName: thermalServiceName); listener.delegate = delegate; listener.resume()
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in engine.tick(now: ProcessInfo.processInfo.systemUptime) }
        RunLoop.main.add(timer, forMode: .common)
        powerConnection = IORegisterForSystemPower(nil, &notificationPort, powerEvent, &notifier)
        // Control is disabled if the required sleep notification cannot be registered.
        guard powerConnection != 0, let port = notificationPort, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else { exit(2) }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let stop = { if engine.restore("服务停止") { exit(0) } }
        term.setEventHandler(handler: stop); interrupt.setEventHandler(handler: stop); term.resume(); interrupt.resume()
        withExtendedLifetime((delegate, listener, term, interrupt)) { RunLoop.main.run() }
    }
}
