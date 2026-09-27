// ============================================================
// ThemeManager.swift
// 把主题直接落到 UIWindow.userInterfaceStyle 上
//
// 为什么需要它：
//   .preferredColorScheme 在 iOS 14 上有个坑 —— 设置面板（sheet）
//   正在显示时改主题，已经弹出的 sheet 不会跟着变（系统只更新
//   后面的新视图）。把整个窗口强制成对应风格，设置面板才会
//   当场跟着变。
//
// 兼容：iOS 14.0+（UIApplication.shared.windows 在 15 起弃用，
// 这里目标就是 14，直接用）
// ============================================================

import UIKit

enum ThemeManager {

    /// theme：0 = 深色，1 = 浅色，2 = 跟随系统
    static func apply(theme: Int) {
        let style: UIUserInterfaceStyle
        switch theme {
        case 1: style = .light
        case 2: style = .unspecified     // 跟随系统
        default: style = .dark
        }
        DispatchQueue.main.async {
            for window in UIApplication.shared.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
