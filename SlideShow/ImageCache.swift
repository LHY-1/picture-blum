// ============================================================
// ImageCache.swift
// 显示图的内存缓存 —— 配合预加载，切到下一张时不用等加载
//
// 逻辑：
//   播到某张时，提前把队列里下一张加载进这个缓存；
//   切图先查缓存，命中就直接换画面，不转圈。
//   循环播放、洗牌回来重复同一张时也走缓存。
//
// 容量：主图长边按设备屏幕算（老设备 ~2000 像素，解码约 12 MB），
// 上限 5 张 ≈ 60 MB。低内存老设备再大就挤兑了；
// NSCache 在系统内存紧张时还会自动淘汰。
//
// 兼容：iOS 14.0+
// ============================================================

import Foundation
import UIKit

final class ImageCache {

    static let shared = ImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 5
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    /// 照片 id 要带来源前缀（系统相册是 "file:xxx" 之外的 localIdentifier）
    /// —— 直接按传入的 key 存取，不加工。

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        // cost 按像素数算，NSCache 淘汰时优先扔贵的
        let pixels = Int(image.size.width * image.scale) *
                    Int(image.size.height * image.scale)
        cache.setObject(image, forKey: key as NSString, cost: pixels)
    }

    func remove(_ key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// 调整缓存上限（张大图约 12 MB，总内存预留按 14 MB/张算）。
    func setCountLimit(_ n: Int) {
        let safe = max(n, 1)
        cache.countLimit = safe
        cache.totalCostLimit = safe * 14 * 1024 * 1024
    }
}
