// ============================================================
// MusicPlayer.swift
// 相框背景音乐
//
// 队列循环播放 AVPlayer。曲库在 MusicStore（上传服务传进来）。
// 音.session 用 .playback：系统静音键不影响它（相框想响就响）。
// App 退到后台音乐会停（没声明后台音频模式），回前台再 applyMusic。
//
// 兼容：iOS 14.0+
// ============================================================

import Foundation
import AVFoundation

final class MusicPlayer: ObservableObject {

    static let shared = MusicPlayer()

    @Published var isPlaying = false
    @Published var currentSong: String = ""

    /// 音量 0...1。默认 0.3 —— 相框音乐别盖过人声。
    @Published var volume: Double = 0.3 {
        didSet {
            PlaybackStore.musicVolume = volume
            avPlayer?.volume = Float(volume)
        }
    }

    private var avPlayer: AVPlayer?
    private var queue: [URL] = []
    private var index = 0
    private var endObserver: Any?

    private init() {
        avPlayer = AVPlayer()
        volume = PlaybackStore.musicVolume

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // 音频会话拿不到也不影响图片播放，继续
        }

        // 一首播完 → 下一首，队列循环
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.advance()
        }
    }

    // MARK: - 控制

    func playQueue(_ songs: [URL], startAt start: Int) {
        guard !songs.isEmpty else {
            stop()
            return
        }
        queue = songs
        index = start % songs.count
        loadCurrent()
    }

    /// 跳到下一首（当前播完自动走这里，也可手动）
    func advance() {
        guard !queue.isEmpty else { return }
        index = (index + 1) % queue.count
        loadCurrent()
    }

    func stop() {
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        currentSong = ""
        isPlaying = false
    }

    /// 回前台 / 曲库变化时重新应用当前设置
    func restart() {
        guard !queue.isEmpty else { return }
        loadCurrent()
    }

    private func loadCurrent() {
        guard index < queue.count else { return }
        let url = queue[index]
        let item = AVPlayerItem(url: url)
        avPlayer?.replaceCurrentItem(with: item)
        avPlayer?.volume = Float(volume)
        avPlayer?.play()
        currentSong = url.deletingPathExtension().lastPathComponent
        isPlaying = true
    }

    deinit {
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
        }
        avPlayer?.pause()
    }
}
