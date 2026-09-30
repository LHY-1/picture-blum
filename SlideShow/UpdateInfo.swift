// ============================================================
// UpdateInfo.swift
// 热更新：App 自己拉 manifest → 下载 → SHA256 校验 → TSServer 安装 → 重启
//
// 原理：
//   App 由 TrollStore 分发，进程带着 TrollStore 的安装权限，
//   可以直接调 TrollStore 的系统级安装服务（TSServer XPC，
//   命令行工具 tsu 用的就是它）。装完杀掉自己，新包起来后
//   自动回到播放画面 —— 相框场景下全程无人值守。
//
// 流程（App 起来自动跑，也可在设置页手动查/装）：
//   检查（6h 节流）→ 有新版才下载 → sha256 校验 → TSServer XPC
//   安装 → exit(0) → 快捷指令自动化（充电器连接时打开 App）
//   把新版本顶起来。任一环节失败自动退回「文件 App 手动装」
//   （包此时已在本地，用户点一次 TrollStore 就装上了），
//   下次 App 起来还会再试一遍 —— 自愈。
//
// 安全：IPA 是代码，安装前必须 sha256 校验；发布端走 GitHub HTTPS。
//
// 兜底说明：TSServer 不是公开 API，服务名 / payload 字段可能随
//   TrollStore 版本变化。连接建立或安装回复没等到时自动退回
//   手动模式；真对不上了只需要改 attemptInstall() 一个函数。
//
// 兼容：iOS 14.0+（无 async/await；CryptoKit SHA256；
//       UpdateChecker 是单例，不在 View body 里构造，
//       避开 iOS 14 MainActor thunk 那条线）
// ============================================================

import Foundation
import CryptoKit
import SwiftUI
import UIKit

struct UpdateInfo {

    /// GitHub Releases 固定入口。latest 指针由 GitHub 维护，
    /// 发布端（publish.sh）只管发新版，这里不用改。
    static let manifestURL =
        "https://github.com/LHY-1/picture-blum/releases/latest/download/manifest.json"

    struct Manifest: Decodable {
        let version: String
        let build: Int
        let sha256: String
        let url: String
        let min_ios: String
    }

    static let currentBuild =
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0

    /// 拉 manifest。callback 在主线程，error 为 nil 时表示没有更新。
    static func check(forLatest: @escaping (Manifest?, Error?) -> Void) {
        URLSession.shared.dataTask(with: URL(string: manifestURL)!) { data, _, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil else {
                    forLatest(nil, error ?? URLError(.badServerResponse))
                    return
                }
                guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                    forLatest(nil, URLError(.cannotDecodeContentData))
                    return
                }
                forLatest(manifest.build > currentBuild ? manifest : nil, nil)
            }
        }.resume()
    }
}

// MARK: - 检查 / 下载 / 安装

/// 单例，App 启动和自动更新都走它。
/// 构造走 static let（惰性、主线程安全），不在任何 View body 里构造。
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()
    private init() {
        autoUpdate = UserDefaults.standard.object(forKey: Keys.auto) as? Bool ?? true
    }

    enum Keys {
        static let auto = "com.yuan.slideshow.autoUpdate"
        static let lastCheck = "com.yuan.slideshow.lastCheckAt"
        static let downloadedIPA = "com.yuan.slideshow.downloadedIPA"
        /// 装完新包、即将退出时置位；新进程起来清掉（= 重启完成）
        static let pendingRestart = "com.yuan.slideshow.pendingRestart"
    }

    /// 自动更新开关（设置页的 Toggle 绑它）
    @Published var autoUpdate: Bool {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: Keys.auto) }
    }

    @Published private(set) var manifest: UpdateInfo.Manifest?
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    /// 已下载到本地、装过或待装的包路径
    @Published private(set) var downloadedIPA: URL?
    /// TSServer 安装请求是否已发出（成功即退出，界面来不及再变）
    @Published private(set) var isInstalling = false
    @Published private(set) var checkError: String?

    /// 自动更新的节流：6 小时内不重复拉
    private static let checkThrottle: TimeInterval = 6 * 3600

    // MARK: App 生命周期钩子

    /// 每次 App 起来都调：清掉上次的重启标记，跑一次自动更新流水线。
    func onAppLaunch() {
        UserDefaults.standard.removeObject(forKey: Keys.pendingRestart)
        autoUpdateIfDue()
    }

    /// 有新版就一路走完：检查 → 下载 → 校验 → 安装 → 重启
    func autoUpdateIfDue() {
        let last = UserDefaults.standard.double(forKey: Keys.lastCheck)
        guard autoUpdate, Date().timeIntervalSince1970 - last >= Self.checkThrottle else { return }
        check { [weak self] newManifest, _ in
            guard let self = self, let m = newManifest else { return }
            self.pipeline(m)
        }
    }
    func check() {
        check { _, _ in }
    }

    /// 检查有没有新版（结果走闭包，自动更新流水线和 App 用它）。
    func check(forLatest: @escaping (UpdateInfo.Manifest?, Error?) -> Void) {
        guard !isChecking else { forLatest(nil, nil); return }
        isChecking = true
        checkError = nil
        manifest = nil
        UpdateInfo.check { [weak self] newManifest, error in
            guard let self = self else { forLatest(nil, error); return }
            self.isChecking = false
            if let m = newManifest {
                self.manifest = m
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastCheck)
                forLatest(m, nil)
            } else {
                if let e = error {
                    self.checkError = "检查更新失败：\(e.localizedDescription)"
                }
                forLatest(newManifest, error)
            }
        }
    }

    /// 下载 + 校验 + 安装的完整流水线（手动和自动共用）
    func pipeline(_ manifest: UpdateInfo.Manifest) {
        guard !isDownloading else { return }
        isDownloading = true
        checkError = nil
        self.manifest = manifest

        let destDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Update", isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("SlideShow-\(manifest.version).ipa")

        var request = URLRequest(url: URL(string: manifest.url)!)
        request.timeoutInterval = 120
        URLSession.shared.downloadTask(with: request) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isDownloading = false
                guard let tempURL = tempURL, error == nil else {
                    self.checkError = "下载失败：\((error as NSError?)?.localizedDescription ?? "网络错误")"
                    return
                }
                do {
                    try FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                } catch {
                    self.checkError = "保存失败：\(error.localizedDescription)"
                    return
                }
                self.downloadedIPA = dest
                UserDefaults.standard.set(dest.absoluteString, forKey: Keys.downloadedIPA)

                // 校验不过不装，退回手动兜底
                guard Self.verify(dest, expectedSHA256: manifest.sha256) else {
                    self.checkError = "校验失败：SHA256 不匹配，请检查发布端或网络，已退回手动安装。"
                    return
                }
                self.attemptInstall(dest)
            }
        }.resume()
    }

    /// 重新装一次已下载的包（TSServer 没接上时的手动重试入口）
    func retryInstall() {
        guard let ipa = downloadedIPA else { return }
        checkError = nil
        attemptInstall(ipa)
    }

    /// 打开「文件」App 手动装（最后的兜底）
    func openFilesApp() {
        URL(string: "file://com.apple.files.app")
            .map { UIApplication.shared.open($0, options: [:], completionHandler: nil) }
    }

    // MARK: 安装（XPC）

    /// 新 SDK 没有 XPC 模块（符号还在 /usr/lib/libXPC.dylib 里，
    /// 只是没给 Swift 头声明），用 dlsym 取运行时函数地址。

    @_silgen_name("dlopen")
    private func dlopen(_ filename: UnsafePointer<CChar>?, _ flags: Int32) -> OpaquePointer?

    @_silgen_name("dlsym")
    private func dlsym(_ handle: OpaquePointer?, _ symbol: UnsafePointer<CChar>) -> OpaquePointer?

    /// void (XPCConnectionDelegateRef delegate, XPCConnectionEvent event, void *arg)
    /// 连接事件是位掩码，4 = invalidated
    private typealias XPCDelegateCFunc = @convention(c)
        (OpaquePointer?, UInt32, OpaquePointer?) -> Void
    private typealias XPCConnCreateCFunc =
        (OpaquePointer?, UnsafePointer<CChar>, Int32, XPCDelegateCFunc?, UnsafeMutableRawPointer?) -> OpaquePointer?
    private typealias XPCConnInterfaceCFunc =
        (OpaquePointer?, OpaquePointer?) -> Void
    private typealias XPCConnResumeCFunc = (OpaquePointer?) -> Void
    private typealias XPCConnEncodeDictCFunc =
        (OpaquePointer?, CFDictionary, CFArray) -> Void
    private typealias XPCConnCancelCFunc = (OpaquePointer?) -> Void
    /// C 里返回 bool（CBool），Swift 桥成 Bool
    private typealias XPCConnIsValidCFunc = (OpaquePointer?) -> Bool

    /// 全局 delegate（C 回调不捕获上下文，闭包不行）
    private let xpcInvalidatedDelegate: XPCDelegateCFunc = { _, event, _ in
        event == 4   // XPC_CONNECTION_EVENT_INVALIDATED
    }

    /// 取 libXPC.dylib 里的符号；缺就返回 nil，整个安装退回手动模式
    private func xpcSymbol(_ name: String) -> OpaquePointer? {
        guard let handle = dlopen("/usr/lib/libXPC.dylib", 2) else { return nil }  // RTLD_NOW
        return dlsym(handle, name)
    }

    /// 调 TrollStore 的系统级安装服务（TSServer XPC）。
    ///
    /// 服务名按社区 tsu 工具用的 `com.trollstore.inject`；payload 按
    /// tsu 的惯例发 {ipa: 路径, url: file URL}。TSServer 不是公开 API，
    /// 字段可能对不上 —— 连接建不起来 / 安装被拒绝时返回 false，
    /// 调用方退回「文件 App 手动装」。真对不上了只需改这一个函数。
    private func attemptInstall(_ ipa: URL) -> Bool {
        guard
            let s = xpcSymbol("XPCConnectionCreate"),
            let si = xpcSymbol("XPCConnectionInterface"),
            let sr = xpcSymbol("XPCConnectionResume"),
            let se = xpcSymbol("XPCConnectionEncodeDictionaryObject"),
            let sc = xpcSymbol("XPCConnectionCancel") else {
            checkError = "系统没暴露 XPC 安装接口，请手动安装（下方按钮）。"
            return false
        }
        // dlsym 给的是地址，位宽一样，直接位转成 C 函数指针
        let connCreate = unsafeBitCast(s, to: XPCConnCreateCFunc.self)
        let connInterface = unsafeBitCast(si, to: XPCConnInterfaceCFunc.self)
        let connResume = unsafeBitCast(sr, to: XPCConnResumeCFunc.self)
        let connEncode = unsafeBitCast(se, to: XPCConnEncodeDictCFunc.self)
        let connCancel = unsafeBitCast(sc, to: XPCConnCancelCFunc.self)
        isInstalling = true
        checkError = nil

        let conn = connCreate(nil, "com.trollstore.inject", 0,
                              xpcInvalidatedDelegate, nil)
        guard let conn else {
            isInstalling = false
            checkError = "TSServer 没接上（可能 TrollStore 版本不匹配），请手动安装。"
            return false
        }
        connInterface(conn, nil)
        connResume(conn)

        let payload = ["ipa": ipa.path, "url": ipa.absoluteString] as CFDictionary
        _ = connEncode(conn, payload, [] as CFArray)

        // 连接被对端断（invalidated）= 请求被拒 / 没被接受，
        // 返回 false 走手动兜底；60 秒内连接保持 = TSServer 在处理
        let isValid: XPCConnIsValidCFunc? = xpcSymbol("XPCConnectionIsValid")
            .map { unsafeBitCast($0, to: XPCConnIsValidCFunc.self) }
        let ok = xpcWaitForInstall(conn, isValid: isValid)
        connCancel(conn)
        isInstalling = false

        if ok {
            // 保守处理「装了 / 可能没装」：置位后退出，让新包起来。
            // 真没装上：旧包被快捷指令自动化重新打开，自动更新
            // 流水线 6h 节流后（或手动点装）再试 —— 自愈。
            UserDefaults.standard.set(true, forKey: Keys.pendingRestart)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                exit(0)
            }
        } else {
            checkError = "TSServer 拒绝了安装请求，请点下方按钮手动安装（包已下载好）。"
        }
        return ok
    }

    /// XPC 没有公开的「等安装完成」机制，能观测的只有连接是否被
    /// invalidate。60 秒内连接被断 = 失败；保持 = 视为在处理。
    private func xpcWaitForInstall(_ conn: OpaquePointer,
                                   isValid: XPCConnIsValidCFunc?) -> Bool {
        guard let isValid else {
            Thread.sleep(forTimeInterval: 60)
            return true
        }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !isValid(conn) { return false }
            Thread.sleep(forTimeInterval: 1)
        }
        return true
    }

    // MARK: 校验

    /// 校验 SHA256（IPA 只有几 MB，整包读进内存算，老设备也没压力）
    static func verify(_ file: URL, expectedSHA256: String) -> Bool {
        do {
            let data = try Data(contentsOf: file)
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return hex.caseInsensitiveCompare(expectedSHA256) == .orderedSame
        } catch {
            return false
        }
    }
}
