import Foundation
import IOKit
import Darwin

// magled-helper — root daemon.
// Listens on /var/run/magled.sock, applies the persisted MagSafe 3 LED mode
// (SMC key ACLC) and re-asserts it on a watchdog tick (survives sleep/wake,
// charger re-plug, and reboot).
//
// Install: sudo sh install.sh   (registers the launchd daemon)
// All SMC writes happen here as root — Apple Silicon requires root for SMC writes.

let kAllowed: Set<UInt8> = [0, 1, 3, 4, 6, 7, 25]

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data((ts + " " + s + "\n").utf8))
}

final class Helper {
    let sockPath = LedSock.path
    let modeFile = "/var/root/.magled_mode"
    var fd: CInt = -1
    var run = true
    var persisted: UInt8 = 0
    var sMC: SMC.Client?

    init() {
        guard geteuid() == 0 else {
            log("helper: must run as root (use: sudo sh install.sh)")
            exit(2)
        }
        self.sMC = try? SMC.Client()
        loadPersisted()
        if persisted != 0 {
            apply(persisted, force: true)
            log("helper: re-applied persisted mode 0x\(String(persisted, radix: 16)) on start")
        }
    }

    deinit {
        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(atPath: sockPath)
    }

    func loadPersisted() {
        if let s = try? String(contentsOfFile: modeFile, encoding: .ascii),
           let v = UInt8(s.trimmingCharacters(in: .whitespaces), radix: 16),
           kAllowed.contains(v) {
            persisted = v
        }
    }

    func savePersisted(_ v: UInt8) {
        try? String(format: "%02x", v).write(toFile: modeFile, atomically: true, encoding: .ascii)
    }

    @discardableResult
    func apply(_ v: UInt8, force: Bool) -> Bool {
        guard SMC.isLEDKeySupported() else {
            log("helper: ACLC key not present on this machine (no MagSafe 3 hardware?) — skipping")
            return false
        }
        if !force, let cur = try? sMC?.readByte(SMC.magSafeLEDKey), cur == v { return true }
        do {
            if sMC == nil { sMC = try SMC.Client() }
            try sMC!.writeByte(SMC.magSafeLEDKey, v)
            Thread.sleep(forTimeInterval: 0.05)
            if let back = (try? sMC!.readByte(SMC.magSafeLEDKey)) {
                // macOS 27：系统模式（0x00）回读的是"当前生效颜色"（如满电绿=0x03），
                // 不能用相等校验——读到合法值即视为生效。
                let ok = (v == 0) ? kAllowed.contains(back) : (back == v)
                if !ok {
                    log("helper: WARN write 0x\(String(v, radix: 16)) but read back 0x\(String(back, radix: 16))")
                    return false
                }
            } else {
                // 回读失败（旧版 macOS / root 读被限）：写入调用本身已成功，按成功处理
                log("helper: WARN write 0x\(String(v, radix: 16)) — read-back unavailable, assuming success")
            }
            return true
        } catch {
            log("helper: write 0x\(String(v, radix: 16)) failed: \(error)")
            // 连接失效则丢弃，下次自动重连
            sMC = nil
            return false
        }
    }

    func startSocket() throws {
        try? FileManager.default.removeItem(atPath: sockPath)
        let sfd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sfd >= 0 else { throw NSError(domain: "magled", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed: errno \(String(errno))"]) }
        fd = sfd
        var addr = sockaddr_un()
        LedSock.fillSunPath(&addr, path: sockPath)
        let addrlen = socklen_t(2 + sockPath.utf8.count)
        guard bind(fd, withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, addrlen) == 0 else {
            throw NSError(domain: "magled", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind failed: errno \(String(errno))"])
        }
        chmod(sockPath, 0o660)
        let staff = gid_t(20)
        chown(sockPath, 0, staff)
        guard listen(fd, 8) == 0 else { throw NSError(domain: "magled", code: 3, userInfo: [NSLocalizedDescriptionKey: "listen failed: errno \(String(errno))"]) }
        log("helper: listening on \(sockPath)")
    }

    func handleOne() {
        var peerAddr = sockaddr_un()
        var len = socklen_t(2 + sockPath.utf8.count)
        let cfd = accept(fd, withUnsafeMutablePointer(to: &peerAddr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, &len)
        guard cfd >= 0 else { return }
        defer { close(cfd) }

        // 读超时 5 秒：防止客户端连上却不发数据把单线程守护挂死
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 256)
        var line = [UInt8]()
        while line.count < 512 {
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in Darwin.read(cfd, ptr.baseAddress, 256) }
            if n > 0 {
                line.append(contentsOf: buffer.prefix(n))
                if line.contains(0x0A) { break }
            } else if n == 0 { break }
            else if errno == EINTR { continue }
            else { break }
        }
        guard !line.isEmpty else { return }
        if let i = line.firstIndex(of: 0x0A) { line.removeSubrange(i + 1..<line.count) }
        let request = String(bytes: line, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let response = dispatch(request)
        var data = Array(response.utf8); data.append(0x0A)
        var w = 0
        while w < data.count {
            let n = data.withUnsafeBytes { p in Darwin.write(cfd, p.baseAddress!.advanced(by: w), p.count - w) }
            if n > 0 { w += n } else { break }
        }
    }

    func currentLED() -> UInt8? {
        if sMC == nil {
            let c = try? SMC.Client()
            sMC = c
        }
        guard let c = sMC else { return nil }
        if let v = try? c.readByte(SMC.magSafeLEDKey) { return v }
        // 读取失败：连接可能已失效（睡眠唤醒后常见）——丢弃，下次自动重连
        sMC = nil
        return nil
    }

    func dispatch(_ request: String) -> String {
        let parts = request.lowercased().split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return "ERR empty" }
        switch parts[0] {
        case "ping":
            return "OK 1.0"
        case "get":
            if SMC.isLEDKeySupported(), let v = currentLED() {
                return String(format: "OK %02x", v)
            }
            return "ERR aclc-key-missing"
        case "set":
            guard parts.count > 1, let v = UInt8(parts[1], radix: 16) else { return "ERR bad-value" }
            guard kAllowed.contains(v) else { return "ERR disallowed" }
            let ok = apply(v, force: true)
            // 只有写入成功才持久化：避免失败时状态文件与实际灯态不一致（重启后坚持一个没生效的模式）
            if ok {
                persisted = v
                savePersisted(v)
            }
            return ok ? String(format: "OK %02x", v) : "ERR write-failed"
        default:
            return "ERR unknown-command"
        }
    }

    func watchdogTick() {
        guard persisted != 0 else { return }
        // 用 currentLED() 而非裸 readByte：连接失效时它会重连，避免看门狗静默失效
        if SMC.isLEDKeySupported(),
           let cur = currentLED(),
           cur != persisted {
            log("helper: watchdog — LED state drifted to 0x\(String(cur, radix: 16)), re-asserting 0x\(String(persisted, radix: 16))")
            _ = apply(persisted, force: true)
        }
    }
}

// ---- main ----

let helper = Helper()
do {
    try helper.startSocket()
} catch {
    log("helper: \(error.localizedDescription)")
    exit(1)
}

var stopFlag = false
signal(SIGTERM) { _ in stopFlag = true }
signal(SIGINT) { _ in stopFlag = true }

log("helper: magled v1.0 started (pid \(getpid()), mode 0x\(String(helper.persisted, radix: 16)))")

while !stopFlag {
    var set = fd_set()
    withUnsafeMutablePointer(to: &set) { p in
        p.withMemoryRebound(to: Int8.self, capacity: MemoryLayout<fd_set>.size) { raw in
            for i in 0..<MemoryLayout<fd_set>.size { raw[i] = 0 }
        }
    }
    var tv = timeval(tv_sec: 20, tv_usec: 0)
    withUnsafeMutablePointer(to: &set) { spOuter in
        spOuter.withMemoryRebound(to: fd_set.self, capacity: 1) { sp in
            withUnsafeMutablePointer(to: &tv) { tpOuter in
                tpOuter.withMemoryRebound(to: timeval.self, capacity: 1) { tp in
                    __darwin_fd_set(Int32(helper.fd), sp)
                    let n = select(Int32(helper.fd) + 1, sp, nil, nil, tp)
                    if n > 0 {
                        helper.handleOne()
                    } else if n == 0 {
                        helper.watchdogTick()
                    } else if errno != EINTR {
                        log("helper: select error: \(String(errno))")
                    }
                }
            }
        }
    }
    // allow signal handler to interrupt select（信号本身会中断 select，这里只做极少让退）
    usleep(50_000)
}

log("helper: shutting down")
try? FileManager.default.removeItem(atPath: helper.sockPath)
exit(0)
