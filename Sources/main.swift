// MacStat — минималистичный системный монитор в строке меню.
// Только AppKit + Mach/IOKit, без сторонних библиотек.
import AppKit
import IOKit
import IOKit.ps
import Darwin

// MARK: - Helpers

func sysInt(_ name: String) -> Int {
    var v = 0
    var sz = MemoryLayout<Int>.size
    sysctlbyname(name, &v, &sz, nil, 0)
    return v
}

func sysStr(_ name: String) -> String {
    var sz = 0
    sysctlbyname(name, nil, &sz, nil, 0)
    guard sz > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: sz)
    sysctlbyname(name, &buf, &sz, nil, 0)
    return String(cString: buf)
}

func fmtBytes(_ b: Double) -> String {
    let u = ["B", "KB", "MB", "GB", "TB"]
    var v = b, i = 0
    while v >= 1000, i < u.count - 1 { v /= 1024; i += 1 }
    return i <= 1 ? String(format: "%.0f %@", v, u[i]) : String(format: "%.1f %@", v, u[i])
}

func fmtRate(_ b: Double) -> String { fmtBytes(b) + "/s" }

// MARK: - Temperature (Apple Silicon, IOHID private sensors)

final class Thermal {
    typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    typealias CopyProp = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<CFTypeRef>?
    typealias CopyEvent = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    typealias FloatVal = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private var copyEvent: CopyEvent?
    private var floatVal: FloatVal?
    private var sensors: [(svc: UnsafeMutableRawPointer, name: String)] = []
    private var dieSensors: [(svc: UnsafeMutableRawPointer, name: String)]?
    private var client: UnsafeMutableRawPointer?
    private var services: CFArray?

    init() {
        let h = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        func sym<T>(_ n: String, _ t: T.Type) -> T? {
            guard let p = dlsym(h, n) else { return nil }
            return unsafeBitCast(p, to: t)
        }
        guard let create = sym("IOHIDEventSystemClientCreate", Create.self),
              let setMatch = sym("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copySvcs = sym("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProp = sym("IOHIDServiceClientCopyProperty", CopyProp.self),
              let ce = sym("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let fv = sym("IOHIDEventGetFloatValue", FloatVal.self),
              let c = create(kCFAllocatorDefault) else { return }
        copyEvent = ce; floatVal = fv; client = c
        _ = setMatch(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let arr = copySvcs(c)?.takeRetainedValue() else { return }
        services = arr // держим, чтобы ссылки на сервисы были живы
        for i in 0..<CFArrayGetCount(arr) {
            guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
            let svc = UnsafeMutableRawPointer(mutating: raw)
            let name = (copyProp(svc, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            sensors.append((svc, name))
        }
    }

    func debugCounts() -> String {
        _ = cpuTemp()
        return "all=\(sensors.count) cpu=\(dieSensors?.count ?? 0) names=" + (dieSensors ?? []).prefix(6).map { $0.name }.joined(separator: ",")
    }

    /// Все сенсоры, сгруппированные по имени (без индексов), макс. значение
    func allTemps() -> [(String, Double)] {
        guard let copyEvent, let floatVal else { return [] }
        var g: [String: Double] = [:]
        for s in sensors {
            guard let ev = copyEvent(s.svc, 15, 0, 0) else { continue }
            let v = floatVal(ev, 15 << 16)
            Unmanaged<AnyObject>.fromOpaque(ev).release()
            guard v > 0, v < 150 else { continue }
            var n = s.name
            while let l = n.last, l.isNumber || l == " " { n.removeLast() }
            if n.contains("tdie") { n = "CPU die" }
            else if n.hasPrefix("gas gauge") { n = "Battery" }
            else if n.contains("NAND") { n = "SSD (NAND)" }
            else { n = n.replacingOccurrences(of: " MTR Temp Sensor", with: "").replacingOccurrences(of: "Temp Sensor", with: "") }
            g[n] = max(g[n] ?? 0, v)
        }
        return g.sorted { $0.value > $1.value }
    }

    /// Температура кристалла CPU (макс. по сенсорам), °C
    func cpuTemp() -> Double? {
        guard let copyEvent, let floatVal, !sensors.isEmpty else { return nil }
        if dieSensors == nil {
            let d = sensors.filter { $0.name.contains("tdie") || $0.name.contains("MTR Temp") }
            let all = d.isEmpty ? sensors.filter { !$0.name.contains("gas gauge") && !$0.name.contains("NAND") } : d
            // сенсоров кристалла десятки и они почти одинаковы — каждое чтение это IPC, берём каждый 4-й
            dieSensors = all.count > 6 ? all.enumerated().filter { $0.offset % 4 == 0 }.map { $0.element } : all
        }
        var die: [Double] = [], other: [Double] = []
        for s in dieSensors! {
            guard let ev = copyEvent(s.svc, 15, 0, 0) else { continue }
            let v = floatVal(ev, 15 << 16)
            Unmanaged<AnyObject>.fromOpaque(ev).release()
            guard v > 0, v < 150 else { continue }
            if s.name.contains("tdie") || s.name.contains("MTR Temp") { die.append(v) }
            else if !s.name.contains("gas gauge"), !s.name.contains("NAND") { other.append(v) }
        }
        return die.max() ?? other.max()
    }
}

// MARK: - Sampler

final class Sampler {
    let host = mach_host_self()
    let thermal = Thermal()
    let pageSize = UInt64(sysInt("hw.pagesize"))
    let memTotal = UInt64(sysInt("hw.memsize"))
    let nE = sysInt("hw.perflevel1.logicalcpu")
    var tb = mach_timebase_info_data_t()

    // CPU
    var prevTicks: [UInt32] = []
    var cpuTotal = 0.0, cpuUser = 0.0, cpuSys = 0.0
    var cores: [Double] = []
    var history: [Double] = []
    let maxHistory = 90
    var temp: Double?

    // Memory
    var memUsed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure = 1

    // Extras (только при открытом окне)
    var gpu: Double?
    var battery: (pct: Int, charging: Bool, onAC: Bool)?
    var diskTotal = 0.0, diskFree = 0.0
    var netDown = 0.0, netUp = 0.0
    var prevNet: (UInt64, UInt64, UInt64)?   // in, out, time(ns)
    var load1 = 0.0
    var top: [(String, Double)] = []
    struct Proc { var name: String; var cpu: Double; var mem: UInt64; var count: Int }
    var procsCPU: [Proc] = [], procsMem: [Proc] = []
    var nameCache: [Int32: String] = [:]
    var memApp: UInt64 = 0, memWired: UInt64 = 0, memComp: UInt64 = 0, memCached: UInt64 = 0, memFree: UInt64 = 0
    var load5 = 0.0, load15 = 0.0
    var netRxTotal: UInt64 = 0, netTxTotal: UInt64 = 0
    var temps: [(String, Double)] = []
    var batt: [(String, String)] = []
    var wantDetails = false
    var procMode = 1          // 0 — не нужны (Details), 1 — раз в 2 тика (Overview), 2 — каждый тик (Processes)
    var tickN = 0
    let chip = sysStr("machdep.cpu.brand_string")
    var prevProc: [Int32: UInt64] = [:]
    var prevProcT: UInt64 = 0
    var lastDisk: TimeInterval = 0

    init() { mach_timebase_info(&tb) }

    func sampleLight() {
        sampleCPU()
        temp = thermal.cpuTemp()
    }

    func sampleFull() {
        sampleLight()
        sampleMemory()
        gpu = sampleGPU()
        sampleBattery()
        sampleNet()
        tickN += 1
        if procMode == 2 || (procMode == 1 && tickN % 2 == 0) || (procMode == 1 && top.isEmpty) { sampleProcs() }
        var l = [0.0, 0.0, 0.0]; getloadavg(&l, 3); load1 = l[0]; load5 = l[1]; load15 = l[2]
        if wantDetails { temps = thermal.allTemps(); sampleBatteryDetails() }
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastDisk > 30 { lastDisk = now; sampleDisk() }
    }

    func resetExtras() { prevNet = nil; prevProc = [:]; prevProcT = 0; top = []; procsCPU = []; procsMem = []; nameCache = [:] }

    func sampleCPU() {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var cnt: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS, let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let c = Int(n)
        var cur = [UInt32](repeating: 0, count: c * 4)
        for i in 0..<(c * 4) { cur[i] = UInt32(bitPattern: info[i]) }
        defer { prevTicks = cur }
        guard prevTicks.count == cur.count else { return }
        var cs = [Double](); cs.reserveCapacity(c)
        var tu = 0.0, ts = 0.0, tt = 0.0
        for i in 0..<c {
            let b = i * 4
            let u = Double(cur[b] &- prevTicks[b]), s = Double(cur[b + 1] &- prevTicks[b + 1])
            let id = Double(cur[b + 2] &- prevTicks[b + 2]), ni = Double(cur[b + 3] &- prevTicks[b + 3])
            let t = u + s + id + ni
            cs.append(t > 0 ? (u + s + ni) / t : 0)
            tu += u + ni; ts += s; tt += t
        }
        cores = cs
        if tt > 0 { cpuUser = tu / tt; cpuSys = ts / tt; cpuTotal = (tu + ts) / tt }
        history.append(cpuTotal)
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
    }

    func sampleMemory() {
        var st = vm_statistics64()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &st) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &cnt)
            }
        }
        if r == KERN_SUCCESS {
            let pages = UInt64(st.internal_page_count) &- UInt64(st.purgeable_count)
                + UInt64(st.wire_count) + UInt64(st.compressor_page_count)
            memUsed = pages * pageSize
            memApp = (UInt64(st.internal_page_count) &- UInt64(st.purgeable_count)) * pageSize
            memWired = UInt64(st.wire_count) * pageSize
            memComp = UInt64(st.compressor_page_count) * pageSize
            memCached = (UInt64(st.external_page_count) + UInt64(st.purgeable_count)) * pageSize
            memFree = UInt64(st.free_count) * pageSize
        }
        var sw = xsw_usage()
        var sz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 { swapUsed = sw.xsu_used }
        pressure = max(1, sysInt("kern.memorystatus_vm_pressure_level"))
    }

    func sampleGPU() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        var e = IOIteratorNext(it)
        while e != 0 {
            if let ps = IORegistryEntryCreateCFProperty(e, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let u = (ps["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, u / 100)
            }
            IOObjectRelease(e)
            e = IOIteratorNext(it)
        }
        return best
    }

    func sampleBattery() {
        battery = nil
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d["Current Capacity"] as? Int, let mx = d["Max Capacity"] as? Int, mx > 0 else { continue }
            battery = (cur * 100 / mx, (d["Is Charging"] as? Bool) ?? false,
                       (d["Power Source State"] as? String) == "AC Power")
            return
        }
    }

    func sampleDisk() {
        let k: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: k) {
            diskTotal = Double(v.volumeTotalCapacity ?? 0)
            diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
        }
    }

    func sampleNet() {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return }
        defer { freeifaddrs(first) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  let data = a.pointee.ifa_data else { continue }
            let name = String(cString: a.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(d.ifi_ibytes); tx += UInt64(d.ifi_obytes)
        }
        let now = mach_absolute_time() * UInt64(tb.numer) / UInt64(tb.denom)
        if let p = prevNet, now > p.2 {
            let dt = Double(now - p.2) / 1e9
            // счётчики 32-битные — учитываем переполнение
            let dr = UInt64(UInt32(truncatingIfNeeded: rx) &- UInt32(truncatingIfNeeded: p.0))
            let dtx = UInt64(UInt32(truncatingIfNeeded: tx) &- UInt32(truncatingIfNeeded: p.1))
            netDown = Double(dr) / dt; netUp = Double(dtx) / dt
        }
        prevNet = (rx, tx, now)
        netRxTotal = rx; netTxTotal = tx
    }

    func sampleBatteryDetails() {
        batt = []
        let e = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard e != 0 else { return }
        defer { IOObjectRelease(e) }
        var pr: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(e, &pr, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = pr?.takeRetainedValue() as? [String: Any] else { return }
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        if let c = num("CycleCount") { batt.append(("Cycles", String(Int(c)))) }
        if let dc = num("DesignCapacity"), dc > 0, let nom = num("NominalChargeCapacity") ?? num("AppleRawMaxCapacity") {
            batt.append(("Health", String(format: "%.0f%%", nom / dc * 100)))
        }
        if let t = num("Temperature") { batt.append(("Temperature", String(format: "%.1f °C", t / 100))) }
        if let v = num("Voltage"), let a = (d["InstantAmperage"] as? NSNumber)?.int64Value {
            let w = v / 1000 * Double(a) / 1000
            batt.append((w < 0 ? "Discharging" : "Charging", String(format: "%.1f W", abs(w))))
        }
    }

    func appName(_ pid: Int32) -> String {
        if let n = nameCache[pid] { return n }
        var buf = [CChar](repeating: 0, count: 4096)
        var name = ""
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if let r = path.range(of: ".app/") {
                name = String(path[..<r.lowerBound].split(separator: "/").last ?? "")
            }
        }
        if name.isEmpty {
            var b2 = [CChar](repeating: 0, count: 256)
            proc_name(pid, &b2, 256)
            name = String(cString: b2)
        }
        if name.isEmpty { name = "pid \(pid)" }
        nameCache[pid] = name
        return name
    }

    func sampleProcs() {
        let cap = Int(proc_listallpids(nil, 0))
        guard cap > 0 else { return }
        var pids = [Int32](repeating: 0, count: cap + 32)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        guard n > 0 else { return }
        let now = mach_absolute_time()
        var cur: [Int32: UInt64] = [:]
        var agg: [String: Proc] = [:]
        let wall = prevProcT > 0 ? Double(now - prevProcT) * Double(tb.numer) / Double(tb.denom) : 0
        if wall > 0 && wall < 4e8 { return }   // слишком частый вызов — цифры будут шумными
        for pid in pids.prefix(n) where pid > 0 {
            var ri = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let t = ri.ri_user_time &+ ri.ri_system_time
            cur[pid] = t
            var pct = 0.0
            if wall > 0, let p = prevProc[pid], t >= p {
                pct = Double(t - p) * Double(tb.numer) / Double(tb.denom) / wall
            }
            let mem = ri.ri_phys_footprint
            if pct < 0.002 && mem < 20_000_000 { continue }   // не тянем мелочь
            let nm = appName(pid)
            var a = agg[nm] ?? Proc(name: nm, cpu: 0, mem: 0, count: 0)
            a.cpu += pct; a.mem += mem; a.count += 1
            agg[nm] = a
        }
        prevProc = cur; prevProcT = now
        let all = Array(agg.values)
        procsMem = Array(all.sorted { $0.mem > $1.mem }.prefix(12))
        guard wall > 0 else { return }
        procsCPU = Array(all.sorted { $0.cpu > $1.cpu }.prefix(12))
        top = procsCPU.prefix(3).filter { $0.cpu > 0.005 }.map { ($0.name, $0.cpu) }
    }
}

// MARK: - Panel view (вся отрисовка вручную — быстро и легко)

final class PanelView: NSView {
    override var isFlipped: Bool { true }
    let s: Sampler
    let W: CGFloat = 300, P: CGFloat = 16
    var CW: CGFloat { W - 2 * P }
    let quit = NSButton()
    let seg = NSSegmentedControl(labels: ["Overview", "Processes", "Details"], trackingMode: .selectOne,
                                 target: nil, action: nil)
    let sortSeg = NSSegmentedControl(labels: ["CPU", "Memory"], trackingMode: .selectOne, target: nil, action: nil)
    var onChange: (() -> Void)?
    var tab: Int { seg.selectedSegment }

    @objc func changed() { s.wantDetails = tab == 2; s.procMode = [1, 2, 0][tab]; onChange?() }

    init(_ s: Sampler) {
        self.s = s
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        quit.isBordered = false
        quit.attributedTitle = NSAttributedString(string: "Quit", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        quit.target = NSApp; quit.action = #selector(NSApplication.terminate(_:))
        quit.sizeToFit()
        addSubview(quit)
        for c in [seg, sortSeg] {
            c.controlSize = .small; c.font = NSFont.systemFont(ofSize: 11)
            c.target = self; c.action = #selector(changed)
            c.selectedSegment = 0
            addSubview(c)
        }
        seg.frame = NSRect(x: P, y: 14, width: CW, height: 22)
        sortSeg.frame = NSRect(x: P, y: 44, width: CW, height: 22)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Цвета
    func tint(_ f: Double, warn: Double = 0.75, crit: Double = 0.9) -> NSColor {
        f >= crit ? .systemRed : f >= warn ? .systemOrange : .controlAccentColor
    }

    // Рисование
    var drawing = true
    func text(_ str: String, x: CGFloat, y: CGFloat, w: CGFloat, font: NSFont,
              color: NSColor = .labelColor, right: Bool = false) {
        guard drawing else { return }
        let ps = NSMutableParagraphStyle()
        ps.alignment = right ? .right : .left
        ps.lineBreakMode = .byTruncatingTail
        (str as NSString).draw(in: NSRect(x: x, y: y, width: w, height: font.pointSize + 5),
                               withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: ps])
    }

    func bar(y: CGFloat, frac: Double, color: NSColor, h: CGFloat = 5) {
        guard drawing else { return }
        let r = NSRect(x: P, y: y, width: CW, height: h)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        let w = max(h, CW * CGFloat(min(max(frac, 0), 1)))
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: P, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }

    func divider(_ y: CGFloat) {
        guard drawing else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: P, y: y, width: CW, height: 0.5).fill()
    }

    let fLabel = NSFont.systemFont(ofSize: 13, weight: .medium)
    let fValue = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    let fCap = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    func row(_ y: inout CGFloat, _ title: String, _ value: String, frac: Double? = nil,
             color: NSColor? = nil, caption: String? = nil) {
        text(title, x: P, y: y, w: 120, font: fLabel)
        text(value, x: P + 100, y: y, w: CW - 100, font: fValue, color: .secondaryLabelColor, right: true)
        y += 21
        if let f = frac { bar(y: y, frac: f, color: color ?? tint(f)); y += 9 }
        if let c = caption { text(c, x: P, y: y, w: CW, font: fCap, color: .tertiaryLabelColor); y += 16 }
        y += 8
    }

    /// Возвращает итоговую высоту; при draw=false ничего не рисует
    @discardableResult
    func render(draw: Bool) -> CGFloat {
        drawing = draw
        var y: CGFloat = 50
        if !draw { sortSeg.isHidden = tab != 1 }

        if tab == 0 { renderOverview(&y) } else if tab == 1 { renderProcs(&y) } else { renderDetails(&y) }

        // футер
        divider(y); y += 8
        let up = Int(ProcessInfo.processInfo.systemUptime)
        let ut = up >= 86400 ? "\(up / 86400)d \(up % 86400 / 3600)h" : "\(up / 3600)h \(up % 3600 / 60)m"
        text("Uptime \(ut)", x: P, y: y + 2, w: 160, font: fCap, color: .tertiaryLabelColor)
        if !draw { quit.setFrameOrigin(NSPoint(x: W - P - quit.frame.width, y: y)) }
        y += 24
        return y
    }


    func renderOverview(_ y: inout CGFloat) {
        let draw = drawing
        // — CPU —
        text("CPU", x: P, y: y, w: 100, font: NSFont.systemFont(ofSize: 15, weight: .semibold))
        text(String(format: "%.0f%%", s.cpuTotal * 100), x: P + 100, y: y - 2, w: CW - 100,
             font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold), right: true)
        y += 28
        // график
        let gh: CGFloat = 40
        if draw {
            let r = NSRect(x: P, y: y, width: CW, height: gh)
            let clip = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            NSColor.labelColor.withAlphaComponent(0.06).setFill(); clip.fill()
            NSGraphicsContext.saveGraphicsState(); clip.addClip()
            let h = s.history, mx = s.maxHistory
            if h.count > 1 {
                let step = CW / CGFloat(mx - 1)
                let x0 = P + CW - CGFloat(h.count - 1) * step
                let line = NSBezierPath()
                for (i, v) in h.enumerated() {
                    let pt = NSPoint(x: x0 + CGFloat(i) * step, y: y + gh - 2 - CGFloat(v) * (gh - 4))
                    i == 0 ? line.move(to: pt) : line.line(to: pt)
                }
                let fill = line.copy() as! NSBezierPath
                fill.line(to: NSPoint(x: P + CW, y: y + gh)); fill.line(to: NSPoint(x: x0, y: y + gh)); fill.close()
                NSColor.controlAccentColor.withAlphaComponent(0.28).setFill(); fill.fill()
                NSColor.controlAccentColor.setStroke(); line.lineWidth = 1.5; line.lineJoinStyle = .round; line.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        y += gh + 8
        // ядра
        let n = s.cores.count
        if n > 0 {
            let gap: CGFloat = 3, ch: CGFloat = 26
            let bw = (CW - gap * CGFloat(n - 1)) / CGFloat(n)
            if draw {
                for (i, u) in s.cores.enumerated() {
                    let x = P + CGFloat(i) * (bw + gap)
                    NSColor.labelColor.withAlphaComponent(0.1).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: bw, height: ch), xRadius: 2.5, yRadius: 2.5).fill()
                    let fh = max(2, ch * CGFloat(u))
                    (i < s.nE ? NSColor.systemGreen : tint(u)).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: y + ch - fh, width: bw, height: fh), xRadius: 2.5, yRadius: 2.5).fill()
                }
            }
            y += ch + 6
        }
        text(String(format: "User %.0f%%   System %.0f%%   Load %.2f", s.cpuUser * 100, s.cpuSys * 100, s.load1),
             x: P, y: y, w: CW, font: fCap, color: .tertiaryLabelColor)
        y += 20
        divider(y); y += 12

        // — Остальное —
        if let t = s.temp {
            row(&y, "Temperature", String(format: "%.0f °C", t), frac: (t - 30) / 70,
                color: tint((t - 30) / 70, warn: 0.57, crit: 0.8))
        }
        let mf = Double(s.memUsed) / Double(max(s.memTotal, 1))
        let pr = s.pressure >= 4 ? "Critical" : s.pressure >= 2 ? "Warning" : "Normal"
        row(&y, "Memory", "\(fmtBytes(Double(s.memUsed))) of \(fmtBytes(Double(s.memTotal)))", frac: mf,
            color: s.pressure >= 4 ? .systemRed : s.pressure >= 2 ? .systemOrange : .controlAccentColor,
            caption: "Pressure \(pr)   Swap \(fmtBytes(Double(s.swapUsed)))")
        if let g = s.gpu { row(&y, "GPU", String(format: "%.0f%%", g * 100), frac: g) }
        if let b = s.battery {
            row(&y, "Battery", "\(b.pct)%" + (b.charging ? "  ⚡︎" : b.onAC ? "  plugged in" : ""),
                frac: Double(b.pct) / 100,
                color: b.pct <= 10 && !b.onAC ? .systemRed : b.charging ? .systemGreen : .controlAccentColor)
        }
        if s.diskTotal > 0 {
            let used = s.diskTotal - s.diskFree
            row(&y, "Disk", "\(fmtBytes(s.diskFree)) free", frac: used / s.diskTotal)
        }
        divider(y - 2); y += 10
        row(&y, "Network", "↓ \(fmtRate(s.netDown))   ↑ \(fmtRate(s.netUp))")

        if !s.top.isEmpty {
            divider(y - 2); y += 10
            text("TOP PROCESSES", x: P, y: y, w: CW, font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                 color: .tertiaryLabelColor)
            y += 18
            for (name, pct) in s.top {
                text(name, x: P, y: y, w: CW - 70, font: NSFont.systemFont(ofSize: 12))
                text(String(format: "%.0f%%", pct * 100), x: P + CW - 60, y: y, w: 60,
                     font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                     color: .secondaryLabelColor, right: true)
                y += 19
            }
            y += 4
        }

    }

    // MARK: Processes

    func renderProcs(_ y: inout CGFloat) {
        y += 4
        if !drawing { sortSeg.frame.origin.y = y - 4 }
        y += 28
        let byMem = sortSeg.selectedSegment == 1
        let list = byMem ? s.procsMem : s.procsCPU
        let hf = NSFont.systemFont(ofSize: 10, weight: .semibold)
        text("APP", x: P, y: y, w: 100, font: hf, color: .tertiaryLabelColor)
        text("CPU", x: P + CW - 140, y: y, w: 60, font: hf, color: byMem ? .tertiaryLabelColor : .secondaryLabelColor, right: true)
        text("MEMORY", x: P + CW - 70, y: y, w: 70, font: hf, color: byMem ? .secondaryLabelColor : .tertiaryLabelColor, right: true)
        y += 18
        if list.isEmpty {
            text("Collecting…", x: P, y: y, w: CW, font: NSFont.systemFont(ofSize: 12), color: .tertiaryLabelColor)
            y += 24
            return
        }
        let mx = max(byMem ? Double(list[0].mem) : list[0].cpu, 0.0001)
        let f = NSFont.systemFont(ofSize: 12), mf = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for p in list {
            text(p.count > 1 ? "\(p.name)  ×\(p.count)" : p.name, x: P, y: y, w: CW - 150, font: f)
            text(String(format: "%.1f%%", p.cpu * 100), x: P + CW - 140, y: y, w: 60, font: mf,
                 color: byMem ? .tertiaryLabelColor : .secondaryLabelColor, right: true)
            text(fmtBytes(Double(p.mem)), x: P + CW - 70, y: y, w: 70, font: mf,
                 color: byMem ? .secondaryLabelColor : .tertiaryLabelColor, right: true)
            y += 19
            let v = byMem ? Double(p.mem) : p.cpu
            bar(y: y, frac: v / mx, color: byMem ? .systemPurple : .controlAccentColor, h: 3)
            y += 8
        }
        y += 4
    }

    // MARK: Details

    func section(_ y: inout CGFloat, _ t: String) {
        text(t, x: P, y: y, w: CW, font: NSFont.systemFont(ofSize: 10, weight: .semibold), color: .tertiaryLabelColor)
        y += 18
    }

    func kv(_ y: inout CGFloat, _ k: String, _ v: String, dot: NSColor? = nil) {
        var x = P
        if let d = dot, drawing {
            d.setFill(); NSBezierPath(ovalIn: NSRect(x: P, y: y + 5, width: 7, height: 7)).fill()
        }
        if dot != nil { x += 14 }
        text(k, x: x, y: y, w: 150, font: NSFont.systemFont(ofSize: 12))
        text(v, x: P + 100, y: y, w: CW - 100, font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
             color: .secondaryLabelColor, right: true)
        y += 19
    }

    func renderDetails(_ y: inout CGFloat) {
        let nCores = s.cores.count, nE = s.nE
        section(&y, "SYSTEM")
        kv(&y, "Chip", s.chip.replacingOccurrences(of: "Apple ", with: ""))
        kv(&y, "Cores", nE > 0 ? "\(nCores)  (\(nCores - nE) P + \(nE) E)" : "\(nCores)")
        let v = ProcessInfo.processInfo.operatingSystemVersion
        kv(&y, "macOS", "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        kv(&y, "Load avg", String(format: "%.2f  %.2f  %.2f", s.load1, s.load5, s.load15))
        y += 8; divider(y - 4); y += 6

        section(&y, "MEMORY")
        let tot = Double(max(s.memTotal, 1))
        let parts: [(String, UInt64, NSColor)] = [
            ("App", s.memApp, .controlAccentColor), ("Wired", s.memWired, .systemOrange),
            ("Compressed", s.memComp, .systemPurple), ("Cached files", s.memCached, .systemGray),
        ]
        if drawing {
            let r = NSRect(x: P, y: y, width: CW, height: 8)
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            let clip = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4); clip.fill()
            NSGraphicsContext.saveGraphicsState(); clip.addClip()
            var x = P
            for p in parts {
                let w = CW * CGFloat(Double(p.1) / tot)
                p.2.setFill(); NSRect(x: x, y: y, width: w, height: 8).fill(); x += w
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        y += 16
        for p in parts { kv(&y, p.0, fmtBytes(Double(p.1)), dot: p.2) }
        kv(&y, "Free", fmtBytes(Double(s.memFree)))
        kv(&y, "Swap used", fmtBytes(Double(s.swapUsed)))
        y += 8; divider(y - 4); y += 6

        section(&y, "NETWORK (SINCE BOOT)")
        kv(&y, "Received", fmtBytes(Double(s.netRxTotal)))
        kv(&y, "Sent", fmtBytes(Double(s.netTxTotal)))

        if !s.batt.isEmpty {
            y += 8; divider(y - 4); y += 6
            section(&y, "BATTERY")
            for (k, v) in s.batt { kv(&y, k, v) }
        }
        if !s.temps.isEmpty {
            y += 8; divider(y - 4); y += 6
            section(&y, "SENSORS")
            for (k, v) in s.temps.prefix(8) { kv(&y, k, String(format: "%.0f °C", v)) }
        }
        y += 4
    }

    override func draw(_ dirtyRect: NSRect) { render(draw: true) }

    func relayout() -> NSSize {
        let h = render(draw: false)
        setFrameSize(NSSize(width: W, height: h))
        return NSSize(width: W, height: h)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let s = Sampler()
    var item: NSStatusItem!
    let popover = NSPopover()
    var panel: PanelView!
    var timer: Timer?
    var lastTitle = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panel = PanelView(s)
        panel.onChange = { [weak self] in self?.tick() }
        let vc = NSViewController(); vc.view = panel
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.delegate = self

        s.sampleLight()          // базовая точка для дельт
        schedule(1.5)
        // чтобы первый тик показал реальные цифры
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.tick() }
    }

    func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() {
        if popover.isShown {
            s.sampleFull()
            popover.contentSize = panel.relayout()
            panel.needsDisplay = true
        } else {
            s.sampleLight()
        }
        updateTitle()
    }

    func updateTitle() {
        var t = String(format: "%2.0f%%", s.cpuTotal * 100)
        if let tp = s.temp { t += String(format: " %2.0f°", tp) }
        guard t != lastTitle, let b = item.button else { return }
        lastTitle = t
        b.attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Quit MacStat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = m; sender.performClick(nil); item.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        s.resetExtras()
        s.sampleFull()
        popover.contentSize = panel.relayout()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        schedule(1.0)
        // второй замер через секунду даёт сеть и топ процессов
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if self?.popover.isShown == true { self?.tick() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        s.resetExtras()
        schedule(2.0)
    }
}

#if BENCH
_ = NSApplication.shared
let bs = Sampler(); bs.wantDetails = true
func cpuNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }
func t(_ n: String, _ f: () -> Void) {
    f(); let a = DispatchTime.now().uptimeNanoseconds, c = cpuNs()
    for _ in 0..<20 { f() }
    print(n, "wall", Double(DispatchTime.now().uptimeNanoseconds - a) / 20e6, "ms  cpu", Double(cpuNs() - c) / 20e6, "ms")
}
print("sensors:", bs.thermal.debugCounts())
bs.sampleFull()
t("cpu") { bs.sampleCPU() }
t("thermal cpuTemp") { bs.temp = bs.thermal.cpuTemp() }
t("allTemps") { bs.temps = bs.thermal.allTemps() }
t("memory") { bs.sampleMemory() }
t("gpu") { _ = bs.sampleGPU() }
t("battery") { bs.sampleBattery() }
t("batteryDetails") { bs.sampleBatteryDetails() }
t("net") { bs.sampleNet() }
usleep(500000)
t("procs") { usleep(450000); bs.sampleProcs() }
exit(0)
#endif

#if SNAPSHOT
// Отладка: рендер вкладок панели в PNG (swiftc -D SNAPSHOT), без запуска приложения
_ = NSApplication.shared
let ss = Sampler()
ss.wantDetails = true
ss.sampleFull(); Thread.sleep(forTimeInterval: 1); ss.sampleFull(); Thread.sleep(forTimeInterval: 1)
for _ in 0..<70 { ss.sampleCPU(); Thread.sleep(forTimeInterval: 0.08) }
ss.sampleFull()
let pv = PanelView(ss)
try? FileManager.default.createDirectory(atPath: "docs/screenshots", withIntermediateDirectories: true)
for (theme, ap) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
    for (t, name) in ["overview", "processes", "details"].enumerated() {
        pv.seg.selectedSegment = t
        if t == 1 { pv.sortSeg.selectedSegment = 0 }
        let sz = pv.relayout()
        let appearance = NSAppearance(named: ap)!
        pv.appearance = appearance
        let rep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds)!
        pv.cacheDisplay(in: pv.bounds, to: rep)
        let img = NSImage(size: sz)
        img.addRepresentation(rep)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = sz
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let r = NSRect(origin: .zero, size: sz)
        let clip = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        clip.addClip()
        (theme == "dark" ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
        r.fill()
        img.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/screenshots/\(theme)-\(name).png"))
    }
}
exit(0)
#endif

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
