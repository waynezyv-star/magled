import Foundation
import Darwin

// Sock.swift — tiny Unix-socket client for the magled helper.
// Protocol: one request line in, one response line out, per connection.
//   request:  "ping" | "get" | "set <hex>"
//   response: "OK <hex|version>" | "ERR <reason>"

public enum LedSock {
    /// Override with MAGLED_SOCK env (testing).
    public static var path: String {
        ProcessInfo.processInfo.environment["MAGLED_SOCK"] ?? "/var/run/magled.sock"
    }

    public struct Reply {
        public let ok: Bool
        public let payload: String   // hex value or error text
        public init(_ ok: Bool, _ payload: String) { self.ok = ok; self.payload = payload }
    }

    public static func fillSunPath(_ addr: inout sockaddr_un, path: String) {
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString.prefix(104))
        withUnsafeMutableBytes(of: &addr) { raw in
            guard let base = raw.baseAddress else { return }
            base.advanced(by: 2).copyMemory(from: bytes, byteCount: bytes.count)
        }
    }

    public static func send(_ request: String, timeout: Int32 = 5) -> Reply? {
        var addr = sockaddr_un()
        fillSunPath(&addr, path: path)
        // macOS sockaddr_un: 2-byte family + 104 sun_path = 106 bytes total

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                // 与 helper bind 时保持一致：AF_UNIX 地址长度 = 2 + 路径长
                Darwin.connect(fd, sp, socklen_t(2 + path.utf8.count))
            }
        }
        guard ok == 0 else { return nil }

        var toWrite = Array(request.utf8)
        toWrite.append(0x0A) // \n
        var written = 0
        while written < toWrite.count {
            let n = toWrite.withUnsafeBytes { buf -> Int in
                Darwin.write(fd, buf.baseAddress!.advanced(by: written), buf.count - written)
            }
            guard n > 0 else { return nil }
            written += n
        }

        var buffer = [UInt8](repeating: 0, count: 256)
        var response = [UInt8]()
        while response.count < 1024 {
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                response.append(contentsOf: buffer.prefix(n))
                if response.contains(0x0A) { break }
            } else if n == 0 { break }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break } // timeout
            else { break }
        }
        guard !response.isEmpty else { return nil }
        if let nl = response.firstIndex(of: 0x0A) { response.removeSubrange(nl + 1..<response.count) }
        let line = String(bytes: response, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = line.split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        let payload = parts.count > 1 ? parts[1] : ""
        return Reply(first.uppercased() == "OK", payload)
    }

    public static func helperRunning() -> Bool {
        send("ping")?.ok == true
    }
}
