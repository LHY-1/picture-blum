// ============================================================
// ThumbnailCache.swift
// 有上限的缩略图缓存
//
// 为什么不用普通字典：
//   老设备内存只有 1-2 GB。用 [String: UIImage] 缓存缩略图时，
//   5000 张照片 × 200×200（解码后约 160 KB）= 800 MB，必然被系统杀掉。
//
// NSCache 的两个好处：
//   1. countLimit / totalCostLimit 到顶自动淘汰最久未用的
//   2. 系统发出内存警告时自动清空（这是 NSCache 内建行为，无需手动处理）
//
// 兼容：iOS 14.0+
// ============================================================

import UIKit

final class ThumbnailCache {

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 300                      // 最多 300 张
        cache.totalCostLimit = 48 * 1024 * 1024     // 或 48 MB，谁先到算谁
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        // cost 用解码后的字节数估算，NSCache 据此淘汰
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        let cost = Int(pixels * 4)                  // RGBA 每像素 4 字节
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func clear() {
        cache.removeAllObjects()
    }
}
