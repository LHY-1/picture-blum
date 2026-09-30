// ============================================================
// PhotoLibraryManager.swift
// 照片来源管理 —— 系统相册 + 上传进来的照片
//
// 刻意不用 async/await：
//   目标 iOS 14，而 Swift 并发运行时需要回移植库
//   （SDK 里 SwiftConcurrencyMinimumDeploymentTarget = 15.0）。
//   更关键的是：非 @MainActor 的 async 函数从主线程 await 后会跳到
//   后台线程执行，在后台线程写 @Published 会导致 UI 更新崩溃。
//   用 GCD 显式指定队列，线程关系一目了然。
//
// 兼容：iOS 14.0+
// ============================================================

import Foundation
import UIKit
import Photos
import Combine
import CommonCrypto

// MARK: - 照片来源

/// 一张照片从哪来
enum SlidePhotoSource {
    case asset(PHAsset)     // 系统相册
    case file(URL)          // 上传进来的，存在 App 自己的 Documents 里
}

/// 表示一张待播放的照片
struct SlidePhoto: Identifiable {
    let id: String
    let source: SlidePhotoSource

    var asset: PHAsset? {
        if case .asset(let a) = source { return a }
        return nil
    }

    var fileURL: URL? {
        if case .file(let url) = source { return url }
        return nil
    }

    /// 界面上显示的名字
    var displayName: String {
        switch source {
        case .asset(let a):
            return a.creationDate.map { Self.dateFormatter.string(from: $0) } ?? "照片"
        case .file(let url):
            return url.deletingPathExtension().lastPathComponent
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

/// 播放哪些照片
enum PhotoSourceMode: Int, CaseIterable, Identifiable {
    case systemAlbum = 0    // 只要系统相册
    case uploaded    = 1    // 只要上传进来的（现在存在系统相册里）
    case both        = 2    // 两者都要

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .systemAlbum: return "系统相册"
        case .uploaded:    return "上传的照片"
        case .both:        return "两者都要"
        }
    }

    /// 需不需要申请相册权限。
    /// 上传的照片现在也存系统相册，所以**每种模式都需要相册权限**。
    var needsPhotoPermission: Bool {
        return true
    }

    /// 这个模式只看上传进来的照片（按 manifest 过滤），还是全要。
    var uploadedOnly: Bool {
        self == .uploaded
    }
}

/// 一个可勾选的相册（用户建的手动相册 + 共享相簿）
struct SlideAlbum: Identifiable {
    let id: String                    // PHAssetCollection.localIdentifier
    let name: String
    let isShared: Bool
    let collection: PHAssetCollection
}

// MARK: - 管理器

class PhotoLibraryManager: ObservableObject {
    @Published var photos: [SlidePhoto] = []
    /// 可勾选的相册（用户相册 + 共享相簿），网格选照片时整册勾选用
    @Published var albums: [SlideAlbum] = []
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// 被去掉的重复项清单（诊断用，设置 → 信息 里能看到）
    @Published private(set) var removedDuplicates: [String] = []

    /// 权限检查失败次数 + 最近一次拿到的状态（诊断用）
    @Published private(set) var permissionFailures = 0
    @Published private(set) var lastPermissionStatus: PHAuthorizationStatus = .notDetermined

    /// 权限重试定时器：运行中遇到权限失败时保持播放，每 60 秒试一次
    private var permissionRetryTimer: Timer?

    /// 回前台时如果有重试在跑，立刻试一次
    private var didBecomeActiveObserver: Any?

    /// 本次运行是否已经弹过系统授权框。
    /// 上传会频繁触发重载；弹过一次还没授权，就不能再弹，
    /// 交给 60 秒重试 + 回前台观察等用户手动授权。
    private var hasPromptedThisSession = false

    /// 去重别名：被去掉的 asset id → 留下的代表 id。
    /// 相册勾选时用它把「相册里的副本 id」归一到「目录里的代表 id」，
    /// 否则选了某相册里被去重掉的那份，播放列表里就找不到那张照片。
    @Published private(set) var aliasToRep: [String: String] = [:]

    /// 当前的照片来源
    @Published var sourceMode: PhotoSourceMode = .both

    /// 单张照片长边像素上限，按当前设备屏幕算（长边 pt × 缩放系数）：
    /// 老设备屏幕小，落在 2000 像素上下，整图解码不爆内存；
    /// 新设备跟着屏幕走，清晰度不打折。
    /// 上限 4096 —— 再往上解码一张主图就要吃掉大量内存，没必要。
    private let maxPixelDimension: CGFloat = {
        let screen = UIScreen.main
        let screenPixels = max(screen.bounds.width, screen.bounds.height) * screen.scale
        return min(max(screenPixels, 1024), 4096)
    }()

    private let localStore = LocalPhotoStore.shared

    // MARK: - 授权

    /// 授权检查，回调一定在主线程执行。
    ///
    /// 老代码直接调老 API `PHPhotoLibrary.requestAuthorization`：它每次都会
    /// 向系统「申请」授权，App 长时间运行后再被触发（后台上传、相册库
    /// 变化、reload）时，系统可能重新弹授权框——这是「跑着跑着又冒出来
    /// 照片权限」的元凶。
    ///
    /// 这里改成按级别先查后问，且**已授权绝不重新弹框**：
    /// 读取端（播图）只需 `.readWrite` 下的「读」级别；写入端（上传进
    /// 相册）只需 `.addOnly`。用户给过任一级别，状态就稳定不再回退。
    func requestAuthorization(force: Bool = false,
                             completion: @escaping () -> Void) {
        let level = PHAccessLevel.readWrite
        let status = PHPhotoLibrary.authorizationStatus(for: level)
        guard status == .notDetermined else {
            DispatchQueue.main.async {
                self.updateStatus(status)
                completion()
            }
            return
        }

        guard force || !hasPromptedThisSession else {
            // 弹过一次还没授权：不再打扰。后台上传触发的重载可能
            // 隔 1.5 秒又来一次，每次都弹会把用户弹烦——
            // 交给 60 秒重试 / 回前台 / 设置里的「重新申请」去接。
            DispatchQueue.main.async {
                self.updateStatus(status)
                completion()
            }
            return
        }

        hasPromptedThisSession = true
        PHPhotoLibrary.requestAuthorization(for: level) { [weak self] s in
            DispatchQueue.main.async {
                self?.updateStatus(s)
                completion()
            }
        }
    }

    /// 权限失败后的恢复入口：60 秒重试定时器 + 回前台时各调一次。
    /// 只查不弹——被拒的情况下系统不允许 App 自己再弹。
    /// 用户去「设置 → 照片」里开了权限，这里就能查到并重载照片。
    func retryAuthorization() {
        let level = PHAccessLevel.readWrite
        let status = PHPhotoLibrary.authorizationStatus(for: level)
        DispatchQueue.main.async {
            self.updateStatus(status)
        }
        guard status == .authorized || status == .limited else { return }
        guard !self.isLoading else { return }
        self.stopPermissionRetry()
        // 接上了：刷新一遍目录。播放队列没被动过（失败时不清），
        // 相框从头就没断过，这里只是把新照片并进目录。
        self.loadAllPhotos(mode: self.sourceMode, completion: nil)
    }

    private func startPermissionRetry() {
        guard permissionRetryTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.retryAuthorization()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionRetryTimer = timer

        if didBecomeActiveObserver == nil {
            didBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self = self, self.permissionRetryTimer != nil else { return }
                self.retryAuthorization()
            }
        }
    }

    private func stopPermissionRetry() {
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            didBecomeActiveObserver = nil
        }
    }

    private func updateStatus(_ status: PHAuthorizationStatus) {
        authorizationStatus = status
        lastPermissionStatus = status
        if status == .authorized || status == .limited {
            permissionFailures = 0
            hasPromptedThisSession = false
        }
    }

    deinit {
        stopPermissionRetry()
    }

    private var hasPhotoPermission: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    /// 对外版本（设置界面判断权限状态用）
    var hasPermissionPublic: Bool { hasPhotoPermission }

    /// 当前相册权限，给设置「信息」区看的 —— 出权限问题时一眼能判断
    var permissionDescription: String {
        switch authorizationStatus {
        case .notDetermined: return "未询问"
        case .restricted:    return "受限（家长控制）"
        case .denied:        return "已拒绝"
        case .authorized:    return "全部访问"
        case .limited:       return "仅限选中的照片"
        @unknown default:    return "未知"
        }
    }

    // MARK: - 加载照片

    /// 按当前来源加载照片列表。回调在主线程执行。
    ///
    /// 上传的照片排在前面 —— 刚传进来的应该马上看到，
    /// 而不是埋在几千张相册照片后面。
    func loadAllPhotos(mode: PhotoSourceMode? = nil, completion: (() -> Void)? = nil) {
        let mode = mode ?? sourceMode
        sourceMode = mode

        errorMessage = nil
        isLoading = true

        // 每种模式都需要相册权限，统一走授权检查
        requestAuthorization { [weak self] in
            guard let self = self else { return }

            guard self.hasPhotoPermission else {
                // 没相册权限。
                // 已有照片（播放中途被拒 / addOnly 误报）：保持播放 + 60 秒重试
                //   权限，不清队列 —— 相框不能因为权限问题整体罢工。
                // 一张都没有（启动时就被拒）：给明确提示。
                self.permissionFailures += 1
                self.startPermissionRetry()
                if self.photos.isEmpty {
                    self.errorMessage = "请在系统设置里授予相册访问权限"
                    self.isLoading = false
                    completion?()
                }
                return
            }

            // 取相册数据可能耗时（几万张时），放后台队列
            DispatchQueue.global(qos: .userInitiated).async {
                let options = PHFetchOptions()
                options.sortDescriptors = [
                    NSSortDescriptor(key: "creationDate", ascending: false)
                ]

                // 上传的照片按登记表匹配出来的那批 asset
                let uploadedPhotos = self.localSlidePhotos()
                let uploadedIDs = Set(uploadedPhotos.map { $0.id })

                let result = PHAsset.fetchAssets(with: .image, options: options)

                // ── 1. 收齐候选（按 localIdentifier 去重）──
                var candidates: [SlidePhoto] = []
                var seen = Set<String>()

                result.enumerateObjects { asset, _, _ in
                    let id = asset.localIdentifier
                    guard seen.insert(id).inserted else { return }
                    candidates.append(SlidePhoto(id: id, source: .asset(asset)))
                }

                // 共享相簿的照片不一定在全局列表里（没下载到「图库」），
                // 显式查出来补上。
                let sharedCollections = PHAssetCollection.fetchAssetCollections(
                    with: .album,
                    subtype: .albumCloudShared,
                    options: nil)
                sharedCollections.enumerateObjects { collection, _, _ in
                    let sharedOptions = PHFetchOptions()
                    sharedOptions.sortDescriptors = [
                        NSSortDescriptor(key: "creationDate", ascending: false)
                    ]
                    let assets = PHAsset.fetchAssets(
                        in: collection, options: sharedOptions)
                    assets.enumerateObjects { asset, _, _ in
                        guard asset.mediaType == .image else { return }
                        let id = asset.localIdentifier
                        guard seen.insert(id).inserted else { return }
                        candidates.append(SlidePhoto(id: id, source: .asset(asset)))
                    }
                }

                // 可勾选的相册列表：
                //   用户建的普通相册 + 共享相簿 + 系统智能相册
                //   （收藏、自拍、全景、连拍、截图、自定义智能相册）
                var albumList: [SlideAlbum] = []

                let userAlbums = PHAssetCollection.fetchAssetCollections(
                    with: .album,
                    subtype: .albumRegular,
                    options: nil)
                userAlbums.enumerateObjects { collection, _, _ in
                    albumList.append(SlideAlbum(
                        id: collection.localIdentifier,
                        name: collection.localizedTitle ?? "相册",
                        isShared: false,
                        collection: collection))
                }

                // 系统智能相册。空的不列出来——勾了也没照片
                let smartSubtypes: [PHAssetCollectionSubtype] = [
                    .smartAlbumFavorites,
                    .smartAlbumSelfPortraits,
                    .smartAlbumPanoramas,
                    .smartAlbumBursts,
                    .smartAlbumScreenshots,
                    .smartAlbumRecentlyAdded,
                    .smartAlbumUserLibrary
                ]
                for sub in smartSubtypes {
                    let smart = PHAssetCollection.fetchAssetCollections(
                        with: .smartAlbum,
                        subtype: sub,
                        options: nil)
                    smart.enumerateObjects { collection, _, _ in
                        guard PHAsset.fetchAssets(
                            in: collection, options: nil).count > 0 else { return }
                        albumList.append(SlideAlbum(
                            id: collection.localIdentifier,
                            name: collection.localizedTitle ?? "智能相册",
                            isShared: false,
                            collection: collection))
                    }
                }

                sharedCollections.enumerateObjects { collection, _, _ in
                    albumList.append(SlideAlbum(
                        id: collection.localIdentifier,
                        name: collection.localizedTitle ?? "共享相簿",
                        isShared: true,
                        collection: collection))
                }

                // ── 2. 分组：同一天 的照片可能互为副本 ──
                // 共享件的 iCloud 中间码流常常和原图尺寸不同，
                // 所以不再要求「同尺寸」才进同桶——只要同一天
                // （EXIF 时间戳相同），就都送去哈希精确比较。
                // 单张的一天（不可能有副本）直接收，不花算力。
                func bucketKey(of photo: SlidePhoto) -> String? {
                    guard case .asset(let a) = photo.source,
                          let t = a.creationDate else { return nil }
                    // 砍到「天」
                    let dayStamp = (t.timeIntervalSinceReferenceDate / 86400)
                        .rounded() * 86400
                    return "d:\(dayStamp)"
                }

                var buckets: [String: [Int]] = [:]
                var solo: [SlidePhoto] = []
                for (i, photo) in candidates.enumerated() {
                    if let key = bucketKey(of: photo) {
                        buckets[key, default: []].append(i)
                    } else {
                        solo.append(photo)
                    }
                }

                // ── 3. 同天多张：内容哈希精确判重 ──
                // 同一张的两个副本像素一模一样，640px 下采样的
                // md5 必相同；不同照片就算同天，像素全等概率≈0。
                let multiIndices = buckets.filter { $0.value.count > 1 }
                    .flatMap { $0.value }
                var md5s: [Int: String] = [:]
                let lock = NSLock()
                if !multiIndices.isEmpty {
                    DispatchQueue.concurrentPerform(iterations: multiIndices.count) { j in
                        let idx = multiIndices[j]
                        if let hash = Self.contentFingerprint(candidates[idx]) {
                            lock.lock()
                            md5s[idx] = hash
                            lock.unlock()
                        }
                    }
                }

                // 粗判兜底键（哈希失败时用）：同「小时+尺寸」才敢留一份
                func coarseKey(of photo: SlidePhoto) -> String? {
                    guard case .asset(let a) = photo.source,
                          let t = a.creationDate else { return nil }
                    let hrStamp = (t.timeIntervalSinceReferenceDate / 3600)
                        .rounded() * 3600
                    return "c:\(hrStamp)|\(a.pixelWidth)x\(a.pixelHeight)"
                }

                var kept: [SlidePhoto] = solo
                var duplicatesLog: [String] = []
                var aliasMap: [String: String] = [:]    // 被去掉的 id → 留下的代表 id

                for (key, indices) in buckets {
                    var keptHashes = Set<String>()
                    var hashToRep: [String: String] = [:]
                    var coarseKept = Set<String>()
                    var coarseToRep: [String: String] = [:]
                    for i in indices {
                        let photo = candidates[i]
                        if let hash = md5s[i] {
                            // 精确判：像素哈希相同才算同一张
                            if keptHashes.insert(hash).inserted {
                                kept.append(photo)
                                hashToRep[hash] = photo.id
                            } else {
                                duplicatesLog.append("\(photo.id) ~ hash")
                                aliasMap[photo.id] = hashToRep[hash] ?? photo.id
                            }
                        } else {
                            // 拿不到像素（iCloud 未下载）：退回「小时+尺寸」
                            // 同组最多留一份
                            let ck = coarseKey(of: photo) ?? "c:none"
                            if coarseKept.insert(ck).inserted {
                                kept.append(photo)
                                coarseToRep[ck] = photo.id
                            } else {
                                duplicatesLog.append("\(photo.id) ~ \(ck)")
                                aliasMap[photo.id] = coarseToRep[ck] ?? photo.id
                            }
                        }
                    }
                }

                // 全局列表原来按创建时间倒序，分组后重排回原顺序
                kept.sort { a, b in
                    guard case .asset(let aa) = a.source,
                          case .asset(let bb) = b.source else { return false }
                    return (aa.creationDate ?? .distantPast) > (bb.creationDate ?? .distantPast)
                }

                // 回到主线程再改 @Published 属性
                DispatchQueue.main.async {
                    // 按来源模式拼最终列表：
                    //   上传的 → 只有 manifest 匹配到的
                    //   相册的 → 全库减掉上传的（避免重复）
                    //   两者   → 全库，上传的排前面（刚传进来的先看到）
                    let rest = kept.filter { !uploadedIDs.contains($0.id) }
                    let finalList: [SlidePhoto]
                    switch mode {
                    case .uploaded:
                        finalList = uploadedPhotos
                    case .systemAlbum:
                        finalList = rest
                    case .both:
                        finalList = uploadedPhotos + rest
                    }

                    self.photos = finalList
                    self.albums = albumList
                    self.removedDuplicates = duplicatesLog
                    self.aliasToRep = aliasMap
                    // 一张都没有：给真实提示，不误报「需要授权」
                    self.errorMessage = finalList.isEmpty
                        ? (mode == .uploaded
                           ? "还没有上传的照片。开「上传服务」从手机传几张进来。"
                           : "系统相册里没找到照片（共享相簿也算进去了）。")
                        : nil
                    self.isLoading = false
                    completion?()
                }
            }
        }
    }

    /// 把「上传的照片」查出来 —— 它们存在系统相册里，
    /// 按 manifest 登记的名字匹配。
    ///
    /// 匹配用 PHAssetResource.assetResources(for:) 的资源 originalFilename
    /// （这是正式的公开 API；KVC 的 "filename" 键在 14.8 上
    /// 对导入图不生效，查出来是空的）。
    /// 先按「最近 7 天」缩范围，再逐个核对资源名。
    private func localSlidePhotos() -> [SlidePhoto] {
        let store = localStore
        let names = Set(store.entries.map { $0.name })
        guard !names.isEmpty else { return [] }

        // 粗筛：近 7 天（上传的就是最近进来的）
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate > %@",
            NSDate(timeIntervalSinceNow: -7 * 86400))

        let result = PHAsset.fetchAssets(with: .image, options: options)
        guard result.count > 0 else { return [] }

        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        // 逐个拿资源文件名（公开 API，只读 photo 资源）
        var fileNamesByAsset: [String: [String]] = [:]
        for asset in assets {
            for res in PHAssetResource.assetResources(for: asset) where res.type == .photo {
                fileNamesByAsset[asset.localIdentifier, default: []]
                    .append(res.originalFilename)
            }
        }

        var photos: [SlidePhoto] = []
        var seen = Set<String>()
        for asset in assets {
            let assetNames = fileNamesByAsset[asset.localIdentifier] ?? []
            let matchedName = assetNames.first { names.contains($0) }
            guard let matchedName, seen.insert(matchedName).inserted else {
                continue
            }
            photos.append(SlidePhoto(id: asset.localIdentifier,
                                     source: .asset(asset)))
        }
        return photos
    }

    // MARK: - 加载单张照片

    /// 异步加载某张照片的完整数据，回调在主线程执行
    func loadImage(for photo: SlidePhoto, complete: @escaping (UIImage?) -> Void) {
        switch photo.source {

        case .file(let url):
            // 本地文件：按需解码到屏幕尺寸，不整张读进内存
            DispatchQueue.global(qos: .userInitiated).async {
                let image = LocalPhotoStore.downsample(
                    url: url, maxDimension: self.maxPixelDimension)
                DispatchQueue.main.async { complete(image) }
            }

        case .asset(let asset):
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true          // 支持 iCloud 照片
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast

            // 尺寸限制，防止大图占用太多内存。
            // targetSize 是 requestImage 的参数，不是 PHImageRequestOptions 的属性。
            let pixelW = CGFloat(asset.pixelWidth)
            let pixelH = CGFloat(asset.pixelHeight)
            let longest = max(pixelW, pixelH)

            // scale 上限 1.0 —— 小图不做放大请求，避免无谓的解码开销
            let scale = longest > 0 ? min(1.0, maxPixelDimension / longest) : 1.0
            let targetSize = CGSize(width: pixelW * scale, height: pixelH * scale)

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                DispatchQueue.main.async { complete(image) }
            }
        }
    }

    // MARK: - 内容指纹（去重用）

    /// 把照片下采样到 640px 算 md5。
    ///
    /// 同一张照片的两个副本（共享项 + 图库副本）像素完全一致，
    /// 哈希必相同；不同的照片就算同时间、同尺寸，640px 像素
    /// 全等的概率约等于零。这是 iOS 14 上能拿到的最精确判据
    /// （PHAsset.cloudIdentifier 要 iOS 15 才有）。
    ///
    /// 传 nil 的代价：拿不到像素（iCloud 没下载 + 无网）→
    /// 返回 nil，调用方退回粗判。
    static func contentFingerprint(_ photo: SlidePhoto) -> String? {
        let maxDim: CGFloat = 640
        var image: UIImage?

        switch photo.source {
        case .file(let url):
            image = LocalPhotoStore.downsample(url: url, maxDimension: maxDim)
        case .asset(let asset):
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            // 目标尺寸给得远小于真实像素，只取缩略图
            let target = CGSize(width: maxDim, height: maxDim)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { img, _ in
                image = img
            }
        }

        guard let pixels = downsampledPixels(image, maxDim: maxDim) else {
            return nil
        }
        return md5Hex(pixels)
    }

    /// 取图的原始像素（不做缩放）供哈希。
    /// opportunistic 模式下 UIImage 可能是渐进式解码器，
    /// 直接取 cgImage 拿到的就是当前这一档的像素。
    private static func downsampledPixels(_ image: UIImage?, maxDim: CGFloat) -> [UInt8]? {
        guard let cg = image?.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }

        // 取小图再算，数据量 = w*h*4，640px 上限约 1.6 MB
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    private static func md5Hex(_ data: [UInt8]) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBufferPointer { buf in
            _ = CC_MD5(buf.baseAddress, UInt32(buf.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 加载缩略图（网格列表用），回调在主线程执行
    func loadThumbnail(for photo: SlidePhoto,
                       size: CGSize,
                       complete: @escaping (UIImage?) -> Void) {
        switch photo.source {

        case .file(let url):
            DispatchQueue.global(qos: .userInitiated).async {
                let maxDimension = max(size.width, size.height) * UIScreen.main.scale
                let image = LocalPhotoStore.downsample(
                    url: url, maxDimension: maxDimension)
                DispatchQueue.main.async { complete(image) }
            }

        case .asset(let asset):
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic          // 先给小图，再给大图
            options.isNetworkAccessAllowed = true

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                DispatchQueue.main.async { complete(image) }
            }
        }
    }
}
