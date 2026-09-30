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

    /// 重新扫收件箱。会顺手收编 Documents 根目录下的散图
    /// （用「文件」App 或 Finder 拖进来的照片会落在那里）。
    func refresh() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }

            self.adoptLooseFiles()

            let inbox = self.scanDir(self.inboxDir)

            DispatchQueue.main.async {
                self.apply(inbox: inbox)
            }
        }
    }

    /// 只在主线程调用。真的有变化才广播，避免无谓的重载。
    private func apply(inbox: [URL]) {
        let sig = "inbox:" + inbox.map { $0.lastPathComponent }
            .joined(separator: "|") + "||entries:" + entriesSignature()
        let isFirstScan = !hasScannedOnce
        let changed = sig != signature

        self.inbox = inbox
        signature = sig
        hasScannedOnce = true

        // 首次扫描不广播 —— 启动流程自己会加载一遍
        guard changed, !isFirstScan else { return }
        NotificationCenter.default.post(name: .photoStoreDidChange, object: nil)
    }

    private func entriesSignature() -> String {
        entries.map { "\($0.name)|\($0.assetID ?? "-")" }
            .joined(separator: "|")
    }

    private func scanDir(_ dir: URL) -> [URL] {
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
        guard let loose = try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in loose
        where Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            let dest = uniqueURL(in: inboxDir, preferredName: url.lastPathComponent)
            try? FileManager.default.moveItem(at: url, to: dest)
        }
    }

    // MARK: - 写入（进系统相册）

    /// 保存一个上传。大图直接写进系统相册，本地只留小缩略图 + 登记。
    /// 可能被后台网络线程调用，内部自己切队列。
    ///
    /// importImmediately 由调用方在主线程读好再传进来 —— autoImport 是
    /// @Published，不能在后台队列上读。
    /// 返回 1 = 成功（进了相册或进了收件箱），0 = 失败。
    @discardableResult
    func saveUpload(filename: String,
                   data: Data,
                   importImmediately: Bool) -> Int {
        let safeName = Self.sanitize(filename)
        let ext = (safeName as NSString).pathExtension.lowercased()

        guard Self.imageExtensions.contains(ext) else { return 0 }
        guard !data.isEmpty else { return 0 }

        // 1. 大图写进系统相册（「添加照片」权限，不动已有内容）。
        // 用 PHAssetCreationRequest 直接塞数据资源，不解码原图
        // （iPad Air 2 上整图解码一张大图太费内存）。
        var didAddToAlbum = false
        PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            let resOptions = PHAssetResourceCreationOptions()
            resOptions.originalFilename = safeName
            // data 版（不解码原图）：直接塞原始字节
            _ = creation.addResource(with: .photo, data: data,
                                      options: resOptions)
            didAddToAlbum = creation.placeholderForCreatedAsset != nil
        }

        // 2. 本地留小缩略图（网页和网格用）。
        //    写进临时文件再解码，不占 Documents
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
        } catch {
            return 0
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        ioQueue.sync {
            if importImmediately, didAddToAlbum {
                addEntry(name: safeName, bytes: data.count)
            }
            _ = makeThumbnailForName(safeName, sourceURL: tmp)
        }
        persistEntries()

        refresh()
        return 1
    }

    private func addEntry(name: String, bytes: Int) {
        // 同名不重复登记
        if entries.contains(where: { $0.name == name }) { return }
        entries.append(MediaEntry(name: name, assetID: nil, bytes: bytes))
    }

    /// 回填 assetID：把登记表里还没记录 id 的照片，
    /// 到系统相册里按资源文件名找出来。
    func resolveAssetIDs() {
        guard entries.contains(where: { $0.assetID == nil }) else { return }

        ioQueue.async { [weak self] in
            guard let self = self else { return }

            let missing = self.entries.filter { $0.assetID == nil }
            guard !missing.isEmpty else { return }
            let names = Set(missing.map { $0.name })

            // 近 3 天 + 资源文件名比对（KVC "filename" 键在 14.8 上
            // 对导入图查不出来，用公开 API 的 originalFilename）
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "creationDate > %@",
                NSDate(timeIntervalSinceNow: -3 * 86400))
            let result = PHAsset.fetchAssets(with: .image, options: options)

            var byName: [String: String] = [:]
            result.enumerateObjects { asset, _, _ in
                for res in PHAssetResource.assetResources(for: asset)
                where res.type == .photo {
                    byName[res.originalFilename] = asset.localIdentifier
                }
            }

            var found = false
            DispatchQueue.main.async {
                for i in self.entries.indices
                where self.entries[i].assetID == nil {
                    if let id = byName[self.entries[i].name] {
                        self.entries[i].assetID = id
                        found = true
                    }
                }
                if found {
                    self.persistEntries()
                }
            }
        }
    }

    /// 有本地文件就立刻出缩略图（同步）。
    /// 本地没有的（相册里的）走 generateThumbnailForNameAsync。
    @discardableResult
    func makeThumbnailForName(_ name: String,
                              sourceURL: URL?) -> URL? {
        guard let sourceURL else { return nil }
        let dest = thumbnailURLForName(name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        guard let image = Self.downsample(url: sourceURL, maxDimension: 400),
              let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        try? jpeg.write(to: dest, options: .atomic)
        return dest
    }

    /// 本地没有大图，缩略图直接从「相册 asset」生成（异步，
    /// 因为 PHImageManager 没有同步出图的公开 API）
    func generateThumbnailForNameAsync(_ name: String,
                                       complete: @escaping (URL?) -> Void) {
        let stem = (name as NSString).deletingPathExtension
        let dest = thumbsDir.appendingPathComponent(stem + ".jpg")
        if FileManager.default.fileExists(atPath: dest.path) {
            DispatchQueue.main.async { complete(dest) }
            return
        }

        // 找相册 asset：近 30 天粗筛 + 资源文件名精确核对
        //（KVC "filename" 谓词在 14.8 上对导入图查不出来）
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate > %@",
            NSDate(timeIntervalSinceNow: -30 * 86400))
        let result = PHAsset.fetchAssets(with: .image, options: options)

        var targetAsset: PHAsset?
        result.enumerateObjects { asset, _, _ in
            for res in PHAssetResource.assetResources(for: asset) {
                guard res.type == .photo, res.originalFilename == name
                else { continue }
                targetAsset = asset
            }
        }
        guard let asset = targetAsset else {
            DispatchQueue.main.async { complete(nil) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var jpeg: Data?
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .fastFormat
            opts.resizeMode = .fast
            PHImageManager.default().requestImageData(
                for: asset,
                options: opts,
                resultHandler: { data, _, _, _ in
                    guard let data else {
                        DispatchQueue.main.async { complete(nil) }
                        return
                    }
                    // 后台解码成 400px 再压 jpeg
                    let tmpURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(UUID().uuidString)")
                    do {
                        try data.write(to: tmpURL)
                        if let img = Self.downsample(url: tmpURL, maxDimension: 400) {
                            jpeg = img.jpegData(compressionQuality: 0.8)
                        }
                        try? FileManager.default.removeItem(at: tmpURL)
                    } catch {}
                    DispatchQueue.main.async {
                        guard let jpeg else {
                            complete(nil)
                            return
                        }
                        let dest = self.thumbnailURLForName(name)
                        try? jpeg.write(to: dest, options: .atomic)
                        self.refresh()
                        complete(dest)
                    }
                })
        }
    }

    /// 缩略图路径（按名字）
    func thumbnailURLForName(_ name: String) -> URL {
        thumbsDir.appendingPathComponent(
            (name as NSString).deletingPathExtension + ".jpg")
    }

    /// 把收件箱里待导入的文件写进系统相册。
    /// 成功一张删一张本地文件（大图不留在本地），生成缩略图 + 登记。
    @discardableResult
    func importAll() -> Int {
        var count = 0
        ioQueue.sync {
            let files = scanDir(inboxDir)
            count = files.filter { importOneLocked($0) }.count
        }
        persistEntries()
        refresh()
        resolveAssetIDs()
        return count
    }

    @discardableResult
    func importOne(_ url: URL) -> Int {
        var result = 0
        ioQueue.sync {
            if importOneLocked(url) { result = 1 }
        }
        persistEntries()
        refresh()
        resolveAssetIDs()
        return result
    }

    /// 写相册 + 登记 + 生成缩略图 + 删本地文件。
    /// 调用方必须已在 ioQueue 里。相册写入是同步语义：
    /// performChanges 主线程调用（HTTP handler 可能跑在后台队列，
    /// 但 PHPhotoLibrary.performChanges 本身线程安全）。
    private func importOneLocked(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let name = url.lastPathComponent

        var didAdd = false
        PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            let resOptions = PHAssetResourceCreationOptions()
            resOptions.originalFilename = name
            _ = creation.addResource(with: .photo, data: data,
                                     options: resOptions)
            didAdd = creation.placeholderForCreatedAsset != nil
        }

        guard didAdd else { return false }

        addEntry(name: name, bytes: data.count)
        _ = makeThumbnailForName(name, sourceURL: url)
        try? FileManager.default.removeItem(at: url)
        saveEntriesLocked()
        return true
    }

    /// 删一张（按名字）：清本地缩略图 + 登记；
    /// 系统相册里的那张留给用户自己删，我们不碰相册里的原图。
    func delete(named name: String) {
        ioQueue.sync {
            try? FileManager.default.removeItem(
                at: thumbsDir.appendingPathComponent(
                    (name as NSString).deletingPathExtension + ".jpg"))
            entries.removeAll { $0.name == name }
            saveEntriesLocked()
        }
        refresh()
    }

    /// 删收件箱里的文件（还没进相册的）
    func deleteInbox(_ urls: [URL]) {
        ioQueue.sync {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(
                    at: thumbnailURL(for: url))
            }
        }
        refresh()
    }

    /// 清空本地登记（不删相册里的照片）
    func deleteAllEntries() {
        ioQueue.sync {
            for e in entries {
                try? FileManager.default.removeItem(
                    at: thumbsDir.appendingPathComponent(
                        (e.name as NSString).deletingPathExtension + ".jpg"))
            }
            entries.removeAll()
            saveEntriesLocked()
        }
        refresh()
    }

    // MARK: - 缩略图

    /// 缩略图路径（不一定存在）
    func thumbnailURL(for photo: URL) -> URL {
        thumbsDir.appendingPathComponent(photo.lastPathComponent + ".jpg")
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
        entries.reduce(0) { $0 + $1.bytes }
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
