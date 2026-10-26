import Foundation

// LEDModeText — human-readable labels (shared by the app; the CLI has its own copy).
enum LEDModeText {
    static func current(_ v: UInt8) -> String {
        switch v {
        case 0x00: return "跟随系统"
        case 0x01: return "已关闭"
        case 0x03: return "常亮绿"
        case 0x04: return "常亮橙"
        case 0x06: return "慢速闪烁"
        case 0x07: return "快速闪烁"
        case 0x19: return "闪烁后关闭"
        // macOS 27+ 固件会把 ACLC 读回沙箱化为 0xff（且拒绝第三方写入），
        // 此时灯必然处于系统控制下——按"跟随系统"展示。
        case 0xff: return "跟随系统"
        default: return "未知 0x\(String(format: "%02x", v))"
        }
    }
}
