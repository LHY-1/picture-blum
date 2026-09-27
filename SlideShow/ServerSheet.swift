// ============================================================
// ServerSheet.swift
// 上传服务面板：开关、网址、二维码、收件箱
//
// 兼容：iOS 14.0+
//   - 用 @Binding 传递 isPresented 代替 iOS 15+ 的 @Environment(\.dismiss)
//
// ⚠️⚠️ 这个文件里有一条铁律，破了就会「一点上传服务就闪退」：
//
//       不要在 View 里写 Binding(get:set:)。
//
//   为什么：
//     View.body 是 @MainActor 的，所以写在 body（及其调用的计算属性）
//     里的闭包字面量全都被推断成 @MainActor 闭包。而
//     `Binding.init(get:set:)` 要的是普通（nonisolated）闭包，
//     编译器于是必须插一层「actor 跳转 thunk」来做转换，
//     这层 thunk 会引用两个符号：
//         _$sScM6sharedScMvgZ   Swift.MainActor.shared
//         _$sScMMa              type metadata accessor for Swift.MainActor
//
//     Swift.MainActor 是 iOS 15 才有的。二进制按 iOS 14 编译时这俩
//     是**弱引用**，iOS 14.8.1 的 dyld 把它们解析成 NULL。代码走到
//     桩里的 `br x16`（x16 = 0）就跳到地址 0：
//         EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS at 0x0
//         x16: 0   pc: 0   lr: <bl 之后那条指令>
//     崩溃栈顶是 SwiftUI，往下能看到 ServerSheet.body.getter。
//
//   这里原来给 Toggle 用了 Binding(get:set:) 做开关，就是这个坑。
//   现在改成 Button（点一下开/关）—— Button 的 action 闭包没问题，
//   SettingsSheet / SlideShowPlayerView 里到处都在这么用。
//
//   自查：build_ipa.sh 第 6 步会在打包前自动扫二进制，一旦发现有
//   代码调用 MainActor.shared 就直接构建失败。加新代码后如果构建
//   报这个错，就是又踩了这条线。
// ============================================================

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct ServerSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: SlideShowViewModel

    @ObservedObject private var server = PhotoServer.shared
    @ObservedObject private var store = LocalPhotoStore.shared

    @State private var showQR = false
    @State private var copied = false

    var body: some View {
        NavigationView {
            Form {
                serverSection
                inboxSection
                librarySection
                optionsSection
                helpSection
            }
            .navigationTitle("上传照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { isPresented = false }
                }
            }
        }
        .sheet(isPresented: $showQR) {
            QRSheet(url: addressText, onClose: { showQR = false })
        }
    }

    // MARK: - 派生状态
    //
    // 全部在这里算好，视图里不做 `if let`。

    /// 服务开着且能拿到局域网地址时才有值
    private var liveURL: String? {
        guard server.isRunning else { return nil }
        return NetworkInfo.urlString(port: server.port)
    }

    /// 永远是一个字符串：网址 / 没 Wi-Fi 的说明 / 服务没开
    private var addressText: String {
        if let url = liveURL { return url }
        return server.isRunning ? NetworkInfo.unavailableReason : "服务未开启"
    }

    private var canShowQR: Bool {
        addressText.hasPrefix("http")
    }

    // MARK: - 服务

    private var serverSection: some View {
        Section(header: Text("服务")) {
            // 这里**不能**用 Toggle(isOn: Binding(get:set:))，见文件头的铁律。
            // 用 Button 一样能表达开关状态，而且不会生成 actor thunk。
            Button(action: {
                if server.isRunning { server.stop() } else { server.start() }
            }) {
                HStack {
                    Label("开启上传服务", systemImage: "wifi")
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
                }
            }

            ServerAddressRow(address: addressText,
                             copied: copied,
                             tappable: canShowQR,
                             onTap: copyAddress)

            QRButtonRow(enabled: canShowQR, action: { showQR = true })

            ServerStatRow(title: "本次已收到", value: "\(server.receivedCount) 张")
            ServerStatRow(title: "最近一张", value: server.lastReceivedName ?? "—")
            ServerNoteRow(message: server.errorMessage ?? "服务运行正常，等设备连进来。",
                          isError: server.errorMessage != nil)
        }
    }

    // MARK: - 收件箱

    private var inboxSection: some View {
        Section(header: Text("待导入 · \(store.inbox.count) 张")) {
            ForEach(store.inbox, id: \.self) { url in
                InboxRow(url: url,
                         sizeText: LocalPhotoStore.formatBytes(Self.fileSize(of: url)),
                         onImport: { importOne(url) })
            }

            InboxActionsRow(hasItems: !store.inbox.isEmpty,
                            onImportAll: importAll,
                            onClear: clearInbox)

            Text("上传的照片先落在收件箱，点「导入」进播放列表。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 已入库

    private var librarySection: some View {
        Section(header: Text("已在相框里")) {
            ServerStatRow(title: "照片数", value: "\(store.media.count) 张")
            ServerStatRow(title: "占用空间",
                          value: LocalPhotoStore.formatBytes(store.mediaBytes))

            DangerButtonRow(title: "清空上传的照片",
                            systemImage: "trash",
                            enabled: !store.media.isEmpty,
                            action: clearMedia)
        }
    }

    // MARK: - 选项

    private var optionsSection: some View {
        Section(header: Text("选项")) {
            Toggle("上传后自动导入", isOn: $store.autoImport)

            Text(store.autoImport
                 ? "传完立刻进播放列表，相框自动刷新。"
                 : "先放进「待导入」，在下面确认后再导入。")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("播放哪些照片", selection: $viewModel.photoSourceMode) {
                ForEach(PhotoSourceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
    }

    // MARK: - 说明

    private var helpSection: some View {
        Section(header: Text("怎么用")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. 打开上面的服务，记住那个网址")
                Text("2. 手机 / 电脑连同一个 Wi-Fi，浏览器打开网址")
                Text("3. 选照片上传，iPad 这边自动就播上了")
            }
            .font(.callout)
            .foregroundColor(.secondary)

            Text("第一次开启时，iPad 会弹窗问「是否允许访问本地网络」，要选允许，否则别的设备连不上。")
                .font(.caption)
                .foregroundColor(.orange)

            Text("iPad 息屏或退出 App 后服务会断开，重新打开即可。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 动作

    private func copyAddress() {
        guard canShowQR else { return }
        UIPasteboard.general.string = addressText
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }

    private func importOne(_ url: URL) {
        store.importOne(url)
        viewModel.reloadLibrary()
    }

    private func importAll() {
        store.importAll()
        viewModel.reloadLibrary()
    }

    private func clearInbox() {
        store.delete(store.inbox)
    }

    private func clearMedia() {
        store.deleteAllMedia()
        viewModel.reloadLibrary()
    }

    private static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
}

// ============================================================
// 各个行
//
// 行都做成具名 struct，Form 里的类型就是这些 struct 名，一眼能看懂。
// 注意：它们的 body 里也**不能**用 Binding(get:set:)，同文件头的铁律。
// ============================================================

/// 网址行：点一下复制。服务没开时显示提示语并变灰。
private struct ServerAddressRow: View {
    let address: String
    let copied: Bool
    let tappable: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(address)
                    .font(.system(.title3, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundColor(tappable ? .blue : .secondary)
                Spacer()
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundColor(copied ? .green : .secondary)
            }

            Text(copied
                 ? "已复制，粘到别的设备浏览器里打开"
                 : (tappable ? "点一下复制，在别的设备浏览器里打开"
                             : "开启服务后这里会显示上传网址"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// 二维码按钮。地址拿不到时置灰。
private struct QRButtonRow: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("显示二维码（扫码直接打开）", systemImage: "qrcode")
                .foregroundColor(enabled ? .blue : .secondary)
        }
        .disabled(!enabled)
    }
}

/// 一行「标题 —— 值」
private struct ServerStatRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// 一行小字提示，橙色代表出错了
private struct ServerNoteRow: View {
    let message: String
    let isError: Bool

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundColor(isError ? .orange : .secondary)
    }
}

/// 收件箱里的一张照片
private struct InboxRow: View {
    let url: URL
    let sizeText: String
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: LocalPhotoStore.shared.thumbnailURL(for: url))

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizeText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onImport) {
                Text("导入")
                    .fontWeight(.semibold)
            }
        }
    }
}

/// 收件箱底部的「全部导入 / 清空」两个按钮
private struct InboxActionsRow: View {
    let hasItems: Bool
    let onImportAll: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack {
            Spacer()

            Button(action: onImportAll) {
                Label("全部导入相框", systemImage: "square.and.arrow.down")
                    .foregroundColor(hasItems ? .blue : .secondary)
            }
            .disabled(!hasItems)

            Button(action: onClear) {
                Label("清空收件箱", systemImage: "trash")
                    .foregroundColor(hasItems ? .red : .secondary)
            }
            .disabled(!hasItems)
        }
    }
}

/// 红色危险操作按钮（清空之类）
private struct DangerButtonRow: View {
    let title: String
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundColor(enabled ? .red : .secondary)
        }
        .disabled(!enabled)
    }
}

// MARK: - 缩略图小图
//
// 读不出来就给一张占位图，视图类型只有 Image 一种，不做 if/else 分叉。

private struct ThumbnailView: View {
    let url: URL

    var body: some View {
        Image(uiImage: Self.load(from: url))
            .resizable()
            .scaledToFill()
            .frame(width: 48, height: 48)
            .clipped()
    }

    /// 缩略图很小（400px），同步读只需几毫秒，不值得为它开线程
    private static func load(from url: URL) -> UIImage {
        if let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return image
        }
        return placeholder
    }

    private static let placeholder: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { context in
            UIColor(white: 0.18, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }()
}

// MARK: - 二维码

struct QRSheet: View {
    let url: String
    let onClose: () -> Void

    private var encodable: Bool { url.hasPrefix("http") }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Spacer()

                // 不做 if/else：生成不出来时 qrImage 会给一张空白图，
                // 这样这里永远只有 Image 一种视图类型。
                Image(uiImage: Self.qrImage(from: url, size: 260))
                    .interpolation(.none)      // 二维码不能平滑插值，会糊
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .background(Color.white)
                    .cornerRadius(12)

                VStack(spacing: 6) {
                    Text(encodable ? "用手机相机扫这个码"
                                   : "还没拿到局域网地址，二维码暂时用不了")
                        .font(.headline)
                    Text(url)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("扫码上传")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭", action: onClose)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 生成

    /// 二维码图。地址不像网址、或生成失败时，返回一张空白占位图 ——
    /// 这样调用方永远只有 Image 一种视图类型，不用写 if/else 分叉。
    static func qrImage(from string: String, size: CGFloat) -> UIImage {
        guard string.hasPrefix("http"),
              let qr = makeQRCode(from: string, size: size) else {
            return blankImage(size: size)
        }
        return qr
    }

    /// 生成二维码。
    ///
    /// CIFilter 输出的图四周没有留白，而二维码规范要求至少 4 个模块的
    /// 静默区，否则相机对不上焦。所以手动在白底上画一次并留边。
    static func makeQRCode(from string: String, size: CGFloat) -> UIImage? {
        guard !string.isEmpty else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage,
              output.extent.width > 0, output.extent.height > 0 else { return nil }

        let scale = size / output.extent.width
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale))

        let quietZone = size * 0.1
        let total = size + quietZone * 2

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: total, height: total))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: total, height: total))

            let ciContext = CIContext()
            if let cg = ciContext.createCGImage(scaled, from: scaled.extent) {
                UIImage(cgImage: cg).draw(
                    in: CGRect(x: quietZone, y: quietZone,
                               width: size, height: size))
            }
        }
    }

    private static func blankImage(size: CGFloat) -> UIImage {
        let total = size * 1.2
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: total, height: total))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: total, height: total))
        }
    }
}
