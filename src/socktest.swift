import Foundation
import Darwin

// socktest — raw connect probe against MAGLED_SOCK, prints errno + reply.
let path = ProcessInfo.processInfo.environment["MAGLED_SOCK"] ?? "/var/run/magled.sock"
print("target: \(path)")
print("exists: \(FileManager.default.fileExists(atPath: path))")

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let bytes = Array(path.utf8CString.prefix(104))
withUnsafeMutableBytes(of: &addr) { raw in
    raw.baseAddress!.advanced(by: 2).copyMemory(from: bytes, byteCount: bytes.count)
}
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { print("socket() errno \(errno)"); exit(2) }
let r = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
        Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
if r != 0 { print("connect() errno \(errno): \(String(cString: strerror(errno)))"); exit(1) }
print("connected")
let req = Array("ping\n".utf8)
_ = req.withUnsafeBytes { buf in Darwin.write(fd, buf.baseAddress, buf.count) }
var buf = [UInt8](repeating: 0, count: 256)
let n = buf.withUnsafeMutableBytes { p -> Int in Darwin.read(fd, p.baseAddress, 256) }
print("read \(n): \(String(bytes: buf.prefix(n), encoding: .utf8) ?? "?")")
