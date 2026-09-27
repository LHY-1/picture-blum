// ============================================================
// PlaybackStore.swift
// 断点续播状态持久化
//
// 记录上次播放到哪张、是否处于播放状态，
// App 重启后自动恢复到原位。
//
// 兼容：iOS 14.0+
// ============================================================

import Foundation

enum PlaybackStore {

    private enum Keys {
        static let lastPhotoId = "playback.lastPhotoId"
        static let lastIndex   = "playback.lastIndex"
        static let wasPlaying  = "playback.wasPlaying"
        static let sourceMode  = "playback.sourceMode"
        static let transitionStyle = "playback.transitionStyle"
        static let preloadDepth  = "playback.preloadDepth"
        static let cacheLimit    = "playback.cacheLimit"
        static let musicEnabled  = "music.enabled"
        static let musicSongs    = "music.songs"
        static let musicVolume   = "music.volume"
        static let theme         = "playback.theme"
    }

    private static var defaults: UserDefaults { .standard }

    /// 上次播放的照片 localIdentifier
    static var lastPhotoId: String? {
        get { defaults.string(forKey: Keys.lastPhotoId) }
        set {
            if let value = newValue {
                defaults.set(value, forKey: Keys.lastPhotoId)
            } else {
                defaults.removeObject(forKey: Keys.lastPhotoId)
            }
        }
    }

    /// 上次播放的序号（照片被删除时的兜底）
    static var lastIndex: Int {
        get { defaults.integer(forKey: Keys.lastIndex) }
        set { defaults.set(newValue, forKey: Keys.lastIndex) }
    }

    /// 上次退出时是否在播放。默认 true —— 相框场景希望开机即播
    static var wasPlaying: Bool {
        get {
            // object(forKey:) 为 nil 表示从未写过，返回默认值
            guard defaults.object(forKey: Keys.wasPlaying) != nil else { return true }
            return defaults.bool(forKey: Keys.wasPlaying)
        }
        set { defaults.set(newValue, forKey: Keys.wasPlaying) }
    }

    /// 照片来源。默认「两者都要」—— 相册和上传的照片都能播，
    /// 这样第一次装上就能用，不用先去设置里改。
    static var sourceMode: Int {
        get {
            guard defaults.object(forKey: Keys.sourceMode) != nil else {
                return PhotoSourceMode.both.rawValue
            }
            return defaults.integer(forKey: Keys.sourceMode)
        }
        set { defaults.set(newValue, forKey: Keys.sourceMode) }
    }

    /// 照片切换动画。默认「滑动」—— 相框场景下最有放映感。
    static var transitionStyle: Int {
        get {
            guard defaults.object(forKey: Keys.transitionStyle) != nil else {
                return TransitionStyle.slide.rawValue
            }
            return defaults.integer(forKey: Keys.transitionStyle)
        }
        set { defaults.set(newValue, forKey: Keys.transitionStyle) }
    }

    /// 预加载深度（提前解码后面几张）。默认 1 = 下一张。
    static var preloadDepth: Int {
        get {
            guard defaults.object(forKey: Keys.preloadDepth) != nil else { return 1 }
            return min(max(defaults.integer(forKey: Keys.preloadDepth), 0), 3)
        }
        set { defaults.set(newValue, forKey: Keys.preloadDepth) }
    }

    /// 内存缓存上限（张大图）。默认 5。
    static var cacheLimit: Int {
        get {
            guard defaults.object(forKey: Keys.cacheLimit) != nil else { return 5 }
            return min(max(defaults.integer(forKey: Keys.cacheLimit), 1), 10)
        }
        set { defaults.set(newValue, forKey: Keys.cacheLimit) }
    }

    /// 背景音乐总开关。默认关。
    static var musicEnabled: Bool {
        get { defaults.bool(forKey: Keys.musicEnabled) }
        set { defaults.set(newValue, forKey: Keys.musicEnabled) }
    }

    /// 选中的歌曲（整队循环播放）。
    /// 存文件名而不是路径 —— 文件换目录后还能按名重新找到。
    static var musicSongs: [String] {
        get { defaults.array(forKey: Keys.musicSongs) as? [String] ?? [] }
        set { defaults.set(newValue, forKey: Keys.musicSongs) }
    }

    /// 音量 0...1。默认 0.3。
    static var musicVolume: Double {
        get {
            guard defaults.object(forKey: Keys.musicVolume) != nil else { return 0.3 }
            return defaults.double(forKey: Keys.musicVolume)
        }
        set { defaults.set(newValue, forKey: Keys.musicVolume) }
    }

    /// 主题：0 = 深色（相框默认，夜里不刺眼），1 = 浅色。
    static var theme: Int {
        get {
            guard defaults.object(forKey: Keys.theme) != nil else { return 0 }
            return defaults.integer(forKey: Keys.theme)
        }
        set { defaults.set(newValue, forKey: Keys.theme) }
    }

    /// 清除进度记录
    static func clear() {
        defaults.removeObject(forKey: Keys.lastPhotoId)
        defaults.removeObject(forKey: Keys.lastIndex)
        defaults.removeObject(forKey: Keys.wasPlaying)
    }
}
