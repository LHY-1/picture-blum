// ============================================================
// NetworkInfo.swift
// 取本机局域网 IP
//
// iOS 没有公开 API 能直接问「我的 IP 是多少」，只能遍历网卡。
// getifaddrs() 是 POSIX 接口，在 iOS 上可用且不需要任何权限
// （读网卡地址不算「访问局域网」，不会触发隐私弹窗）。
//
// 兼容：iOS 14.0+
// ============================================================

import Foundation
import Darwin

enum NetworkInfo {

    /// Wi-Fi 网卡的 IPv4 地址，形如 "192.168.0.20"
    ///
    /// iOS 上 Wi-Fi 固定是 en0（蜂窝是 pdp_ip0）。相框场景必然连 Wi-Fi，
    /// 所以只认 en0 就够了。
    static func wifiAddress() -> String? {
        address(forInterface: "en0")
    }

    /// 所有可能的局域网地址（Wi-Fi 优先，其次有线/热点）
    static func candidateAddresses() -> [String] {
        // 按优先级排：en0 = Wi-Fi，en1/en2 = 有线或热点，bridge100 = 个人热点
        ["en0", "en1", "en2", "bridge100"].compactMap { address(forInterface: $0) }
    }

    private static func address(forInterface name: String) -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var result: String?

        // 遍历链表：sequence(first:next:) 比手写 while 干净
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee

            guard let addrPtr = ifa.ifa_addr,
                  addrPtr.pointee.sa_family == UInt8(AF_INET),   // 只要 IPv4
                  String(cString: ifa.ifa_name) == name
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(addrPtr.pointee.sa_len)
            guard getnameinfo(addrPtr, len,
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let ip = String(cString: host)
            // 169.254.x.x 是自分配地址，说明没连上真正的网络
            if !ip.hasPrefix("169.254.") {
                result = ip
            }
        }

        return result
    }

    /// 拼出给用户看的完整网址
    static func urlString(port: UInt16) -> String? {
        guard let ip = wifiAddress() else { return nil }
        return "http://\(ip):\(port)"
    }

    /// 没连 Wi-Fi 时给一句人话解释
    static var unavailableReason: String {
        "没检测到 Wi-Fi 地址。请确认 iPad 已连接 Wi-Fi。"
    }
}
