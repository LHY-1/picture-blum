// ============================================================
// SettingsSheet.swift
// 设置面板：速度 / 循环 / 定时开关播 / 息屏 / 容错
//
// 兼容：iOS 14.0+
//   - 用 @Binding 传递 isPresented 代替 iOS 15+ 的 @Environment(\.dismiss)
// ============================================================

import SwiftUI

struct SettingsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: SlideShowViewModel
    @ObservedObject var schedule: FrameSchedule

    @ObservedObject private var server = PhotoServer.shared
    @ObservedObject private var store = LocalPhotoStore.shared
    @State private var showServer = false

    var body: some View {
        NavigationView {
            Form {
                playbackSection
                repeatSection
                orderSection
                preloadSection
                musicSection
                sourceSection
                scheduleSection
                screenSection
                toleranceSection
                themeSection
                serverSection
                otherSection
                infoSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { isPresented = false }
                }
            }
        }
        .sheet(isPresented: $showServer) {
            ServerSheet(isPresented: $showServer, viewModel: viewModel)
        }
    }

    // MARK: - 照片来源

    private var sourceSection: some View {
        Section(header: Text("照片来源")) {
            Picker("播放哪些照片", selection: $viewModel.photoSourceMode) {
                ForEach(PhotoSourceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("上传的照片")
                Spacer()
                Text("\(store.media.count) 张")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 上传服务

    private var serverSection: some View {
        Section(header: Text("上传照片")) {
            Button(action: { showServer = true }) {
                HStack {
                    Label("上传服务", systemImage: "wifi")
                        .foregroundColor(.primary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(server.isRunning ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(server.isRunning ? "已开启" : "未开启")
                            .font(.caption)
                            .foregroundColor(server.isRunning ? .green : .secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if store.inbox.count > 0 {
                HStack {
                    Label("待导入", systemImage: "tray.and.arrow.down")
                    Spacer()
                    Text("\(store.inbox.count) 张")
                        .foregroundColor(.orange)
                }
            }

            Text("开启后别的设备连同一个 Wi-Fi，用浏览器把照片传进相框。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 播放

    private var playbackSection: some View {
        Section(header: Text("播放")) {
            VStack(alignment: .leading) {
                HStack {
                    Text("每张停留")
                    Spacer()
                    Text(String(format: "%.0f 秒", viewModel.interval))
                        .foregroundColor(.secondary)
                        .font(.headline)
                }
                IntervalSlider(value: $viewModel.interval,
                               range: 1.0...60.0,
                               step: 1.0)
            }

            HStack(spacing: 8) {
                quickSpeedButton(seconds: 2,  label: "2 秒")
                quickSpeedButton(seconds: 5,  label: "5 秒")
                quickSpeedButton(seconds: 10, label: "10 秒")
                quickSpeedButton(seconds: 30, label: "30 秒")
                quickSpeedButton(seconds: 60, label: "1 分")
            }

            Picker("切换动画", selection: $viewModel.transitionStyle) {
                ForEach(TransitionStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Text("滑动模式下，下一张从右边进来、上一张从右边出去，方向跟着你切图的方向走。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 预加载

    private var preloadSection: some View {
        Section(header: Text("预加载")) {
            Stepper(value: $viewModel.preloadDepth, in: 0...3) {
                HStack {
                    Text("预加载")
                    Spacer()
                    Text(viewModel.preloadDepth == 0 ? "关" : "\(viewModel.preloadDepth) 张")
                        .foregroundColor(.secondary)
                }
            }

            Stepper(value: $viewModel.cacheLimit, in: 1...10) {
                HStack {
                    Text("内存缓存")
                    Spacer()
                    Text("\(viewModel.cacheLimit) 张")
                        .foregroundColor(.secondary)
                }
            }

            Text("预加载会把后面几张提前解码，切换时不用等转圈。缓存调大，来回翻几张都不会转圈；上限 10 张（低内存的老设备只有 2G，再大就挤兑了）。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 音乐

    @ObservedObject private var musicStore = MusicStore.shared

    private var musicSection: some View {
        Section(header: Text("音乐")) {
            Toggle("背景音乐", isOn: $viewModel.musicEnabled)

            // 当前在播的歌（切歌时实时更新）
            if viewModel.isMusicPlaying {
                HStack {
                    Image(systemName: "waveform")
                        .foregroundColor(.blue)
                    Text(viewModel.currentMusicSong)
                        .lineLimit(1)
                    Spacer()
                }
            }

            // 音量
            Stepper(value: $viewModel.musicVolume, in: 0...1, step: 0.1) {
                HStack {
                    Text("音量")
                    Spacer()
                    Text("\(Int(viewModel.musicVolume * 100))%")
                        .foregroundColor(.secondary)
                }
            }

            // 选曲：整队循环播放
            ForEach(musicStore.songs, id: \.self) { url in
                musicSongRow(name: url.lastPathComponent,
                             isSelected: viewModel.musicSongs.contains(url.lastPathComponent))
            }

            if musicStore.songs.isEmpty {
                Text("还没有音乐。把歌曲传到「上传服务」里，这里就能选了（mp3 / m4a / aac / wav）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func musicSongRow(name: String, isSelected: Bool) -> some View {
        Button(action: {
            viewModel.musicSongs = isSelected
                ? viewModel.musicSongs.filter { $0 != name }
                : viewModel.musicSongs + [name]
        }) {
            HStack {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
        }
    }

    // MARK: - 循环

    private var repeatSection: some View {
        Section(header: Text("循环")) {
            Picker("循环模式", selection: $viewModel.repeatMode) {
                ForEach(RepeatMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 顺序

    private var orderSection: some View {
        Section(header: Text("顺序")) {
            Toggle("随机播放", isOn: $viewModel.isShuffle)

            if viewModel.isShuffle {
                Button(action: { viewModel.toggleShuffle() }) {
                    Label("重新洗牌", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundColor(.blue)
                }
            }
        }
    }

    // MARK: - 定时开关播

    private var scheduleSection: some View {
        Section(header: Text("定时开关播")) {
            Toggle("启用定时", isOn: $schedule.isEnabled)

            if schedule.isEnabled {
                scheduleEditor
            }
        }
    }

    private var scheduleEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker(
                "开始播放",
                selection: $schedule.startTime,
                displayedComponents: .hourAndMinute
            )

            DatePicker(
                "停止播放",
                selection: $schedule.endTime,
                displayedComponents: .hourAndMinute
            )

            HStack {
                Text("当前状态")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(schedule.isActive ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(schedule.isActive ? "播放时段内" : "已暂停")
                        .foregroundColor(.secondary)
                }
            }

            Text(schedule.summary)
                .font(.caption)
                .foregroundColor(.secondary)

            Text("到点自动暂停并释放屏幕常亮，设备按系统设置自动锁屏省电。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 屏幕

    private var screenSection: some View {
        Section(header: Text("屏幕")) {
            Toggle("播放时防止自动息屏", isOn: $viewModel.keepsScreenOn)
            Text("仅在播放中且处于定时时段内生效；暂停后自动恢复系统锁屏。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 容错

    private var toleranceSection: some View {
        Section(header: Text("容错")) {
            Picker("图片加载超时", selection: $viewModel.loadTimeout) {
                Text("5 秒").tag(TimeInterval(5))
                Text("10 秒").tag(TimeInterval(10))
                Text("30 秒").tag(TimeInterval(30))
                Text("关闭").tag(TimeInterval(0))
            }
            Text("超时后自动跳到下一张，避免 iCloud 照片下载卡住导致相框定格。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 主题

    private var themeSection: some View {
        Section(header: Text("主题")) {
            Picker("外观", selection: $viewModel.theme) {
                Text("深色").tag(0)
                Text("浅色").tag(1)
                Text("跟随系统").tag(2)
            }
            .pickerStyle(.segmented)

            Text("深色适合夜里挂着当相框，浅色适合白天，跟随系统则跟着 iPad 设置变。播放画面两边都一样，只影响界面颜色。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 其他

    private var otherSection: some View {
        Section(header: Text("其他")) {
            Button(action: { viewModel.restart() }) {
                Label("从头播放", systemImage: "arrow.left")
                    .foregroundColor(.primary)
            }

            Button(action: { viewModel.reloadLibrary() }) {
                Label("刷新相册", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundColor(.primary)
            }

            Button(action: { PlaybackStore.clear() }) {
                Label("清除播放进度", systemImage: "trash")
                    .foregroundColor(.primary)
            }
        }
    }

    // MARK: - 信息

    private var infoSection: some View {
        Section(header: Text("信息")) {
            HStack {
                Text("照片总数")
                Spacer()
                Text("\(viewModel.library.photos.count)")
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("去重诊断")
                Spacer()
                // 上次加载时去掉了几张重复；点一下复制清单，
                // 把指纹发回来，能对上还有哪几张没去干净
                Text(viewModel.library.removedDuplicates.isEmpty
                     ? "无" : "\(viewModel.library.removedDuplicates.count)")
                    .foregroundColor(.secondary)
            }
            if !viewModel.library.removedDuplicates.isEmpty {
                Button(action: {
                    UIPasteboard.general.string =
                        viewModel.library.removedDuplicates.joined(separator: "\n")
                }) {
                    Label("复制去重清单", systemImage: "doc.on.doc")
                }
            }
            HStack {
                Text("当前进度")
                Spacer()
                Text("\(viewModel.currentPhotoIndex + 1) / \(max(viewModel.currentOrder.count, 1))")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("上传服务")
                Spacer()
                Text(server.isRunning ? "端口 \(server.port)" : "未开启")
                    .foregroundColor(server.isRunning ? .green : .secondary)
            }

            HStack {
                Text("相册权限")
                Spacer()
                Text(viewModel.library.permissionDescription)
                    .foregroundColor(viewModel.library.hasPermissionPublic ? .secondary : .red)
                // 权限被拒时点一下重新去申请
                Button(action: {
                    viewModel.library.requestAuthorization { }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.blue)
                }
                .opacity(viewModel.library.hasPermissionPublic ? 0.3 : 1)
            }

            HStack {
                Text("版本")
                Spacer()
                Text(AppInfo.display)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 快速速度按钮
    //
    // 直接赋值，不包 withAnimation —— 在 iOS 14 的 Form 里
    // withAnimation + 改 @Published 会把这次触摸重新派发，
    // 整排按钮无论点哪颗都跳到最后一颗（「1 分」）。

    private func quickSpeedButton(seconds: Double, label: String) -> some View {
        let selected = viewModel.interval == seconds
        return Button(action: {
            viewModel.interval = seconds
        }) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.blue : Color.primary.opacity(0.12))
                .foregroundColor(selected ? .white : .primary)
                .cornerRadius(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 停留时长滑块
//
// SwiftUI 的 Slider 在 iOS 14 老设备的横屏 + Form 场景下，
// 每次触碰滑块都会跳到 100%（最右端）—— 系统 Slider 的 known issue。
// 换成 UIKit 的 UISlider 包一层：行为跟 iPhone 上一致，按哪算哪。
struct IntervalSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)
        slider.addTarget(context.coordinator,
                        action: #selector(Coordinator.valueChanged(_:)),
                        for: .valueChanged)
        return slider
    }

    func updateUIView(_ uiView: UISlider, context: Context) {
        if uiView.value != Float(value) {
            uiView.value = Float(value)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: IntervalSlider

        init(_ parent: IntervalSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ slider: UISlider) {
            // UISlider 连续拖动时 value 是平滑的，按步长取整
            let raw = Double(slider.value)
            let stepped = (raw / parent.step).rounded() * parent.step
            parent.value = min(max(stepped, parent.range.lowerBound),
                               parent.range.upperBound)
        }
    }
}

// MARK: - Preview

struct SettingsSheet_Previews: PreviewProvider {
    static var previews: some View {
        SettingsSheet(
            isPresented: .constant(true),
            viewModel: SlideShowViewModel(),
            schedule: FrameSchedule()
        )
    }
}
