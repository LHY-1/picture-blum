// ============================================================
// SlideShowViewModel.swift
// 幻灯片播放逻辑 - 状态管理、定时、控制
//
// 兼容：iOS 14.0+
// ============================================================

import Foundation
import UIKit
import SwiftUI
import Photos
import Combine

enum RepeatMode: Int, CaseIterable, Identifiable {
    case none      = 0     // 播完停止
    case current   = 1     // 循环当前照片
    case all       = 2     // 循环全部

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none:    return "顺序"
        case .current: return "当前"
        case .all:     return "全部"
        }
    }
}

/// 照片切换动画
///
/// 滑动的方向由「最近一次前进还是后退」决定（见 ViewModel.lastDirection）：
/// 下一张时新照片从右滑入、旧照片向左滑出；上一张时反过来。
enum TransitionStyle: Int, CaseIterable, Identifiable {
    case none          = 0   // 无动画，直接切
    case crossDissolve = 1   // 溶解
    case slide         = 2   // 滑动
    case zoom          = 3   // 缩放

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none:          return "无"
        case .crossDissolve: return "溶解"
        case .slide:         return "滑动"
        case .zoom:          return "缩放"
        }
    }

    /// 切换动画曲线；nil = 无动画直接切
    var animation: Animation? {
        switch self {
        case .none:          return nil
        case .crossDissolve: return .easeInOut(duration: 0.8)
        case .slide:         return .easeInOut(duration: 0.45)
        case .zoom:          return .easeInOut(duration: 0.5)
        }
    }

    /// 单个图层的入场 + 退场。direction：1 = 看下一张（新照片从右进、旧往左出），
    /// -1 = 看上一张（反过来）。
    ///
    /// 溶解 / 缩放都带 opacity —— 新图层是「加载完成后才出现」的，
    /// 带 opacity 让它淡入，而不是突然弹出。
    func layerTransition(direction: CGFloat) -> AnyTransition {
        switch self {
        case .none:
            return .identity
        case .crossDissolve:
            return .opacity
        case .slide:
            // 旧图层往对边滑走（纯位移，不带 opacity）
            // 新图层从对边滑入并淡入
            return .asymmetric(
                insertion: .move(edge: direction >= 0 ? .trailing : .leading)
                    .combined(with: .opacity),
                removal: .move(edge: direction >= 0 ? .leading : .trailing))
        case .zoom:
            return .asymmetric(
                insertion: .scale(scale: 0.85).combined(with: .opacity),
                removal: .scale(scale: 1.12).combined(with: .opacity))
        }
    }
}

class SlideShowViewModel: ObservableObject {
    // MARK: - 依赖
    @Published var library = PhotoLibraryManager()
    @Published var schedule = FrameSchedule()

    // MARK: - 播放状态
    @Published var currentPhoto: SlidePhoto?
    @Published var currentImage: UIImage?
    /// currentImage 属于哪张照片。切图瞬间它仍指着旧照片，
    /// 视图拿这个判断旧图层要不要留在屏幕上；加载完成后才换成新照片。
    @Published var currentImagePhotoID: String?
    @Published var isPlaying = false
    @Published var isCurrentImageLoading = false

    /// 定时器状态的镜像，供视图直接观察（避免嵌套 ObservableObject 不刷新的问题）
    @Published private(set) var scheduleActive = true

    // MARK: - 播放设置
    @Published var interval: TimeInterval = 5       // 每张停留秒数
    @Published var repeatMode: RepeatMode = .all    // 循环模式
    @Published var isShuffle = false                 // 随机播放
    @Published var keepsScreenOn = true              // 播放时防止自动息屏
    @Published var loadTimeout: TimeInterval = 10    // 单张加载超时（0 = 关闭）

    /// 照片切换动画。和 photoSourceMode 一样走 didSet 落盘。
    @Published var transitionStyle: TransitionStyle {
        didSet {
            guard oldValue != transitionStyle else { return }
            PlaybackStore.transitionStyle = transitionStyle.rawValue
        }
    }

    /// 预加载深度：播放时提前解码后面几张（0 = 关，1 = 下一张，默认）。
    @Published var preloadDepth: Int {
        didSet {
            guard oldValue != preloadDepth else { return }
            PlaybackStore.preloadDepth = preloadDepth
        }
    }

    /// 内存缓存上限（张大图）。
    @Published var cacheLimit: Int {
        didSet {
            guard oldValue != cacheLimit else { return }
            PlaybackStore.cacheLimit = cacheLimit
            ImageCache.shared.setCountLimit(cacheLimit)
        }
    }

    // MARK: - 背景音乐
    @Published var musicEnabled: Bool {
        didSet {
            guard oldValue != musicEnabled else { return }
            PlaybackStore.musicEnabled = musicEnabled
            applyMusic()
        }
    }

    /// 选中的歌曲文件名。整队循环播放。
    @Published var musicSongs: [String] {
        didSet {
            guard oldValue != musicSongs else { return }
            PlaybackStore.musicSongs = musicSongs
            applyMusic()
        }
    }

    @Published var musicVolume: Double {
        didSet {
            guard oldValue != musicVolume else { return }
            MusicPlayer.shared.volume = musicVolume
        }
    }

    /// 主题。0 = 深色（相框默认），1 = 浅色。
    @Published var theme: Int {
        didSet {
            guard oldValue != theme else { return }
            PlaybackStore.theme = theme
            // 直接落到 UIWindow 上 —— 正在显示的设置面板
            // 才不会因 iOS 14 的 preferredColorScheme 坑而不跟变
            ThemeManager.apply(theme: theme)
        }
    }

    /// 视图层用的 ColorScheme
    var colorScheme: ColorScheme {
        theme == 1 ? .light : .dark
    }

    /// 播放状态镜像（MusicPlayer 是单独的 ObservableObject，
    /// 视图只 watch viewModel，这里同步一份）
    @Published private(set) var isMusicPlaying = false
    @Published private(set) var currentMusicSong = ""

    /// 最近一次前进 / 后退的方向（1 = 下一张，-1 = 上一张）。
    /// 滑动动画拿它决定照片往哪边飞，不做 @Published —— 视图不需要观察它。
    var lastDirection: CGFloat = 1

    /// 照片来源：系统相册 / 上传进来的 / 两者都要
    @Published var photoSourceMode: PhotoSourceMode {
        didSet {
            guard oldValue != photoSourceMode else { return }
            PlaybackStore.sourceMode = photoSourceMode.rawValue
            // 延迟出 view update 事务 —— Picker 是在渲染更新中调 setter 的，
            // reloadLibrary 会同步改 library.isLoading 这个 @Published，
            // 当场改会触发 "Modifying state during view update" 崩溃。
            DispatchQueue.main.async { self.reloadLibrary() }
        }
    }

    // MARK: - UI 状态
    @Published var showControls = true
    @Published var showSettings = false
    @Published var showPhotoPicker = false

    // MARK: - 播放队列（对外可读）
    @Published private(set) var currentOrder: [SlidePhoto] = []
    private(set) var currentPhotoIndex: Int = 0

    // MARK: - 内部状态
    private var timer: Timer?
    private var shuffledOrder: [SlidePhoto] = []
    private var autoHideWorkItem: DispatchWorkItem?
    private var loadTimeoutWorkItem: DispatchWorkItem?
    private var uploadRefreshWorkItem: DispatchWorkItem?
    private var loadToken = UUID()
    private var cancellables = Set<AnyCancellable>()
    private var musicLibraryObserver: Any?

    // MARK: - 生命周期

    init() {
        // 注意：init 里赋值不会触发 didSet，所以这里安全。
        // 先把所有存储属性赋值完，再调 ImageCache —— Swift 要求
        // self 完全初始化后才能在表达式里读自己的属性。
        photoSourceMode = PhotoSourceMode(rawValue: PlaybackStore.sourceMode) ?? .both
        transitionStyle = TransitionStyle(rawValue: PlaybackStore.transitionStyle) ?? .slide
        preloadDepth = PlaybackStore.preloadDepth
        cacheLimit = PlaybackStore.cacheLimit
        musicEnabled = PlaybackStore.musicEnabled
        musicSongs = PlaybackStore.musicSongs
        musicVolume = PlaybackStore.musicVolume
        theme = PlaybackStore.theme
        ImageCache.shared.setCountLimit(PlaybackStore.cacheLimit)
        observeSchedule()
        observeUploads()
        observeMusic()
        observeMusicLibrary()
    }

    deinit {
        timer?.invalidate()
        autoHideWorkItem?.cancel()
        loadTimeoutWorkItem?.cancel()
        uploadRefreshWorkItem?.cancel()
        if let o = musicLibraryObserver {
            NotificationCenter.default.removeObserver(o)
        }
        NotificationCenter.default.removeObserver(self)
        cancellables.removeAll()
        // 恢复系统默认息屏行为
        UIApplication.shared.isIdleTimerDisabled = false
        MusicPlayer.shared.stop()
    }

    // MARK: - 启动

    /// 启动播放。用回调而非 async —— 见 PhotoLibraryManager 顶部注释。
    func start() {
        library.loadAllPhotos(mode: photoSourceMode) { [weak self] in
            guard let self = self else { return }
            guard !self.library.photos.isEmpty else { return }

            self.rebuildOrder()
            self.restoreLastPosition()

            // 背景音乐：开关是开着的就把选中的歌放起来
            self.applyMusic()

            // 相框场景：上次在播 + 当前在时段内 → 直接开播
            if PlaybackStore.wasPlaying && self.schedule.isActive {
                self.play()
            } else {
                self.pause()
            }
        }
    }

    /// 重新加载照片并从头播放
    /// 重新加载照片并从头播放。
    /// 设置里的「刷新相册」调这个：清掉之前选过的播放子集，
    /// 回到全量库。
    func reloadLibrary() {
        selectedSubset = []
        library.loadAllPhotos(mode: photoSourceMode) { [weak self] in
            self?.restart()
        }
    }

    /// 重新加载但停在当前这张。
    ///
    /// 后台传进来一张新照片时用这个 —— 相框正播到一半被打回第一张
    /// 是很糟糕的体验，新照片插进队列就行，位置不用动。
    private func reloadPreservingPosition() {
        let currentId = currentPhoto?.id

        library.loadAllPhotos(mode: photoSourceMode) { [weak self] in
            guard let self = self else { return }
            self.rebuildOrder()

            if let id = currentId,
               let index = self.currentOrder.firstIndex(where: { $0.id == id }) {
                self.showPhoto(at: index)
            } else {
                self.showPhoto(at: 0)
            }
            if self.isPlaying { self.scheduleNext() }
        }
    }

    /// 断点续播：优先按照片 id 定位，找不到则退回序号
    private func restoreLastPosition() {
        var index = 0

        if let lastId = PlaybackStore.lastPhotoId,
           let found = currentOrder.firstIndex(where: { $0.id == lastId }) {
            index = found
        } else {
            let saved = PlaybackStore.lastIndex
            if saved > 0 && saved < currentOrder.count {
                index = saved
            }
        }

        showPhoto(at: index)
    }

    // MARK: - 播放控制

    func play() {
        isPlaying = true
        PlaybackStore.wasPlaying = true
        applyScreenAwake()
        scheduleNext()
    }

    /// 内部暂停（结束时、定时到点），不改写 wasPlaying，以便下次自动恢复
    func pause() {
        isPlaying = false
        cancelTimer()
        cancelLoadTimeout()
        applyScreenAwake()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
            PlaybackStore.wasPlaying = false   // 用户主动暂停才记录
        } else {
            play()
        }
    }

    func next() {
        advance(direction: 1)
    }

    func previous() {
        advance(direction: -1)
    }

    func toggleShuffle() {
        isShuffle.toggle()

        // 记住当前这张，洗牌后仍从它开始
        let currentId = currentPhoto?.id
        rebuildOrder()

        if let id = currentId,
           let idx = currentOrder.firstIndex(where: { $0.id == id }) {
            showPhoto(at: idx)
        } else {
            showPhoto(at: 0)
        }

        if isPlaying { scheduleNext() }
    }

    func cycleRepeatMode() {
        let all = RepeatMode.allCases
        let currentIdx = all.firstIndex(of: repeatMode) ?? 0
        repeatMode = all[(currentIdx + 1) % all.count]
    }

    /// 重新开始播放
    func restart() {
        rebuildOrder()
        showPhoto(at: 0)
        if isPlaying { scheduleNext() }
    }

    /// 外部设置播放列表（供 PhotoGridView 调用）—— 严格按给定顺序，不洗牌
    ///
    /// 注意：只改**播放队列**，不动 library.photos —— 那个是选图网格
    /// 用的全量目录。之前在这里覆盖了 library.photos，选过的再开网格
    /// 就没选的照片全「消失」了，不符合直觉。
    func loadSelected(_ photos: [SlidePhoto]) {
        selectedSubset = photos
        lastSelectedIds = Set(photos.map { $0.id })
        currentOrder = photos
        shuffledOrder = []
        showPhoto(at: 0)
        if isPlaying { scheduleNext() }
    }

    /// 用户选过的播放子集。空 = 播全部。
    /// 洗牌 / 从头播放都跟着这个范围走；
    /// 「刷新相册」会清掉它（回到全量库）。
    private(set) var selectedSubset: [SlidePhoto] = []

    /// 上次选照片时勾了的 id。重新打开网格时用来预勾上，
    /// 免得每次都要重新点一遍。
    var lastSelectedIds: Set<String> = []

    /// 重建队列用的基础列表：选过子集就用子集，否则全量
    private func playbackBase() -> [SlidePhoto] {
        selectedSubset.isEmpty ? library.photos : selectedSubset
    }

    /// 按当前是否随机重建播放队列。
    /// 随机模式下每次重建都是一次新的洗牌 —— 相框重启即换一批。
    private func rebuildOrder() {
        let base = playbackBase()
        if isShuffle {
            currentOrder = base.shuffled()
            shuffledOrder = currentOrder
        } else {
            currentOrder = base
            shuffledOrder = []
        }
    }

    // MARK: - 息屏控制

    func toggleScreenAwake() {
        keepsScreenOn.toggle()
        applyScreenAwake()
    }

    /// 只有在「用户允许常亮 + 正在播放 + 处于定时时段内」时才阻止息屏。
    /// 其余情况释放 idle timer，让系统按设置自动锁屏省电。
    private func applyScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = keepsScreenOn && isPlaying && scheduleActive
    }

    // MARK: - 上传的照片入库

    /// 别的设备传完照片，相框应该自己就放上了，不用手动刷新。
    ///
    /// 一次传 20 张会触发 20 次目录变化通知，所以做 1.5 秒防抖，
    /// 等传完了再重载一次。
    private func observeUploads() {
        NotificationCenter.default.addObserver(
            forName: .photoStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleUploadRefresh()
        }
    }

    private func scheduleUploadRefresh() {
        // 只播系统相册的话，上传的照片跟播放列表无关
        guard photoSourceMode != .systemAlbum else { return }

        uploadRefreshWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.reloadPreservingPosition()
        }
        uploadRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - 定时开关播

    private func observeSchedule() {
        schedule.$isActive
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                guard let self = self else { return }
                self.scheduleActive = active
                self.handleScheduleChange(active: active)
            }
            .store(in: &cancellables)
    }

    // MARK: - 背景音乐

    /// 把「开关 + 选中的歌」应用到播放器。
    /// 曲库有歌且开关开 → 播放；否则 → 停。
    func applyMusic() {
        guard musicEnabled, !musicSongs.isEmpty else {
            MusicPlayer.shared.stop()
            isMusicPlaying = false
            currentMusicSong = ""
            return
        }

        let urls = MusicStore.shared.songs
        let startIdx = urls.indices
            .compactMap { musicSongs.contains(urls[$0].lastPathComponent) ? $0 : nil }
            .min() ?? 0

        MusicPlayer.shared.playQueue(urls, startAt: startIdx)
        isMusicPlaying = true
        currentMusicSong = urls[startIdx].lastPathComponent
    }

    /// 监听 MusicPlayer 的状态，同步到镜像字段
    private func observeMusic() {
        MusicPlayer.shared.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                self?.isMusicPlaying = playing
            }
            .store(in: &cancellables)
        MusicPlayer.shared.$currentSong
            .receive(on: RunLoop.main)
            .sink { [weak self] song in
                self?.currentMusicSong = song
            }
            .store(in: &cancellables)
    }

    /// 曲库变化（删歌）时：选中的歌被删了就停音乐
    private func observeMusicLibrary() {
        musicLibraryObserver = NotificationCenter.default.addObserver(
            forName: .musicStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.musicEnabled else { return }

            // 还留在曲库里的选中歌
            let library = MusicStore.shared.songs
            let stillValid = self.musicSongs.filter { name in
                library.contains { $0.lastPathComponent == name }
            }

            if stillValid.count != self.musicSongs.count {
                self.musicSongs = stillValid
                applyMusic()
            }
        }
    }

    private func handleScheduleChange(active: Bool) {
        if active {
            // 进入播放时段 → 自动开播
            if !isPlaying && !currentOrder.isEmpty {
                play()
            }
        } else {
            // 离开播放时段 → 暂停，并释放屏幕常亮
            if isPlaying {
                pause()
            }
        }
        applyScreenAwake()
    }

    // MARK: - 前进 / 后退

    private func advance(direction: Int) {
        // 记录方向给切换动画用：下一张往左飞，上一张往右飞
        lastDirection = direction >= 0 ? 1 : -1
        let count = currentOrder.count
        guard count > 0 else { return }

        // 循环当前照片
        if repeatMode == .current {
            rescheduleTimer()
            return
        }

        var newIndex = currentPhotoIndex + direction
        if newIndex >= count {
            switch repeatMode {
            case .all:
                newIndex = 0
            case .none, .current:
                pause()
                return
            }
        } else if newIndex < 0 {
            newIndex = count - 1
        }

        showPhoto(at: newIndex)
        if isPlaying { scheduleNext() }
    }

    // MARK: - 显示当前照片

    private func showPhoto(at index: Int) {
        let count = currentOrder.count
        guard count > 0 else { return }

        let safeIndex = ((index % count) + count) % count
        let photo = currentOrder[safeIndex]

        currentPhoto = photo
        currentPhotoIndex = safeIndex

        // 断点续播：每换一张就记录位置
        PlaybackStore.lastPhotoId = photo.id
        PlaybackStore.lastIndex = safeIndex

        // 缓存命中（上一张就预加载了它）：直接换画面，不转圈
        if let cached = ImageCache.shared.image(for: photo.id) {
            currentImage = cached
            currentImagePhotoID = photo.id
            isCurrentImageLoading = false
            cancelLoadTimeout()
        } else {
            isCurrentImageLoading = true

            // 每次加载用新 token，防止慢回调覆盖新图
            let token = UUID()
            loadToken = token
            cancelLoadTimeout()

            // currentImagePhotoID 先不动 —— 它还指着上一张，
            // 视图用它把旧照片留在屏幕上垫着；加载完成才一起换。
            library.loadImage(for: photo) { [weak self] image in
                guard let self = self, self.loadToken == token else { return }
                self.cancelLoadTimeout()
                if let image = image {
                    ImageCache.shared.store(image, for: photo.id)
                }
                self.currentImage = image
                self.currentImagePhotoID = photo.id
                self.isCurrentImageLoading = false
            }

            // 加载超时保护：iCloud 照片卡住时自动跳到下一张，避免相框定格
            if loadTimeout > 0 {
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self,
                          self.loadToken == token,
                          self.isCurrentImageLoading else { return }

                    self.isCurrentImageLoading = false
                    self.currentImage = nil          // 清掉上一张，避免图文不符
                    self.currentImagePhotoID = nil
                    self.advance(direction: 1)
                }
                loadTimeoutWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + loadTimeout, execute: work)
            }
        }

        // 无论命中与否，都把队列里再下一张提前解好
        preloadNextPhoto()
    }

    // MARK: - 预加载

    /// 提前解码队列里后面几张，放进缓存，切换时不转圈。
    /// 预加载深度 = 0 时完全不预加载。
    private func preloadNextPhoto() {
        let count = currentOrder.count
        guard count > 1, preloadDepth > 0 else { return }

        // 从下一张开始，往后再取 preloadDepth 张
        let targets = (1...preloadDepth).compactMap { offset -> SlidePhoto? in
            let idx = (currentPhotoIndex + offset) % count
            let photo = currentOrder[idx]
            guard ImageCache.shared.image(for: photo.id) == nil else { return nil }
            return photo
        }

        guard !targets.isEmpty else { return }

        // 延迟一点再起，让当前这张先上屏，别抢解码带宽。
        // 多张时一张张隔 0.4 秒排队解，别一次性挤爆解码带宽。
        for (i, photo) in targets.enumerated() {
            let delay = 0.5 + Double(i) * 0.4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self,
                      self.preloadDepth > i else { return }
                // 延迟期间播放位置/队列可能变了，只对「确实还没被显示」的图
                // 做缓存 —— 已经在播/被手动翻到的图会被 showPhoto 另行处理。
                guard ImageCache.shared.image(for: photo.id) == nil,
                      self.currentPhoto?.id != photo.id else { return }
                self.library.loadImage(for: photo) { image in
                    guard let image = image else { return }
                    ImageCache.shared.store(image, for: photo.id)
                }
            }
        }
    }

    private func cancelLoadTimeout() {
        loadTimeoutWorkItem?.cancel()
        loadTimeoutWorkItem = nil
    }

    // MARK: - 定时器

    private func scheduleNext() {
        cancelTimer()

        let count = currentOrder.count
        guard count > 0 else { return }

        if repeatMode == .none && currentPhotoIndex >= count - 1 {
            pause()
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.advance(direction: 1)
        }

        // 加入 common 模式，避免拖拽/滚动时定时器被暂停
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func rescheduleTimer() {
        if isPlaying { scheduleNext() }
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 用户交互

    /// 点击主区域显隐控制条，3 秒后自动隐藏
    ///
    /// 用 DispatchQueue 而非 Task.sleep —— 后者在 iOS 14 上不可用。
    func toggleControls() {
        autoHideWorkItem?.cancel()
        showControls.toggle()

        guard showControls else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.showControls = false
            }
        }
        autoHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }
}
