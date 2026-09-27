// ============================================================
// SlideShowPlayerView.swift
// 幻灯片全屏播放视图
//
// 兼容：iOS 14.0+
// ============================================================

import SwiftUI

struct SlideShowPlayerView: View {
    @EnvironmentObject var viewModel: SlideShowViewModel

    /// iPad 上尺寸类是 regular，据此放大控件。
    /// 用 size class 而不是 UIScreen.bounds —— 旋转时能自动更新。
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// 控件缩放系数
    private var s: CGFloat { hSizeClass == .regular ? 1.4 : 1.0 }

    @State private var swipeOffset: CGFloat = 0

    @ObservedObject private var server = PhotoServer.shared

    var body: some View {
        ZStack {
            // 背景
            Color.black.ignoresSafeArea()

            // 当前照片（带切换动画）
            currentPhotoView

            // 加载指示器
            if viewModel.isCurrentImageLoading {
                ProgressView()
                    .scaleEffect(2)
                    // .tint() 是 iOS 15+，用 progressViewStyle 代替
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }

            // 控制条与提示：必须用撑满高度的 VStack 定位。
            // 直接把 topBar / bottomBar 放进 ZStack 是不行的 —— ZStack 默认
            // 把子视图垂直居中，底栏会跑到屏幕正中挡住画面。
            overlayBars
        }
        // 点击主区域切换控制条显示
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) {
                viewModel.toggleControls()
            }
        }
        // 左右滑动切图
        .gesture(swipeGesture)
        .animation(.easeInOut, value: viewModel.showControls)
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsSheet(
                isPresented: $viewModel.showSettings,
                viewModel: viewModel,
                schedule: viewModel.schedule
            )
        }
        // 用 fullScreenCover 而非 sheet —— iPad 上 sheet 会变成 540pt 宽的
        // 浮动表单，网格挤成一团；全屏呈现才有足够空间选照片
        .fullScreenCover(isPresented: $viewModel.showPhotoPicker) {
            PhotoGridView(
                isPresented: $viewModel.showPhotoPicker,
                viewModel: viewModel
            )
        }
        .onChange(of: viewModel.interval) { _ in
            // 更改间隔时立即重新计时
            if viewModel.isPlaying { viewModel.play() }
        }
    }

    // MARK: - 控制条布局

    /// 撑满屏幕的 VStack，把顶栏推上去、底栏压下去
    private var overlayBars: some View {
        VStack(spacing: 0) {
            if viewModel.showControls {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer(minLength: 0)

            // 定时暂停提示（仅在定时生效且已暂停时显示）
            if viewModel.schedule.isEnabled && !viewModel.scheduleActive {
                schedulePausedBadge
            }

            if viewModel.showControls {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 当前照片（切换动画）

    /// 一张照片一个图层。切换瞬间新旧两层同时在场：
    /// 旧图层原地演退场，新图层演入场，互不干扰。
    ///
    /// 关键点：每层存自己那份图的引用（image），而不是都指 currentImage ——
    /// 否则新图一到手，旧图层也会跟着变成新图，溶解/缩放就看不出来了。
    private struct PhotoLayer: Identifiable {
        let id: String
        let image: UIImage
    }

    private var transitionLayers: [PhotoLayer] {
        var layers: [PhotoLayer] = []

        let newID = viewModel.currentPhoto?.id ?? ""
        let imageOwnerID = viewModel.currentImagePhotoID

        // 旧图层：正在加载、且当前画面还属于上一张、选了非「无动画」。
        // 这时 currentImage 就是旧图，存进图层，它退场时就一直显示旧图。
        if viewModel.isCurrentImageLoading,
           viewModel.transitionStyle != .none,
           let oldID = imageOwnerID,
           oldID != newID,
           let oldImage = viewModel.currentImage {
            layers.append(PhotoLayer(id: oldID, image: oldImage))
        }

        // 新图层：画面已经属于当前照片
        if imageOwnerID == newID, !newID.isEmpty,
           let newImage = viewModel.currentImage {
            layers.append(PhotoLayer(id: newID, image: newImage))
        }

        return layers
    }

    @ViewBuilder
    private var currentPhotoView: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                ForEach(transitionLayers) { layer in
                    let isFront = layer.id == transitionLayers.last?.id

                    photoLayer(layer, isFront: isFront, size: size)
                        .offset(x: isFront ? swipeOffset : 0)
                        .transition(
                            viewModel.transitionStyle.layerTransition(
                                direction: viewModel.lastDirection))
                }

                // 什么都没加载出来时铺黑底
                if transitionLayers.isEmpty {
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: size.width, height: size.height)
                }
            }
            // 「无动画」时 animation 为 nil → 图层直接换，不演
            .animation(viewModel.transitionStyle.animation,
                       value: transitionLayers.map { $0.id })
            .animation(.interactiveSpring(), value: swipeOffset)
        }
        // 照片铺满整屏，包括 home 指示条区域
        .ignoresSafeArea()
    }

    /// 一个图层：用自己存下的图。
    /// 旧图层定格旧图演退场；新图层用新图演入场。
    private func photoLayer(_ layer: PhotoLayer,
                            isFront: Bool,
                            size: CGSize) -> some View {
        ZStack {
            // 模糊背景：照片横竖比例和屏幕不一致时，
            // 四周的留白不再是死黑，而是这张照片的高斯模糊版。
            // scaleEffect 放大 1.15 倍 —— 模糊会把黑色边缘渗进来，
            // 先放大再 clipped 切回，屏幕上全是模糊画面。
            Image(uiImage: layer.image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .scaleEffect(1.15)
                .blur(radius: 30)
                .clipped()
                .opacity(0.7)

            // 原图
            Image(uiImage: layer.image)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - 顶部控制栏

    private var topBar: some View {
        HStack {
            // 照片选择入口
            Button(action: { viewModel.showPhotoPicker = true }) {
                Image(systemName: "square.grid.3x3")
                    .foregroundColor(.white)
                    .font(.system(size: 22 * s))
                    .padding(8)
            }

            // 序号指示器
            if !viewModel.currentOrder.isEmpty {
                Text("\(viewModel.currentPhotoIndex + 1) / \(viewModel.currentOrder.count)")
                    .foregroundColor(.white)
                    .font(.system(size: 17 * s, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(4)
            }

            Spacer()

            // 上传服务开着的时候给个提示 —— 一眼能看出相框正在收照片
            if server.isRunning {
                Image(systemName: "wifi")
                    .foregroundColor(.green)
                    .font(.system(size: 16 * s))
                    .padding(8)
            }

            // 息屏开关
            Button(action: { viewModel.toggleScreenAwake() }) {
                Image(systemName: viewModel.keepsScreenOn
                      ? "moon.fill"
                      : "moon")
                    .foregroundColor(viewModel.keepsScreenOn ? .yellow : .white.opacity(0.6))
                    .font(.system(size: 22 * s))
                    .padding(8)
            }

            // 设置
            Button(action: { viewModel.showSettings = true }) {
                Image(systemName: "gearshape")
                    .foregroundColor(.white)
                    .font(.system(size: 22 * s))
                    .padding(8)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.6), .clear]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    // MARK: - 底部控制栏

    private var bottomBar: some View {
        VStack(spacing: 12) {
            // 进度条
            progressBar

            // 控制按钮
            HStack {
                // 循环模式
                Button(action: { viewModel.cycleRepeatMode() }) {
                    Image(systemName: repeatModeIcon)
                        .foregroundColor(.white)
                        .font(.system(size: 20 * s))
                        .padding(12)
                }
                .frame(width: 60 * s, height: 60 * s)

                Spacer()

                // 上一张
                Button(action: { viewModel.previous() }) {
                    Image(systemName: "backward.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 28 * s))
                        .padding(12)
                }
                .frame(width: 70 * s, height: 70 * s)

                // 播放 / 暂停
                Button(action: { viewModel.togglePlayPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 44 * s))
                        .padding(12)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .frame(width: 80 * s, height: 80 * s)

                // 下一张
                Button(action: { viewModel.next() }) {
                    Image(systemName: "forward.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 28 * s))
                        .padding(12)
                }
                .frame(width: 70 * s, height: 70 * s)

                Spacer()

                // 随机模式
                Button(action: { viewModel.toggleShuffle() }) {
                    Image(systemName: "shuffle")
                        .foregroundColor(viewModel.isShuffle ? .blue : .white.opacity(0.7))
                        .font(.system(size: 20 * s))
                        .padding(12)
                }
                .frame(width: 60 * s, height: 60 * s)
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [.clear, Color.black.opacity(0.6)]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - 进度条

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                Rectangle()
                    .fill(Color.white)
                    .frame(width: geo.size.width * progressWidth)
            }
        }
        .frame(height: 4)       // GeometryReader 会贪婪占满，必须钉死高度
        .cornerRadius(2)
    }

    private var progressWidth: CGFloat {
        guard !viewModel.currentOrder.isEmpty else { return 0 }
        return CGFloat(viewModel.currentPhotoIndex + 1) /
               CGFloat(viewModel.currentOrder.count)
    }

    private var repeatModeIcon: String {
        switch viewModel.repeatMode {
        case .none:    return "repeat"
        case .current: return "repeat.1"
        case .all:     return "repeat.2"
        }
    }

    // MARK: - 定时暂停提示
    //
    // 位置由外层 overlayBars 的 VStack 决定，这里不再自带 Spacer。

    private var schedulePausedBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.zzz.fill")
            Text("定时暂停中 · \(viewModel.schedule.startTimeString) 恢复")
        }
        .font(.caption)
        .foregroundColor(.white.opacity(0.75))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .padding(.bottom, 12)
        .allowsHitTesting(false)   // 不挡手势
    }

    // MARK: - 手势

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                swipeOffset = value.translation.width
            }
            .onEnded { value in
                let threshold: CGFloat = 80
                withAnimation(.spring()) {
                    if value.translation.width < -threshold {
                        viewModel.next()
                    } else if value.translation.width > threshold {
                        viewModel.previous()
                    }
                    swipeOffset = 0
                }
            }
    }
}

// MARK: - Preview

struct SlideShowPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        SlideShowPlayerView()
            .environmentObject(SlideShowViewModel())
    }
}
