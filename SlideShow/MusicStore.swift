// ============================================================
// MusicStore.swift
// 相框曲库 —— 通过上传服务传进来的音乐文件
//
// 存哪儿：Documents/PhotoStation/Music/
// 格式：mp3 / m4a / aac / wav（AVPlayer 都能播）
//
// 兼容：iOS 14.0+
// ============================================================

import Foundation
import Combine

final class MusicStore: ObservableObject {

    static let shared = MusicStore()

    /// 认的音乐扩展名。上传服务按它把文件路由到曲库。
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav"
    ]

    let musicDir: URL

    private let ioQueue = DispatchQueue(label: "photostation.music", qos: .userInitiated)

    @Published private(set) var songs: [URL] = []
    private var signature = ""
    private var hasScannedOnce = false

    private init() {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        musicDir = docs.appendingPathComponent("PhotoStation/Music", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: musicDir, withIntermediateDirectories: true)

        refresh()
    }

    // MARK: - 扫描

    func refresh() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }

            let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: self.musicDir,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []

            let songs = entries
                .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                    return da > db
                }

            DispatchQueue.main.async {
                let newSig = songs.map { $0.lastPathComponent }.joined(separator: "|")
                let isFirst = !self.hasScannedOnce
                let changed = newSig != self.signature
                self.songs = songs
                self.signature = newSig
                self.hasScannedOnce = true

                // 首次扫描不广播，之后有变化才广播
                if changed, !isFirst {
                    NotificationCenter.default.post(
                        name: .musicStoreDidChange, object: nil)
                }
            }
        }
    }

    // MARK: - 写入 / 删除

    /// 存一首新音乐（上传服务调用）。返回落盘 URL。
    @discardableResult
    func add(filename: String, data: Data) -> URL? {
        let safeName = LocalPhotoStore.sanitize(filename)
        guard Self.audioExtensions.contains(
            (safeName as NSString).pathExtension.lowercased()) else { return nil }
        guard !data.isEmpty else { return nil }

        var result: URL?
        ioQueue.sync {
            let dest = uniqueURL(preferredName: safeName)
            do {
                try data.write(to: dest, options: .atomic)
                result = dest
            } catch {
                return
            }
        }
        refresh()
        return result
    }

    func delete(_ urls: [URL]) {
        ioQueue.sync {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
        refresh()
    }

    func deleteAll() {
        ioQueue.sync {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: musicDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in entries
            where Self.audioExtensions.contains(url.pathExtension.lowercased()) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        refresh()
    }

    /// 按文件名找（删除 / 选择曲用）
    func url(named name: String) -> URL? {
        let target = LocalPhotoStore.sanitize(name)
        return songs.first { $0.lastPathComponent == target }
    }

    // MARK: - 工具

    private func uniqueURL(preferredName: String) -> URL {
        let name = preferredName
        var candidate = musicDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while true {
            let next = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            candidate = musicDir.appendingPathComponent(next)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    var musicBytes: Int {
        songs.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}

extension Notification.Name {
    /// 曲库变化（新增 / 删除了音乐）
    static let musicStoreDidChange = Notification.Name("photostation.musicDidChange")
}
