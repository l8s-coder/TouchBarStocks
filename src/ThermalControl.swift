import Foundation

let thermalServiceName = "local.penghuichai.TouchBarStocks.thermalhelper"
let thermalStateDirectory = "/Library/Application Support/TouchBarStocksThermal"

@objc protocol ThermalService {
    func request(_ command: String, low: Double, high: Double, reply: @escaping (String) -> Void)
}

struct ThermalSample: Codable {
    var temperature: Double?
    var actual: Double
    var minimum: Double
    var maximum: Double
    var target: Double
    var mode: Int
    static func read() -> ThermalSample? {
        var r = ThermalReading()
        guard ThermalRead(&r) else { return nil }
        return ThermalSample(temperature: r.temperature.isFinite ? r.temperature : nil, actual: r.actual,
                             minimum: r.minimum, maximum: r.maximum, target: r.target, mode: Int(r.mode))
    }
}
struct ThermalStatus: Codable {
    var sample: ThermalSample?
    var enabled: Bool
    var message: String
}
struct FanCurve {
    let low: Double
    let high: Double
    var valid: Bool { low.isFinite && high.isFinite && low >= 45 && low <= 75 && high >= low + 5 && high <= 90 }
    func target(_ sample: ThermalSample, previous: Double?) -> Double? {
        guard valid, let t = sample.temperature, t.isFinite, (10...125).contains(t),
              sample.minimum >= 500, sample.maximum > sample.minimum, sample.maximum <= 15000 else { return nil }
        if t <= low { return nil } // System automatic control below the configured threshold.
        let fraction = min(1, max(0, (t - low) / (high - low)))
        let desired = sample.minimum + (sample.maximum - sample.minimum) * fraction
        // Rise immediately; slow decreases to avoid rapid oscillation. Full speed always wins.
        return min(sample.maximum, max(desired, (previous ?? desired) - 300))
    }
}
protocol FanHardware {
    func read() -> ThermalSample?
    func setTarget(_ rpm: Double) -> Bool
    func restore() -> Bool
    func failureReason() -> String
}
extension FanHardware { func failureReason() -> String { "风扇写入未被接受" } }
struct NativeFanHardware: FanHardware {
    func read() -> ThermalSample? { ThermalSample.read() }
    func setTarget(_ rpm: Double) -> Bool { ThermalSetTarget(rpm) }
    func restore() -> Bool { ThermalRestoreAuto() }
    func failureReason() -> String { String(cString: ThermalLastError()) }
}

// Called only on the helper's main queue. The helper owns its sensor sampling and lease.
final class ThermalEngine {
    let hardware: FanHardware
    let mark: () -> Bool
    let clear: () -> Void
    private(set) var enabled = false
    private(set) var owned = false
    private(set) var message = "系统自动控制"
    var curve = FanCurve(low: 60, high: 85)
    var heartbeat: TimeInterval = 0
    var previous: Double?
    private var targetMismatchCount = 0
    init(hardware: FanHardware, mark: @escaping () -> Bool, clear: @escaping () -> Void) {
        self.hardware = hardware; self.mark = mark; self.clear = clear
    }
    @discardableResult func restore(_ reason: String) -> Bool {
        enabled = false; previous = nil; targetMismatchCount = 0
        guard owned else { message = reason; return true }
        if hardware.restore() { owned = false; clear(); message = reason; return true }
        message = "恢复系统控制失败，将持续重试；请勿退出或同时使用其他风扇工具"
        return false
    }
    func recoverOwnedControl() { owned = true; restore("已恢复上次异常退出前的系统控制") }
    func enable(low: Double, high: Double, now: TimeInterval) {
        guard !owned || enabled else { message = "仍在恢复系统控制，请稍后重试"; return }
        let proposed = FanCurve(low: low, high: high)
        guard proposed.valid else { message = "起始温度须为 45～75°C，全速温度须高出至少 5°C 且不超过 90°C"; return }
        guard let s = hardware.read(), let t = s.temperature, t.isFinite else { message = "无法读取有效的 CPU 温度或风扇信息"; return }
        guard s.mode == 0 || owned else { message = "风扇已被其他工具接管，请先恢复其自动控制"; return }
        curve = proposed; heartbeat = now; enabled = true; tick(now: now)
    }
    func tick(now: TimeInterval) {
        if !enabled { if owned { restore("已恢复系统自动控制") }; return }
        guard now - heartbeat < 8, now >= heartbeat else { restore("App 连接超时，已交还系统控制"); return }
        guard let s = hardware.read(), let t = s.temperature, t.isFinite, (10...125).contains(t) else {
            restore("传感器读取失败，已交还系统控制"); return
        }
        guard s.mode == 0 || owned else { enabled = false; message = "检测到其他工具接管，已停止曲线"; return }
        if owned, let expected = previous {
            targetMismatchCount = s.mode == 1 && abs(s.target - expected) <= 150 ? 0 : targetMismatchCount + 1
            if targetMismatchCount >= 3 { restore("目标转速未能读回确认，已交还系统控制"); return }
        }
        guard let rpm = curve.target(s, previous: previous) else {
            // Keep the curve armed while the firmware controls cooling at low temperature.
            if owned {
                guard hardware.restore() else { restore("恢复失败"); return }
                owned = false; clear()
            }
            previous = nil; targetMismatchCount = 0; message = "温度低于起始值，系统自动控制（曲线待命）"; return
        }
        if !owned {
            guard mark() else { enabled = false; message = "无法保存恢复标记，未接管风扇"; return }
            owned = true
        }
        guard hardware.setTarget(rpm) else {
            let detail = hardware.failureReason()
            NSLog("Thermal write failed: %@", detail)
            restore("写入转速失败，已交还系统控制（\(detail)）"); return
        }
        previous = rpm; message = String(format: "温度曲线控制 · 目标 %.0f RPM", rpm)
    }
    func status() -> ThermalStatus { ThermalStatus(sample: hardware.read(), enabled: enabled, message: message) }
}

func runThermalTests() {
    final class Fake: FanHardware {
        var sample: ThermalSample? = ThermalSample(temperature: 75, actual: 3000, minimum: 1200, maximum: 7200, target: 3000, mode: 0)
        var targets: [Double] = []; var restores = 0; var writeOK = true; var restoreOK = true
        func read() -> ThermalSample? { sample }
        var readbackOK = true
        func setTarget(_ rpm: Double) -> Bool { targets.append(rpm); sample?.mode = 1; if readbackOK { sample?.target = rpm }; return writeOK }
        func restore() -> Bool { restores += 1; if restoreOK { sample?.mode = 0 }; return restoreOK }
    }
    func check(_ value: Bool, _ name: String) { precondition(value, name) }
    let h = Fake(); var marked = false
    let e = ThermalEngine(hardware: h, mark: { marked = true; return true }, clear: { marked = false })
    e.enable(low: 60, high: 85, now: 100)
    check(e.enabled && marked && h.targets.last == 4800, "temperature interpolation")
    h.sample?.temperature = 95; e.tick(now: 102); check(h.targets.last == 7200, "high temperature full speed")
    h.sample?.temperature = 65; e.tick(now: 104); check(h.targets.last == 6900, "slow ramp down")
    h.sample?.temperature = nil; e.tick(now: 106); check(!e.enabled && !marked && h.restores == 1, "sensor failure restores")
    h.sample?.temperature = 75; e.enable(low: 60, high: 85, now: 110); e.tick(now: 118)
    check(!e.enabled && !marked, "lease expiry restores")
    e.enable(low: .nan, high: 85, now: 120); check(!e.enabled, "invalid curve rejected")
    h.sample?.mode = 1; e.enable(low: 60, high: 85, now: 120); check(!e.enabled, "foreign manual control rejected")
    h.sample?.mode = 0; h.writeOK = false; e.enable(low: 60, high: 85, now: 120)
    check(!e.enabled && !marked, "write failure restores")
    h.writeOK = true; e.enable(low: 60, high: 85, now: 130); h.restoreOK = false
    e.restore("test"); check(e.owned && marked && !e.enabled, "failed restore retains ownership marker")
    h.restoreOK = true; e.tick(now: 132); check(!e.owned && !marked, "restore retry")
    h.sample?.temperature = 55; e.enable(low: 60, high: 85, now: 140)
    check(e.enabled && !e.owned && !marked, "low temperature leaves firmware control")
    e.restore("test"); h.sample?.temperature = 75; h.readbackOK = false; h.sample?.target = 1200
    e.enable(low: 60, high: 85, now: 150); e.tick(now: 152); e.tick(now: 154); e.tick(now: 156)
    check(!e.enabled && !marked, "unconfirmed target restores after three samples")
    check(!FanCurve(low: 60, high: 95).valid && !FanCurve(low: 80, high: 85).valid, "temperature bounds")
    var invalid = h.sample!; invalid.minimum = 0
    check(FanCurve(low: 60, high: 85).target(invalid, previous: nil) == nil, "invalid fan limits rejected")
    h.readbackOK = true; h.sample?.temperature = 75; h.sample?.mode = 0
    e.enable(low: 60, high: 85, now: 160)
    h.sample?.mode = 0; h.sample?.target = 1200; e.tick(now: 162)
    check(e.enabled && e.owned, "one stale mode/target sample does not abort accepted write")
    h.sample?.mode = 1; h.sample?.target = 4800; e.tick(now: 164)
    check(e.enabled && e.owned, "eventual hardware readback confirms control")
    e.restore("test cleanup")
    print("PASS thermal curve, sensor failure, lease expiry, conflict, recovery and bounds tests")
}
