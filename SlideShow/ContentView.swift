// ============================================================
// ContentView.swift
// 根视图：根据状态决定显示选图界面还是播放器
//
// 兼容：iOS 14.0+
// ============================================================

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: SlideShowViewModel
    @State private var didStart = false

    var body: some View {
        Group {
            if viewModel.library.isLoading && viewModel.library.photos.isEmpty {
                LoadingView()
            } else if viewModel.library.photos.isEmpty {
                EmptyStateView()
            } else {
                SlideShowPlayerView()
            }
        }
        .statusBarHidden(true)          // 隐藏状态栏，全屏体验
        // 主题走 ThemeManager（直接设 UIWindow），不在这加 preferredColorScheme
        .onAppear {
            if !didStart {
                didStart = true
                viewModel.start()
            }
        }
    }
}

// MARK: - 加载中

struct LoadingView: View {
    @EnvironmentObject var viewModel: SlideShowViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    // .tint() 是 iOS 15+，用 progressViewStyle 代替
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))

                Text("正在加载相册…")
                    .foregroundColor(.white.opacity(0.8))
                    .font(.headline)

                if let msg = viewModel.library.errorMessage {
                    Text(msg)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding()
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

// MARK: - 空状态 / 权限引导

struct EmptyStateView: View {
    @EnvironmentObject var viewModel: SlideShowViewModel
    @State private var showMessage = false

    /// 相册权限是否已给。给了权限但没照片时，不能再喊「授予权限」
    /// —— 那是误报，真正原因多半是来源模式不对。
    private var hasPermission: Bool {
        viewModel.library.authorizationStatus == .authorized
            || viewModel.library.authorizationStatus == .limited
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 72))
                    .foregroundColor(.white.opacity(0.6))

                Text("还没有可播放的照片")
                    .font(.title2)
                    .foregroundColor(.white)

                if let msg = viewModel.library.errorMessage {
                    Text(msg)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if hasPermission {
                    // 有权限但没照片：是来源/内容的问题，不是权限
                    Text("确认来源模式里有照片：设置 → 照片来源，\n或先用「上传服务」传几张照片进来。")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Button(action: { showMessage = true }) {
                        Label("授予相册权限", systemImage: "lock.open")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }

                Button(action: {
                    viewModel.reloadLibrary()
                }) {
                    Text("刷新")
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .alert(isPresented: $showMessage) {
            Alert(
                title: Text("需要相册权限"),
                message: Text("请在 iPad 设置 → 隐私 → 照片中允许本 App 访问照片。"),
                dismissButton: .default(Text("好"))
            )
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(SlideShowViewModel())
    }
}
