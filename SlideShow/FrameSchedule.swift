// ============================================================
// FrameSchedule.swift
// 电子相框定时开关播
//
// 支持跨午夜时段（如 22:00 → 次日 06:00）
// 兼容：iOS 14.0+
// ============================================================

import Foundation
import SwiftUI
import Combine

class FrameSchedule: ObservableObject {

    /// 是否启用定时
    @Published var isEnabled: Bool {
        didSet { save(); refreshDeferred() }
    }

    /// 开始播放时间（只取 时:分）
    @Published var startTime: Date {
        didSet { save(); refreshDeferred() }
    }

    /// 停止播放时间（只取 时:分）
    @Published var endTime: Date {
        didSet { save(); refreshDeferred() }
    }

    /// 当前是否处于播放时段内（定时未启用时恒为 true）
    @Published private(set) var isActive: Bool = true

    // MARK: - 内部

    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let enabled = "schedule.enabled"
        static let start   = "schedule.startMinutes"
        static let end     = "schedule.endMinutes"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - 生命周期

    init() {
        // 注意：init 里赋值不会触发 didSet，所以不会递归保存
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        startTime = Self.date(fromMinutes: defaults.object(forKey: Keys.start) as? Int ?? 7 * 60)
        endTime   = Self.date(fromMinutes: defaults.object(forKey: Keys.end)   as? Int ?? 23 * 60)
        isActive  = Self.computeIsActive(
            enabled: isEnabled,
            start: startTime,
            end: endTime,
            now: Date()
        )
        startTicking()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - 持久化

    private func save() {
        defaults.set(isEnabled, forKey: Keys.enabled)
        defaults.set(Self.minutes(from: startTime), forKey: Keys.start)
        defaults.set(Self.minutes(from: endTime), forKey: Keys.end)
    }

    // MARK: - 时段判断

    /// 延迟一帧重算。
    ///
    /// didSet 可能正处于 SwiftUI 的 view update 事务里（Toggle / DatePicker
    /// 就是在渲染更新中写这些属性的）。refresh 会改 isActive 这个 @Published，
    /// 在事务里同步改会触发 "Modifying state during view update" 崩溃。
    private func refreshDeferred() {
        DispatchQueue.main.async { self.refresh() }
    }

    /// 重新计算当前是否在播放时段，变化时更新 isActive
    func refresh() {
        let active = Self.computeIsActive(
            enabled: isEnabled,
            start: startTime,
            end: endTime,
            now: Date()
        )
        if active != isActive {
            isActive = active
        }
    }

    /// 纯函数，方便测试
    static func computeIsActive(enabled: Bool, start: Date, end: Date, now: Date) -> Bool {
        guard enabled else { return true }

        let nowM   = minutes(from: now)
        let startM = minutes(from: start)
        let endM   = minutes(from: end)

        // 起止相同 → 视为全天播放
        if startM == endM { return true }

        if startM < endM {
            // 普通时段，如 07:00 - 23:00
            return nowM >= startM && nowM < endM
        } else {
            // 跨午夜，如 22:00 - 06:00
            return nowM >= startM || nowM < endM
        }
    }

    /// 每 20 秒检查一次，跨过时间边界时自动切换
    private func startTicking() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // 加入 common 模式，避免界面交互时定时器被暂停
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - 辅助

    private static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private static func date(fromMinutes m: Int) -> Date {
        var c = DateComponents()
        c.hour = (m / 60) % 24
        c.minute = m % 60
        return Calendar.current.date(from: c) ?? Date()
    }

    var startTimeString: String { Self.formatter.string(from: startTime) }
    var endTimeString: String   { Self.formatter.string(from: endTime) }

    /// 设置面板里显示的一句话说明
    var summary: String {
        guard isEnabled else { return "未启用定时，全天播放" }

        let startM = Self.minutes(from: startTime)
        let endM   = Self.minutes(from: endTime)

        if startM == endM {
            return "每天全天播放"
        } else if startM < endM {
            return "每天 \(startTimeString) - \(endTimeString) 播放，其余时间暂停"
        } else {
            return "每天 \(startTimeString) - 次日 \(endTimeString) 播放（跨午夜）"
        }
    }
}
