// ============================================================
// make_icon.swift  —  生成 App 图标 PNG
//
// 这是个 macOS 命令行工具（不是 iOS 代码），由 build_ipa.sh 调用。
// 用法：make_icon <尺寸> <输出路径>
//
// 不依赖 Xcode 资源目录，直接画 PNG 放进 app bundle 根目录。
// ============================================================

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3, let size = Int(args[1]) else {
    FileHandle.standardError.write("用法: make_icon <尺寸> <输出路径>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = args[2]

let s = CGFloat(size)
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("无法创建绘图上下文\n".data(using: .utf8)!)
    exit(1)
}

// ── 背景：深色渐变 ──
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 1),
        CGColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: s),
    end: CGPoint(x: s, y: 0),
    options: []
)

// ── 中间：白色圆 ──
let circleDiameter = s * 0.52
let circleRect = CGRect(
    x: (s - circleDiameter) / 2,
    y: (s - circleDiameter) / 2,
    width: circleDiameter,
    height: circleDiameter
)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
ctx.fillEllipse(in: circleRect)

// ── 圆内：播放三角 ──
let triW = circleDiameter * 0.34
let triH = circleDiameter * 0.40
let cx = s / 2
let cy = s / 2
// 视觉居中：三角形重心偏右，往左挪一点
ctx.setFillColor(CGColor(red: 0.06, green: 0.07, blue: 0.12, alpha: 1))
ctx.beginPath()
ctx.move(to: CGPoint(x: cx - triW / 2 - triW * 0.08, y: cy + triH / 2))
ctx.addLine(to: CGPoint(x: cx - triW / 2 - triW * 0.08, y: cy - triH / 2))
ctx.addLine(to: CGPoint(x: cx + triW / 2 + triW * 0.14, y: cy))
ctx.closePath()
ctx.fillPath()

// ── 四角：小圆点，暗示"多张照片" ──
// margin 必须明显大于圆的半径(0.26s)，否则圆点会压在圆边上显得脏。
// 0.33s 的斜向距离约 0.47s，落在圆外的角落里。
let dotR = s * 0.032
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.45))
let margin = s * 0.33
for (dx, dy) in [(-1.0, 1.0), (1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)] {
    let cx2 = s / 2 + CGFloat(dx) * margin
    let cy2 = s / 2 + CGFloat(dy) * margin
    ctx.fillEllipse(in: CGRect(x: cx2 - dotR, y: cy2 - dotR, width: dotR * 2, height: dotR * 2))
}

// ── 写出 PNG ──
guard let image = ctx.makeImage() else {
    FileHandle.standardError.write("无法生成图像\n".data(using: .utf8)!)
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(
    url as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    FileHandle.standardError.write("无法创建输出文件: \(outputPath)\n".data(using: .utf8)!)
    exit(1)
}

CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("写入 PNG 失败\n".data(using: .utf8)!)
    exit(1)
}
