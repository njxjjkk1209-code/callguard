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

    /// Tweak 配置的**主通道**：App Group 容器根目录。
    ///
    /// 这条路比 /var/mobile/Library 可靠得多 —— App 写自己的 App Group 容器
    /// 是沙盒内行为，一定成功；而 SpringBoard 越狱后不受沙盒限制，能直接读
    /// 任意容器。所以不依赖 TrollStore 是否给了 no-sandbox。
    static var tweakConfigInContainerURL: URL {
        dataDirectory.appendingPathComponent("tweak_rules.plist")
    }

    /// Tweak 日志的主通道，同样走容器
    static var tweakLogInContainerURL: URL {
        dataDirectory.appendingPathComponent("tweak_log.jsonl")
    }

    /// Tweak 心跳文件：Tweak 在 SpringBoard 里加载成功后会写这个文件，
    /// 内容是版本号 / 启动时间 / pid。
    ///
    /// 这是判断「Tweak 到底装没装、跑没跑」的唯一可靠依据 ——
    /// 光看配置文件存在只能说明 App 导出成功，跟 Tweak 有没有加载是两件事。
    static var tweakReadyURL: URL {
        dataDirectory.appendingPathComponent("tweak_ready.json")
    }

    static var isTweakRunning: Bool {
        FileManager.default.fileExists(atPath: tweakReadyURL.path)
    }

    static var tweakReadyInfo: [String: Any]? {
        guard let data = try? Data(contentsOf: tweakReadyURL),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return nil
        }
        return dict
    }

    // MARK: - 与越狱 Tweak 的共享通道
    //
    // SpringBoard 进程读不到 App 沙盒，也拿不到 App Group 容器，只能走固定路径。
    // 但 TrollStore 给 App 的 entitlement 并不保证能写 /var/mobile/Library——
    // 沙盒是否真正解除取决于 TrollStore 用的签名模板，实测存在写不进去的情况。
    //
    // 所以这里做多路径探测：逐个尝试「建目录 + 写探针文件」，第一个真正写得进去的
    // 胜出。Tweak 端用同样的顺序查找，保证双方选中同一个目录。

    static let tweakDirectoryCandidates: [String] = [
        "/var/mobile/Library/CallGuard",
        "/var/jb/var/mobile/Library/CallGuard",
        "/var/mobile/Documents/CallGuard",
    ]

    private static var cachedTweakDir: URL?

    /// 探测结果说明，直接显示到设置页。
    /// 只显示「未导出」会让人无从下手，必须把具体原因说出来。
    private(set) static var tweakChannelDiagnostics = "尚未探测"

    static var tweakDirectory: URL {
        if let d = cachedTweakDir { return d }
        return resolveTweakDirectory()
    }

    /// Tweak 读取的规则配置
    static var tweakConfigURL: URL {
        tweakDirectory.appendingPathComponent("tweak_rules.plist")
    }

    /// Tweak 写入的拦截日志（JSONL），App 启动时导入后清空
    static var tweakLogURL: URL {
        tweakDirectory.appendingPathComponent("tweak_log.jsonl")
    }

    /// 当前目录是否落在 Tweak 也能读到的候选路径上。
    /// false 表示已降级到 App Group 容器：App 侧导出成功，但 Tweak 拿不到。
    static var isTweakChannelReachable: Bool {
        tweakDirectoryCandidates.contains(tweakDirectory.path)
    }

    /// 清缓存，下次访问重新探测。
    /// 先装 App 后装 Tweak 时，目录可能是 Tweak 才建出来的，需要重试一次。
    static func resetTweakChannelCache() {
        cachedTweakDir = nil
        tweakChannelDiagnostics = "尚未探测"
    }

    @discardableResult
    static func resolveTweakDirectory() -> URL {
        let fm = FileManager.default
        var report: [String] = []

        for path in tweakDirectoryCandidates {
            let url = URL(fileURLWithPath: path)
            do {
                if !fm.fileExists(atPath: path) {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                }
                // 能建目录不等于能写文件——目录已存在但属主是 root、权限 755 时
                // createDirectory 会直接返回成功，写文件才失败。必须用探针验证。
                let probe = url.appendingPathComponent(".cg_probe")
                try Data("ok".utf8).write(to: probe, options: .atomic)
                try? fm.removeItem(at: probe)

                cachedTweakDir = url
                tweakChannelDiagnostics = "使用 \(path)"
                return url
            } catch {
                let e = error as NSError
                report.append("\(path) → \(e.localizedDescription)")
            }
        }

        // 全部失败：退到 App Group 容器。至少 App 侧不崩、导出流程能走完，
        // 但 Tweak 读不到，设置页会明确标出这一点。
        let fallback = dataDirectory.appendingPathComponent("Bridge", isDirectory: true)
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        cachedTweakDir = fallback
        tweakChannelDiagnostics = "均不可写：" + report.joined(separator: "；")
        return fallback
    }
}
