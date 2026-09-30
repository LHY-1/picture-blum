// ============================================================
// UpdateInfo.swift
// 版本更新：轮询 GitHub Releases 的 manifest，判断有没有新版
//
// 更新走「引导安装」模式：
//   App 拉到新包 → 存到「文件」App → 用户点一次 TrollStore → 装完
//   新包起来后自动回到播放画面。全程 App 只做前两步，安装交给
//   TrollStore（它有系统级签名权限，App 自己装不了）。
//
// 彻底无人值守的「App 自己装自己」（TSServer XPC）是 2.0 的活，
// 现在设备端先把 manifest 拉通，链路是现成的。
//
// 兼容：iOS 14.0+（URLSession 老 API，无 async/await；
//       UpdateChecker 里不用 Binding(get:set:)，避免 iOS 14 并发符号坑）
// ============================================================

import Foundation
import SwiftUI

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

// MARK: - 设置页用的可观察对象
//
// 用 @StateObject 持有 —— 别写 .constant(UpdateChecker())，
// 那个构造调用发生在 body 里（iOS 14 的 MainActor 隔离会把
// ObservableObject() 的默认实现推断成非隔离，构造时越 actor，
// 和 build_ipa.sh 3.5 步查的那条线同源）。

final class UpdateChecker: ObservableObject {
    @Published private(set) var manifest: UpdateInfo.Manifest?
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    /// 成功存进「文件」App 的包路径；nil = 还没存过
    @Published private(set) var downloadedIPA: URL?
    @Published private(set) var lastCheckAt: Date?

    /// 上次提示检查失败的文案；nil = 无
    @Published private(set) var checkError: String?

    /// 已经下载过、不用再下的最新 build 号
    private let checkedBuildKey = "com.yuan.slideshow.updateCheckedBuild"
    private let lastCheckAtKey = "com.yuan.slideshow.updateLastCheckAt"

    func check() {
        guard !isChecking else { return }
        isChecking = true
        checkError = nil
        manifest = nil

        // 已经下载过的版本就不再重复拉（重进设置页也能看到下载好的包）
        let stored = UserDefaults.standard.integer(forKey: checkedBuildKey)
        let savedURL = URL(string: UserDefaults.standard.string(forKey: "com.yuan.slideshow.downloadedIPA") ?? "")
        if stored > 0, let url = savedURL, FileManager.default.fileExists(atPath: url.path) {
            downloadedIPA = url
            isChecking = false
            return
        }

        UpdateInfo.check { [weak self] newManifest, error in
            guard let self = self else { return }
            self.isChecking = false
            if let m = newManifest {
                self.manifest = m
                self.lastCheckAt = Date()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckAtKey)
            } else if let e = error {
                self.checkError = "检查更新失败：\(e.localizedDescription)"
            }
        }
    }

    /// 下载到 Documents/Update/，再开「文件」App 让用户用它装
    func download() {
        guard let manifest = manifest, !isDownloading else { return }
        isDownloading = true
        checkError = nil

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
                let moved = dest.deletingLastPathComponent().appendingPathComponent(dest.lastPathComponent)
                try? FileManager.default.removeItem(at: moved)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: moved)
                    self.downloadedIPA = moved
                    UserDefaults.standard.set(manifest.build, forKey: self.checkedBuildKey)
                    UserDefaults.standard.set(moved.absoluteString, forKey: "com.yuan.slideshow.downloadedIPA")
                } catch {
                    self.checkError = "保存失败：\(error.localizedDescription)"
                    return
                }
                self.openFilesApp()
            }
        }.resume()
    }

    /// 打开「文件」App（com.apple.files.app）。用户在里面找到
    /// 「SlideShow」文件夹 → 点 .ipa → 用 TrollStore 打开。
    func openFilesApp() {
        let url = URL(string: "file://com.apple.files.app")!
        UIApplication.shared.open(url) { _ in }
    }
}
