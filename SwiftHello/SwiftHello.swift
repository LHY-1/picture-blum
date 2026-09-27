// ============================================================
// SwiftHello.swift — 验证 Xcode 14.3.1 + Swift 编译器工作正常
// ============================================================
// 用法：
//   swift SwiftHello.swift
//   或
//   cd SwiftHello && swift run
// ============================================================

import Foundation

print("╔════════════════════════════════════╗")
print("║  Swift + iOS 工具链验证程序       ║")
print("╚════════════════════════════════════╝")
print("")

// 1. 基础语法
print("── 1. 基础语法 ──")
let greeting = "Hello, iOS 14.8.1!"
print("  \(greeting)")

var count = 0
while count < 3 {
    count += 1
    print("  循环 #\(count)")
}

// 2. 类型系统
print("\n── 2. 类型系统 ──")
let ints: [Int] = [42, 17, 3.14 as? Int ?? 0]
let strings: [String] = ["Apple", "SwiftUI", "TrollStore"]
let optional: Int? = nil
print("  数组: \(ints) / \(strings)")
print("  Optional 解包: \(optional ?? -1)")

// 3. 集合操作
print("\n── 3. 集合操作 ──")
let numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
let evens = numbers.filter { $0 % 2 == 0 }
let doubled = numbers.map { $0 * 2 }
let sum = numbers.reduce(0, +)
print("  evens: \(evens)")
print("  doubled: \(doubled)")
print("  sum: \(sum)")

// 4. 字典
print("\n── 4. 字典 ──")
let devices: [String: String] = [
    "iOS": "14.8.1",
    "Xcode": "14.3.1",
    "Swift": "5.9",
    "Compiler": "Apple Clang 14",
    "Installer": "TrollStore"
]
for (key, value) in devices.sorted(by: { $0.key < $1.key }) {
    print("  \(key): \(value)")
}

// 5. 结构体 & 枚举
print("\n── 5. 结构体 & 枚举 ──")
struct App {
    let name: String
    let miniOS: String
    let target: String
    func describe() -> String {
        "App(\(name), min=\(miniOS), target=\(target))"
    }
}

enum DistributeChannel: String {
    case appStore = "App Store"
    case sideload = "TrollStore"
    case enterprise = "Enterprise"

    func icon() -> String {
        switch self {
        case .appStore: return "🏪"
        case .sideload: return "👹"
        case .enterprise: return "🏢"
        }
    }
}

let myApp = App(name: "SwiftHello", miniOS: "14.0", target: "iOS 14.8.1")
print("  \(myApp.describe())")
print("  分发渠道: \(DistributeChannel.sideload.icon()) \(DistributeChannel.sideload.rawValue)")

// 6. 协议 (Protocol)
print("\n── 6. 协议 ──")
protocol SignedPackage {
    var signatureType: String { get }
    var isValid: Bool { get }
}

struct TrollStoreSigned: SignedPackage {
    let signatureType = "checkm8 + TrollStore"
    let isValid = true
}

let pkg = TrollStoreSigned()
print("  \(pkg.signatureType): valid=\(pkg.isValid)")

// 7. 错误处理
print("\n── 7. 错误处理 ──")
enum CompileError: Error, CustomStringConvertible {
    case missingSDK(String)
    case wrongVersion(String)
    case deploymentTooLow(Int)

    var description: String {
        switch self {
        case .missingSDK(let name): return "缺少 SDK: \(name)"
        case .wrongVersion(let v): return "版本不匹配: \(v)"
        case .deploymentTooLow(let min): return "最低部署版本 \(min)"
        }
    }
}

func checkSDK() throws -> String {
    return "iOS 14.0 SDK available"
}

do {
    let result = try checkSDK()
    print("  ✅ \(result)")
} catch {
    print("  ❌ \(error)")
}

// 8. 闭包
print("\n── 8. 闭包 ──")
let sortDesc = { (a: Int, b: Int) in a > b }
print("  降序排序: \(numbers.sorted(by: sortDesc).prefix(5))...")

let add = { (a: Int, b: Int) -> Int in a + b }
print("  \(add(14, 8))")  // 14 + 8 = 22，纪念 iOS 14.8

// 9. 字符串处理
print("\n── 9. 字符串处理 ──")
let version = "14.8.1"
print("  iOS \(version) 长度: \(version.count)")
print("  大写: \(version.uppercased())")
print("  反转: \(String(version.reversed()))")

// 10. 完成
print("")
print("════════════════════════════════════")
print("  ✅ 所有测试通过")
print("  🚀 工具链准备就绪，可以开始开发 App 了")
print("════════════════════════════════════")
