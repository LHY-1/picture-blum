// ============================================================
// SlideShowApp.swift
// 相册幻灯片播放 App - 主入口
//
// 功能特性:
//  - 从系统相册读取照片
//  - 全屏幻灯片自动播放
//  - 保持屏幕常亮 (防止自动息屏)
//  - 播放速度可调 / 随机播放 / 循环播放
//  - 进度控制 (前进 / 后退 / 暂停)
// ============================================================

import SwiftUI

@main
struct SlideShowApp: App {
    @StateObject private var viewModel = SlideShowViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onChange(of: scenePhase) { phase in
                    // 没声明后台音频，切后台音乐会被系统停掉；
                    // 回前台把选中的歌重新放起来
                    if phase == .active {
                        viewModel.applyMusic()
                    }
                }
        }
    }
}
