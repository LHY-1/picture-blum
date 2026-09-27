# 📸 照片幻灯片播放器 (SlideShow)

一个用 SwiftUI 写的照片幻灯片 App，**面向电子相框场景**，兼容 **iOS 14.0+**，通过 **TrollStore** 安装。

## ✨ 功能

### 播放
- **全屏幻灯片** — 自动切换，全屏无干扰
- **防止自动息屏** — 播放期间屏幕常亮（`isIdleTimerDisabled`）
- **播放速度可调** — 1-60 秒每张，5 个快捷档位
- **循环模式** — 顺序 / 循环当前 / 循环全部
- **随机播放** — 每次重启自动换一批
- **手势操作** — 左右滑动切图，点击显隐控制条
- **照片选择** — 从相册勾选要播放的照片

### 电子相框自动化
- **定时开关播** — 设定时段（如 07:00-23:00）自动开播/暂停，**支持跨午夜**
- **断点续播** — App 重启后从上次那张继续，不从头翻
- **加载超时跳过** — iCloud 照片卡住时自动跳下一张，相框不会定格

### 上传照片（iPad 自己当服务器）
- **App 内起 HTTP 服务** — 按需开启，不用连电脑
- **显示网址 + 二维码** — 别的设备扫码就能传，不用手输 IP
- **HEIC 直接支持** — iPhone/iPad 拍的照片不用转格式
- **自动入库** — 传完自动进播放列表，相框不打断当前这张
- **手动确认模式** — 也可以先放「待导入」，看过再入库

## 📁 项目结构

```
SlideShow/
├── SlideShowApp.swift          # App 入口
├── ContentView.swift           # 根视图（状态分发）
├── SlideShowViewModel.swift    # 播放核心（状态、定时器、超时、断点）
├── FrameSchedule.swift         # 定时开关播（时段计算 + 持久化）
├── PlaybackStore.swift         # 断点续播 + 照片来源持久化
│
├── PhotoLibraryManager.swift   # 照片来源（系统相册 + 上传的）
├── LocalPhotoStore.swift       # App 自己的照片库（Inbox / Media / Thumbs）
├── ThumbnailCache.swift        # 内存受限的缩略图缓存
│
├── HTTPServerCore.swift        # 通用 HTTP/1.1 服务器（不依赖 UIKit）
├── PhotoServer.swift           # 上传服务业务逻辑 + 网页
├── NetworkInfo.swift           # 取局域网 IP
├── ServerSheet.swift           # 上传服务面板（开关 / 网址 / 二维码 / 收件箱）
│
├── SlideShowPlayerView.swift   # 全屏播放器 UI
├── SettingsSheet.swift         # 设置面板
├── PhotoGridView.swift         # 照片选择网格
│
├── Info.plist                  # 含相册 + 局域网权限描述
├── SlideShow.entitlements      # ad-hoc 签名用
├── build_ipa.sh                # 构建 IPA
├── run_simulator.sh            # 在模拟器里跑
├── tools/make_icon.swift       # 图标生成器
└── README.md
```

## 📤 上传照片怎么用

**场景**：手机拍完照，想让客厅的 iPad 相框放出来，但不想插线、不想同步。

```
iPad（相框）                        手机 / 电脑
──────────────                      ─────────────
设置 → 上传照片 → 开启服务
   ↓
显示 http://192.168.0.20:8080  ──→  连同一个 Wi-Fi
   ↓                                  浏览器打开这个网址
   ↓                                  选照片 → 上传
   ↓                                        │
收到 → 自动入库 → 相框接着播  ←──────────────┘
```

### 步骤

1. iPad 上打开 App → 齿轮 → **上传照片** → 打开「开启上传服务」
2. 第一次会弹**「是否允许访问本地网络」→ 必须选允许**，否则别的设备连不上
3. 记下显示的那个网址（点一下可复制），或点「显示二维码」
4. 手机/电脑连**同一个 Wi-Fi**，浏览器打开网址（扫码的话直接打开）
5. 选照片上传 → iPad 相框自动就放上了

### 两种入库模式

| 模式 | 行为 | 适合 |
|---|---|---|
| **自动导入**（默认） | 传完直接进播放列表，相框立刻能播 | 自己的设备，信任来源 |
| **手动确认** | 先落在「待导入」，在面板里看过再点导入 | 别人传来一堆照片时 |

面板里也能逐张删除、清空上传的照片、切换「播放哪些照片」（系统相册 / 上传的 / 两者）。

### 上传的照片存在哪

存在 App 自己的 `Documents/PhotoStation/` 下，**不写进系统相册**：

```
Documents/PhotoStation/
├── Inbox/     收到的上传，尚未入库
├── Media/     已入库，参与播放
└── Thumbs/    缩略图缓存（网页和网格用）
```

这么设计的原因：

- 写系统相册要额外权限，iOS 14 上「仅添加」权限行为不稳定
- 相册里混进几千张自己的照片后没法批量清掉
- 相框是长期无人值守运行的，自己的库自己管最省心

顺带开了 `UIFileSharingEnabled`，所以这个目录在**「文件」App** 和 **Finder** 里也能看到，
照片直接拖进去会被自动收编进上传库（见 `LocalPhotoStore.adoptLooseFiles()`）。

### 限制

- 单张最大 **64 MB**（整包在内存里，2 GB 内存的设备不能开太大）
- 只在 App 前台运行时有效，息屏或退出 App 服务就断了
- 只支持同一个局域网，没有鉴权 —— 别在公共 Wi-Fi 上开

## 🚀 构建（一行命令）

**不需要建 Xcode 项目，不需要 Apple ID，不需要苹果证书。**

TrollStore 安装时会用它自己的签名重新签，所以 ad-hoc 签名就够了：

```bash
cd SlideShow
bash build_ipa.sh
```

产物：`build/SlideShow.ipa`

脚本做的事：

```
1. 检查 iOS SDK
2. 清理旧产物
3. swiftc 编译全部 .swift → arm64 / iOS 14.0
4. 用 tools/make_icon.swift 画图标（5 个尺寸）
5. 组装 .app bundle（Info.plist + PkgInfo + 图标 + 可执行文件）
6. codesign ad-hoc 签名
7. 打包成 Payload/SlideShow.app 结构的 IPA
```

### 安装到 iPad

1. AirDrop 把 `SlideShow.ipa` 传到 iPad（或网盘 / 数据线）
2. 在 iPad 上点开这个文件 → 用 TrollStore 打开
3. TrollStore 里点 Install

### 改配置

| 要改的东西 | 位置 |
|---|---|
| Bundle ID / 版本号 / 显示名 | `build_ipa.sh` 顶部配置区 |
| 最低系统版本 | `build_ipa.sh` 的 `MIN_IOS` + `Info.plist` 的 `MinimumOSVersion`（两处要一致） |
| 设备族（iPhone / iPad） | `Info.plist` 的 `UIDeviceFamily`，`1`=iPhone `2`=iPad |
| 图标样式 | `tools/make_icon.swift` |

### 为什么不用 Xcode 项目

代码全部是纯 SwiftUI + 系统框架，没有资源目录、没有 CocoaPods、没有多 target，
手写 bundle 比维护 `.xcodeproj` 简单得多，也更容易看出构建到底做了什么。

需要 Xcode 项目的场景：要用调试器、要用 Instruments、要加 Asset Catalog、要发 App Store。

## 📱 旧设备兼容说明

目标设备：**低内存的老 iPad / iPhone**（1-2 GB 内存，iOS 14 时代），
长期当相框挂在那里用。下面的取舍都是按这种老设备来的，新设备不受影响。

### 内存是唯一的硬约束

1-2 GB 内存决定了所有取舍。已有的针对性处理：

| 措施 | 原因 |
|---|---|
| 缩略图走 `NSCache`（上限 300 张 / 48 MB） | 无上限字典缓存 5000 张 = 800 MB，必崩 |
| 每格缩略图独立成 View，各持 `@State` | 选中状态变化只重绘一格，而非整个网格 |
| `LazyVGrid` + `onAppear` 按需加载 | 只请求可见区域的缩略图 |
| 主图长边按设备屏幕动态计算（老设备 ~2000，新设备跟屏幕走，封顶 4096） | 按屏幕解码而不整图读进内存，低内存设备不爆 |

`NSCache` 在系统发出内存警告时会自动清空，不需要手动处理。

### 屏幕

- 老设备基本都是 **LCD 而非 OLED** → **不存在烧屏问题**，"防烧屏漂移"可以不做
- 主图解码上限跟着屏幕走（`maxPixelDimension` 动态计算），不同设备不用各调各的

### 控件尺寸

用 `horizontalSizeClass == .regular` 判定，iPad 上控件放大 1.4 倍。
用 size class 而不是 `UIScreen.bounds`，旋转时能自动更新。

### 照片选择器

用 `.fullScreenCover` 而非 `.sheet`——iPad 的 sheet 是 540pt 浮动表单，网格会挤成一团。

### 多任务

`UIRequiresFullScreen = true`，禁用 Slide Over / 分屏，不会被手势划走。

### 必须在 Xcode 里确认设备族

```
Target → General → Deployment Info → Devices
→ 选 "Universal" 或 "iPad"
```

对应 `TARGETED_DEVICE_FAMILY`：`1,2` = 通用，`2` = 仅 iPad，`1` = 仅 iPhone。

> 新建 Xcode 项目默认可能只选了 iPhone。不改的话装到 iPad 上会以兼容模式运行，
> 画面四周一圈黑边，无法全屏。

### 系统版本

老设备一般停留在 **iOS 14**。App 按 iOS 14 的 API 能力编写，
在更新的系统上同样正常运行。

## 📺 当电子相框用：推荐配置

| 设置项 | 推荐值 | 原因 |
|---|---|---|
| 每张停留 | 10-30 秒 | 太短看不清，太长没意思 |
| 循环模式 | 全部 | 一直播下去 |
| 随机播放 | 开 | 每天不重样 |
| 定时开关播 | 07:00 - 23:00 | 夜间省电、不扰眠 |
| 防止自动息屏 | 开 | 相框必须 |
| 图片加载超时 | 10 秒 | iCloud 照片兜底 |

**系统侧配合**：
- 设置 → 辅助功能 → **引导式访问** → 开启。连按三次侧边键锁定，彻底防误触
- 设置 → 显示与亮度 → **自动锁定 → 永不**（或设长一点，App 暂停时会释放常亮让系统锁屏）
- 设置 → 显示与亮度 → **自动亮度 → 开**（夜间自动变暗）
- 快捷指令 → 自动化 → **充电器连接时 → 打开 SlideShow**（关掉"运行前询问"）

## ⚙️ 关键实现说明

### 定时开关播

`FrameSchedule` 每 20 秒检查一次当前时间是否落在播放时段内，跨过边界时通过
Combine 通知 ViewModel 自动播放/暂停。

时段判断是纯函数，跨午夜也正确：

```swift
static func computeIsActive(enabled: Bool, start: Date, end: Date, now: Date) -> Bool {
    guard enabled else { return true }
    let nowM = minutes(from: now), startM = minutes(from: start), endM = minutes(from: end)
    if startM == endM { return true }                    // 起止相同 = 全天
    if startM < endM { return nowM >= startM && nowM < endM }   // 07:00-23:00
    return nowM >= startM || nowM < endM                 // 22:00-06:00 跨午夜
}
```

### 屏幕常亮的时机

只在**三个条件同时满足**时才阻止息屏，否则释放 idle timer 让系统省电：

```swift
UIApplication.shared.isIdleTimerDisabled = keepsScreenOn && isPlaying && scheduleActive
```

### 断点续播

每换一张照片就写一次 `UserDefaults`（照片 id + 序号）。重启时优先按照片 id 定位，
照片被删除则退回序号：

```swift
if let lastId = PlaybackStore.lastPhotoId,
   let found = currentOrder.firstIndex(where: { $0.id == lastId }) {
    index = found
}
```

### 加载超时跳过

每次加载生成一个 UUID token，超时回调先校验 token 是否仍是当前的 ——
避免慢回调覆盖新图，也避免误跳过已经加载好的照片：

```swift
let token = UUID()
loadToken = token
library.loadImage(for: photo) { image in
    guard self.loadToken == token else { return }   // 旧回调，丢弃
    ...
}
DispatchQueue.main.asyncAfter(deadline: .now() + loadTimeout) {
    guard self.loadToken == token, self.isCurrentImageLoading else { return }
    self.advance(direction: 1)                      // 超时，跳下一张
}
```

### iOS 14 兼容性规避

| 特性 | iOS 15+ | iOS 14 替代方案 |
|---|---|---|
| `.task { }` 修饰符 | ✅ | `.onAppear { Task { } }` |
| `@Environment(\.dismiss)` | ✅ | `@Binding var isPresented: Bool` |
| `Task.sleep(nanoseconds:)` | ✅ | `DispatchQueue.main.asyncAfter` |
| `.persistentSystemOverlays` | ✅ (16+) | 不用 |
| `.presentationDetents` | ✅ (16+) | 不用 |

### 定时器在交互时不停

```swift
RunLoop.main.add(timer, forMode: .common)   // 否则拖拽/滚动时会被暂停
```

### 照片加载策略

- **主图**：长边按设备屏幕动态计算（封顶 4096），防内存爆炸
- **缩略图**：200 像素，网格列表用
- **iCloud 照片**：`isNetworkAccessAllowed = true`
- **回调线程**：所有回调回主线程，避免 UI 崩溃

## 🎬 操作说明

- **点击屏幕** — 显隐控制条（3 秒自动隐藏）
- **左滑 / 右滑** — 上/下一张
- **底部中央大按钮** — 播放 / 暂停
- **顶部月亮图标** — 息屏开关（黄色=常亮）
- **顶部绿色 wifi 图标** — 上传服务运行中（只读提示，不挡操作）
- **顶部齿轮** — 设置（含定时开关播、上传照片）
- **顶部九宫格** — 照片选择

## 📝 后续可扩展

- [ ] 上传时自动压缩（省空间，相框用不到原图分辨率）
- [ ] 上传密码保护（现在同一局域网内谁都能传）
- [ ] 断点续传（网络不好时大文件要重传）
- [ ] 只播收藏照片（`PHAsset.isFavorite`）
- [ ] 跳过截图和录屏（`mediaSubtype` 过滤）
- [ ] 夜间自动调暗（`UIScreen.main.brightness`）
- [ ] 拍摄日期水印
- [ ] 按相簿筛选
- [ ] 背景音乐
- [ ] Ken Burns 转场动画

## 🐛 已知限制

- iOS 14 上 `PHAuthorizationStatus.limited` 支持有限
- iOS 不允许 App 主动关闭屏幕，定时停止只能做到"暂停 + 释放常亮"，实际锁屏由系统自动锁定时间决定
- App 无法自行开机自启，需配合快捷指令自动化或越狱 LaunchDaemon
- 上传服务**只在 App 前台运行时有效**，息屏或切走就断 —— iOS 不给普通 App 长期后台监听端口的能力
- 上传服务**没有鉴权**，同一局域网内任何人知道地址就能传。家用 Wi-Fi 没问题，公共网络别开
- 未实现 3D Touch / Haptic 反馈

## 📄 授权

MIT
