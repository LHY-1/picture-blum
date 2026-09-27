// ============================================================
// LocalPhotoStore.swift
// 上传照片的登记处 —— 大图存进系统相册，本地只留缩略图
//
// 旧版把上传的照片整份存 Documents 里，占磁盘、还要自己管一套库。
// 现在改成：
//   - 上传的文件直接写进系统相册（只用「添加照片」权限，
//     不动相册里原有的东西）
//   - 本地只留：
//       PhotoStation/Thumbs/      小缩略图（网页和网格用）
//       PhotoStation/Inbox/       尚未入相册的待导入文件
//       PhotoStation/manifest.json 登记表（名字 + 相册里的 asset id）
//
// 播放端「上传的照片」直接查系统相册（PhotoLibraryManager 里做），
// 和本地相册走同一条路，天然支持去重和共享。
//
// 兼容：iOS 14.0+
// ============================================================

import Foundation
import UIKit
import ImageIO
import Photos
import Combine

/// 一张「已存进系统相册的上传照片」
struct MediaEntry: Codable, Equatable {
    let name: String        // 原始文件名（相册里的 asset 按它匹配）
    var assetID: String?    // 系统相册的 localIdentifier（写相册后回填）
    var bytes: Int          // 原图大小，界面显示用
}

final class LocalPhotoStore: ObservableObject {

    static let shared = LocalPhotoStore()

    // MARK: - 目录

    let root: URL
    let inboxDir: URL
    let thumbsDir: URL

    /// 所有改动都在这个串行队列上做，避免并发上传时互相踩
    private let ioQueue = DispatchQueue(label: "photostation.store", qos: .userInitiated)

    private var manifestURL: URL {
        root.appendingPathComponent("manifest.json")
    }

    // MARK: - 状态（只在主线程读写）

    @Published private(set) var inbox: [URL] = []
    /// 已存进系统相册的上传照片
    @Published private(set) var entries: [MediaEntry] = []

    /// 上次扫描到的指纹，用来判断有没有真的变化
    private var signature = ""
    private var hasScannedOnce = false

    /// 上传后是否直接入相册。关掉则先放收件箱，等手动确认。
    @Published var autoImport: Bool {
        didSet { UserDefaults.standard.set(autoImport, forKey: Keys.autoImport) }
    }

    private enum Keys {
        static let autoImport = "photostation.autoImport"
    }

    /// 能识别的图片扩展名
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif",
        "tif", "tiff", "bmp", "webp"
    ]

    // MARK: - 初始化

    private init() {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]

        root     = docs.appendingPathComponent("PhotoStation", isDirectory: true)
        inboxDir = root.appendingPathComponent("Inbox", isDirectory: true)
        thumbsDir = root.appendingPathComponent("Thumbs", isDirectory: true)

        for dir in [inboxDir, thumbsDir] {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }

        if UserDefaults.standard.object(forKey: Keys.autoImport) == nil {
            UserDefaults.standard.set(true, forKey: Keys.autoImport)
        }
        autoImport = UserDefaults.standard.bool(forKey: Keys.autoImport)

        loadEntries()
        refresh()
    }

    // MARK: - 登记表

    private func loadEntries() {
        guard let data = try? Data(contentsOf: manifestURL),
              let list = try? JSONDecoder().decode([MediaEntry].self, from: data) else {
            entries = []
            return
        }
        entries = list
    }

    /// 调用前必须已在 ioQueue 里（或 entries 没有并发改动）
    private func saveEntriesLocked() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    /// 主线程落盘
    private func persistEntries() {
        let snapshot = entries
        ioQueue.sync {
            guard snapshot == self.entries else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.manifestURL, options: .atomic)
            }
        }
    }

    // MARK: - 扫描

    /// 重新扫描两个目录。会顺手收编 Documents 根目录下的散图
    /// （用「文件」App 或 Finder 拖进来的照片会落在那里）。
    func refresh() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }

            self.adoptLooseFiles()

            let inbox = self.scan(self.inboxDir)
            let media = self.scan(self.mediaDir)

            DispatchQueue.main.async {
                self.apply(inbox: inbox, media: media)
            }
        }
    }

    /// 只在主线程调用。媒体库真的变了才广播，避免无谓的重载。
    private func apply(inbox: [URL], media: [URL]) {
        let signature = media.map { $0.lastPathComponent }.joined(separator: "|")
        let isFirstScan = !hasScannedOnce
        let changed = signature != mediaSignature

        self.inbox = inbox
        self.media = media
        mediaSignature = signature
        hasScannedOnce = true

        // 首次扫描不广播 —— 启动流程自己会加载一遍
        guard changed, !isFirstScan else { return }
        NotificationCenter.default.post(name: .photoStoreDidChange, object: nil)
    }

    private func scan(_ dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? .distantPast
                return da > db          // 新的在前
            }
    }

    /// Documents 根目录下的散图 → 收件箱
    private func adoptLooseFiles() {
        let docs = root.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries
        where Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            let dest = uniqueURL(in: inboxDir, preferredName: url.lastPathComponent)
            try? FileManager.default.moveItem(at: url, to: dest)
        }
    }

    // MARK: - 写入

    /// 保存一个上传。返回落盘后的 URL。
    /// 可能被后台网络线程调用，内部自己切队列。
    ///
    /// importImmediately 由调用方在主线程读好再传进来 —— autoImport 是
    /// @Published，不能在后台队列上读。
    @discardableResult
    func saveUpload(filename: String,
                    data: Data,
                    importImmediately: Bool) -> URL? {
        let safeName = Self.sanitize(filename)
        let ext = (safeName as NSString).pathExtension.lowercased()

        guard Self.imageExtensions.contains(ext) else { return nil }
        guard !data.isEmpty else { return nil }

        var result: URL?
        ioQueue.sync {
            let staged = uniqueURL(in: inboxDir, preferredName: safeName)
            do {
                try data.write(to: staged, options: .atomic)
            } catch {
                return
            }

            makeThumbnail(for: staged)

            result = importImmediately ? moveToMedia(staged) : staged
        }

        refresh()
        return result
    }

    /// 把收件箱里的照片移进媒体库
    @discardableResult
    func importAll() -> Int {
        var count = 0
        ioQueue.sync {
            for url in scan(inboxDir) {
                if moveToMedia(url) != nil { count += 1 }
            }
        }
        refresh()
        return count
    }

    @discardableResult
    func importOne(_ url: URL) -> URL? {
        var result: URL?
        ioQueue.sync { result = moveToMedia(url) }
        refresh()
        return result
    }

    /// 只在 ioQueue 内部调用
    private func moveToMedia(_ url: URL) -> URL? {
        let dest = uniqueURL(in: mediaDir, preferredName: url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    func delete(_ urls: [URL]) {
        ioQueue.sync {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: thumbnailURL(for: url))
            }
        }
        refresh()
    }

    func deleteAllMedia() {
        ioQueue.sync {
            for url in scan(mediaDir) {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: thumbnailURL(for: url))
            }
        }
        refresh()
    }

    // MARK: - 缩略图

    /// 缩略图路径（不一定存在）
    func thumbnailURL(for photo: URL) -> URL {
        thumbsDir.appendingPathComponent(photo.lastPathComponent + ".jpg")
    }

    /// 生成缩略图。已存在则跳过。
    @discardableResult
    func makeThumbnail(for photo: URL, maxDimension: CGFloat = 400) -> URL? {
        let dest = thumbnailURL(for: photo)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        guard let image = Self.downsample(url: photo, maxDimension: maxDimension),
              let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }

        try? jpeg.write(to: dest, options: .atomic)
        return dest
    }

    // MARK: - 图片解码

    /// 按需解码到指定尺寸。
    ///
    /// 用 CGImageSource 而不是 UIImage(contentsOfFile:) —— 后者会把整张原图
    /// 解码进内存，一张 4000×3000 的 JPEG 解码后是 48 MB，低内存的老设备
    /// 连播几张就爆。downsample 只解码到目标尺寸。
    ///
    /// kCGImageSourceCreateThumbnailWithTransform 会应用 EXIF 旋转信息，
    /// 否则竖拍的照片显示出来是躺着的。
    static func downsample(url: URL, maxDimension: CGFloat) -> UIImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOptions) else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as CFDictionary

        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    // MARK: - 工具

    /// 去掉路径成分和危险字符，只留文件名
    static func sanitize(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_. ()[]"))
        let cleaned = base.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .reduce("", +)
        return cleaned.isEmpty ? "photo.jpg" : cleaned
    }

    /// 重名时加 -1 -2 后缀
    private func uniqueURL(in dir: URL, preferredName: String) -> URL {
        let name = Self.sanitize(preferredName)
        var candidate = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while true {
            let next = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            candidate = dir.appendingPathComponent(next)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: - 统计

    var mediaBytes: Int {
        media.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    static func formatBytes(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1024 * 1024 { return String(format: "%.0f KB", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / 1024 / 1024) }
        return String(format: "%.2f GB", b / 1024 / 1024 / 1024)
    }
}

extension Notification.Name {
    /// 媒体库内容发生变化（有新照片入库、或删除了照片）
    static let photoStoreDidChange = Notification.Name("photostation.storeDidChange")
}
