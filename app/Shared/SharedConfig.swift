//
//  SharedConfig.swift
//  App / Extension 共用的路径与常量。
//
//  rootless 越狱 + TrollStore 环境下 App Group 不一定可用，
//  这里做三级降级：App Group → Application Support → Caches。
//

import Foundation

enum SharedConfig {

    /// 必须与 entitlements 里的 application-groups 一致
    static let appGroupID = "group.com.k.callguard"

    static let databaseName = "callguard.sqlite"

    /// CallDirectory extension 的 bundle id
    static let directoryExtensionID = "com.k.callguard.directory"

    /// App Group 容器是否可用（TrollStore 下可能为 nil）
    static var isAppGroupAvailable: Bool {
        containerURL != nil
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
    }

    /// 数据目录，三级降级
    static var dataDirectory: URL {
        let fm = FileManager.default

        if let c = containerURL {
            return c
        }

        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("CallGuard", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var databaseURL: URL {
        dataDirectory.appendingPathComponent(databaseName)
    }

    /// CallDirectory 读取的拦截列表（一行一个 E.164 号码，升序）
    static var blocklistExportURL: URL {
        dataDirectory.appendingPathComponent("blocklist.txt")
    }

    /// CallDirectory 读取的识别列表（`号码\t标签`，一行一条，升序）
    static var identifyExportURL: URL {
        dataDirectory.appendingPathComponent("identify.txt")
    }

    // MARK: - 与越狱 Tweak 的共享通道
    //
    // SpringBoard 进程读不到 App 沙盒，也拿不到 App Group 容器，
    // 只能走固定路径。TrollStore 安装的 App 带 platform-application
    // entitlement，可以直接写 /var/mobile/Library/。

    static let tweakDirectory = URL(fileURLWithPath: "/var/mobile/Library/CallGuard")

    /// Tweak 读取的规则配置
    static var tweakConfigURL: URL {
        tweakDirectory.appendingPathComponent("tweak_rules.plist")
    }

    /// Tweak 写入的拦截日志（JSONL），App 启动时导入后清空
    static var tweakLogURL: URL {
        tweakDirectory.appendingPathComponent("tweak_log.jsonl")
    }

    /// 确保共享目录存在；写失败说明没有 platform-application 权限
    @discardableResult
    static func ensureTweakDirectory() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: tweakDirectory.path) { return true }
        do {
            try fm.createDirectory(at: tweakDirectory,
                                   withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("[CallGuard] 无法创建共享目录 %@: %@",
                  tweakDirectory.path, error.localizedDescription)
            return false
        }
    }
}
