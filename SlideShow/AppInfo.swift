// ============================================================
// AppInfo.swift
// 版本号读取
//
// 显示在「设置 → 信息」和上传网页页脚 —— iPad 和 Mac 浏览器
// 两边都能看到，用来确认装的是哪个构建。
//
// 兼容：iOS 14.0+
// ============================================================

import Foundation

enum AppInfo {

    /// 语义版本号，形如 "1.1"
    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    /// 构建号，每次跑 build_ipa.sh 自动 +1
    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }

    /// "1.1 (build 12)"
    static var display: String {
        "\(shortVersion) (build \(buildNumber))"
    }
}
