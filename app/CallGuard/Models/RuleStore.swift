//
//  RuleStore.swift
//  业务层：规则 CRUD、引擎重建、CallDirectory 导出与刷新。
//

import Foundation
import CallKit

@MainActor
final class RuleStore: ObservableObject {

    static let shared = RuleStore()

    @Published private(set) var rules: [Rule] = []
    @Published private(set) var whitelist: [WhitelistEntry] = []
    @Published private(set) var logs: [CallLogEntry] = []
    @Published private(set) var todayBlocked = 0
    @Published private(set) var totalBlocked = 0
    @Published private(set) var engineRuleCount = 0
    @Published var errorMessage: String?
    @Published var lastReloadMessage: String?

    private(set) var engine: CGEngine?

    private init() {}

    // MARK: - 启动

    func bootstrap() {
        do {
            try Database.shared.openIfNeeded()
            try seedIfNeeded()
            try refreshAll()
            rebuildEngine()
            syncExports()
            importTweakLogs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func seedIfNeeded() throws {
        guard try Database.shared.fetchRules().isEmpty else { return }

        guard let url = Bundle.main.url(forResource: "seed_rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(SeedDocument.self, from: data) else {
            return
        }

        for r in doc.rules {
            guard let type = RuleType(seedName: r.type),
                  let action = RuleAction(seedName: r.action) else { continue }
            try Database.shared.insertRule(type: type, value: r.value,
                                           label: r.label, action: action, source: "seed")
        }

        for w in doc.whitelist_templates {
            try Database.shared.addWhitelist(number: w.value,
                                             isPrefix: w.type == "prefix",
                                             note: w.label)
        }
    }

    // MARK: - 刷新

    func refreshAll() throws {
        rules     = try Database.shared.fetchRules()
        whitelist = try Database.shared.fetchWhitelist()
        logs      = try Database.shared.fetchLogs(limit: 200)
        todayBlocked = try Database.shared.todayBlockedCount()
        totalBlocked = try Database.shared.totalBlockedCount()
    }

    func refreshLogs() {
        do {
            logs = try Database.shared.fetchLogs(limit: 200)
            todayBlocked = try Database.shared.todayBlockedCount()
            totalBlocked = try Database.shared.totalBlockedCount()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 引擎

    func rebuildEngine() {
        let e = CGEngine()

        for r in rules where r.enabled {
            let cr = CGRule()
            cr.ruleId  = Int(r.id)
            cr.type    = CGRuleType(rawValue: r.type.rawValue) ?? .exact
            cr.action  = CGAction(rawValue: r.action.rawValue) ?? .mark
            cr.value   = r.value
            cr.label   = r.label
            cr.enabled = true
            e.addRule(cr)
        }

        for w in whitelist {
            if w.isPrefix {
                e.addWhitelistPrefix(w.number)
            } else {
                e.addWhitelist(w.number)
            }
        }

        e.finalizeEngine()
        engine = e
        engineRuleCount = Int(e.ruleCount)
    }

    // MARK: - 规则增删改

    func addRule(type: RuleType, value: String, label: String, action: RuleAction) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "规则内容不能为空"
            return
        }
        do {
            _ = try Database.shared.insertRule(type: type, value: trimmed,
                                               label: label, action: action)
            try refreshAll()
            rebuildEngine()
            syncExports()
            scheduleDirectoryReload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteRule(_ rule: Rule) {
        do {
            try Database.shared.deleteRule(id: rule.id)
            try refreshAll()
            rebuildEngine()
            syncExports()
            scheduleDirectoryReload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAction(_ action: RuleAction, for rule: Rule) {
        do {
            try Database.shared.updateRuleAction(id: rule.id, action: action)
            try refreshAll()
            rebuildEngine()
            syncExports()
            scheduleDirectoryReload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggle(_ rule: Rule) {
        do {
            try Database.shared.setRuleEnabled(id: rule.id, enabled: !rule.enabled)
            try refreshAll()
            rebuildEngine()
            syncExports()
            scheduleDirectoryReload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 白名单

    func addWhitelist(number: String, isPrefix: Bool) {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try Database.shared.addWhitelist(number: trimmed, isPrefix: isPrefix)
            try refreshAll()
            rebuildEngine()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeWhitelist(_ entry: WhitelistEntry) {
        do {
            try Database.shared.removeWhitelist(number: entry.number)
            try refreshAll()
            rebuildEngine()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 日志

    func clearLogs() {
        do {
            try Database.shared.clearLogs()
            refreshLogs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - CallDirectory

    /// 导出 CallDirectory 用的两个列表。
    ///
    /// - blocklist.txt：action == block 的精确号码，直接拦截
    /// - identify.txt：action == mark 的精确号码 + 标签，来电时显示"疑似骚扰"
    ///
    /// 号段（prefix）规则**导不出去**——CallDirectory 不支持前缀匹配，
    /// 那部分只能靠越狱 Tweak。UI 里要明确提示这一点。
    func exportBlocklist() throws {
        var blockNumbers = Set<String>()
        var identifyMap: [String: String] = [:]

        for r in rules where r.enabled && r.type == .exact {
            let n = CGEngine.normalize(r.value)
            guard !n.isEmpty else { continue }

            switch r.action {
            case .block:
                blockNumbers.insert(n)
            case .mark:
                // 同一号码有多条 mark 规则时，保留标签更具体的那条
                if identifyMap[n] == nil || (identifyMap[n]?.count ?? 0) < r.label.count {
                    identifyMap[n] = r.label.isEmpty ? "疑似骚扰" : r.label
                }
            case .silence, .allow:
                break
            }
        }

        // 拦截优先：同时出现在两个集合里的号码从识别列表里剔除
        for n in blockNumbers {
            identifyMap.removeValue(forKey: n)
        }

        let blockText = blockNumbers.sorted().joined(separator: "\n")
        try blockText.write(to: SharedConfig.blocklistExportURL,
                            atomically: true, encoding: .utf8)

        let identifyText = identifyMap.keys.sorted()
            .map { "\($0)\t\(identifyMap[$0]!)" }
            .joined(separator: "\n")
        try identifyText.write(to: SharedConfig.identifyExportURL,
                               atomically: true, encoding: .utf8)
    }

    /// 导出 Tweak 配置到 /var/mobile/Library/CallGuard/tweak_rules.plist
    ///
    /// SpringBoard 进程读不到 App 沙盒，只能走这个固定路径。
    /// 需要 App 带 platform-application entitlement（TrollStore 会自动注入）。
    func exportTweakConfig() {
        guard SharedConfig.ensureTweakDirectory() else {
            lastReloadMessage = "无法写入共享目录，Tweak 拿不到规则"
            return
        }

        var ruleDicts: [[String: Any]] = []
        for r in rules where r.enabled {
            ruleDicts.append([
                "id":      Int(r.id),
                "type":    r.type.rawValue,
                "action":  r.action.rawValue,
                "value":   r.value,
                "label":   r.label,
                "enabled": true,
            ])
        }

        var whitelistExact: [String] = []
        var whitelistPrefix: [String] = []
        for w in whitelist {
            if w.isPrefix {
                whitelistPrefix.append(w.number)
            } else {
                whitelistExact.append(w.number)
            }
        }

        let dict: [String: Any] = [
            "enabled":         true,
            "version":         1,
            "rules":           ruleDicts,
            "whitelist":       whitelistExact,
            "whitelistPrefix": whitelistPrefix,
        ]

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0
            )
            try data.write(to: SharedConfig.tweakConfigURL, options: .atomic)
        } catch {
            lastReloadMessage = "Tweak 配置写入失败：\(error.localizedDescription)"
        }
    }

    /// 把 Tweak 写的 JSONL 日志导入数据库，然后清空文件
    func importTweakLogs() {
        let url = SharedConfig.tweakLogURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }

        var imported = 0
        for line in data.split(separator: 0x0A) {
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)),
                  let dict = obj as? [String: Any],
                  let number = dict["number"] as? String,
                  let actionRaw = dict["action"] as? Int,
                  let ts = dict["ts"] as? Double else {
                continue
            }

            let action = RuleAction(rawValue: actionRaw) ?? .mark
            let label = dict["label"] as? String ?? ""
            let ruleId = (dict["ruleId"] as? NSNumber)?.int64Value

            do {
                try Database.shared.insertLog(number: number, action: action,
                                              ruleId: ruleId, label: label,
                                              ts: Date(timeIntervalSince1970: ts))
                imported += 1
            } catch {
                continue
            }

            // 命中计数回流：这是规则自动升级的依据
            if let ruleId, action != .allow {
                try? Database.shared.bumpHitCount(id: ruleId)
            }
        }

        // 已导入的清掉，避免重复计数
        try? "".write(to: url, atomically: true, encoding: .utf8)

        if imported > 0 {
            refreshLogs()
        }
    }

    // MARK: - 规则自动升级

    /// 把「观察期满 + 命中达标」的 mark 规则升级成 block。
    ///
    /// 这是整个方案里唯一能让拦截率随时间上升的机制：
    /// 种子号段先只标记，跑够 7 天、命中 3 次以上，自动转成真拦截。
    /// 用户手动加过白名单的号码不受影响（白名单优先级本来就高于一切）。
    @discardableResult
    func promoteObservableRules(minHits: Int = 3, days: Int = 7) -> Int {
        let candidates = rules.filter { $0.promotable(minHits: minHits, days: days) }
        guard !candidates.isEmpty else { return 0 }

        do {
            try Database.shared.promoteRules(ids: candidates.map { $0.id })
            try refreshAll()
            rebuildEngine()
            syncExports()
            scheduleDirectoryReload()
            lastReloadMessage = "已升级 \(candidates.count) 条规则为拦截"
            return candidates.count
        } catch {
            errorMessage = error.localizedDescription
            return 0
        }
    }

    /// 当前有多少条规则够格升级（用于 UI 提示）
    func promotableCount(minHits: Int = 3, days: Int = 7) -> Int {
        rules.filter { $0.promotable(minHits: minHits, days: days) }.count
    }

    // MARK: - 批量导入

    struct ImportOutcome {
        var added = 0
        var duplicate = 0
        var invalid = 0
        var sample: [String] = []

        var summary: String {
            var parts: [String] = []
            if added > 0     { parts.append("新增 \(added)") }
            if duplicate > 0 { parts.append("重复 \(duplicate)") }
            if invalid > 0   { parts.append("无效 \(invalid)") }
            return parts.isEmpty ? "没有可导入的内容" : parts.joined(separator: "，")
        }
    }

    /// 批量导入号码。支持逗号、空格、分号、换行、中文标点分隔。
    @discardableResult
    func importNumbers(_ text: String,
                       action: RuleAction,
                       label: String,
                       type: RuleType = .exact) -> ImportOutcome {

        var outcome = ImportOutcome()

        let existing = Set(rules.filter { $0.type == type }.map { $0.value })
        var seen = Set<String>()

        let separators = CharacterSet(charactersIn: ",\n\r\t ;，、；|")
        let tokens = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for token in tokens {
            let normalized = CGEngine.normalize(token)
            // 归一化后至少 6 位，否则大概率是误粘贴的碎片
            guard !normalized.isEmpty, normalized.count >= 6 else {
                outcome.invalid += 1
                continue
            }

            if existing.contains(token) || seen.contains(normalized) {
                outcome.duplicate += 1
                continue
            }
            seen.insert(normalized)

            do {
                _ = try Database.shared.insertRule(type: type, value: token,
                                                   label: label, action: action,
                                                   source: "import")
                outcome.added += 1
                if outcome.sample.count < 5 { outcome.sample.append(token) }
            } catch {
                outcome.invalid += 1
            }
        }

        if outcome.added > 0 {
            do {
                try refreshAll()
                rebuildEngine()
                syncExports()
                scheduleDirectoryReload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        return outcome
    }

    // MARK: - 导出备份

    /// 把全部规则导出成 JSON，用于换机 / 备份
    func exportRulesJSON() -> Data? {
        let items: [[String: Any]] = rules.map { r in
            [
                "type":     r.type.rawValue,
                "value":    r.value,
                "label":    r.label,
                "action":   r.action.rawValue,
                "enabled":  r.enabled,
                "hitCount": r.hitCount,
                "createdAt": Int(r.createdAt.timeIntervalSince1970),
            ]
        }
        let doc: [String: Any] = [
            "version": 1,
            "exportedAt": Int(Date().timeIntervalSince1970),
            "rules": items,
            "whitelist": whitelist.map { ["number": $0.number, "isPrefix": $0.isPrefix, "note": $0.note] },
        ]
        return try? JSONSerialization.data(withJSONObject: doc,
                                           options: [.prettyPrinted, .sortedKeys])
    }

    /// 一次性同步所有导出产物：CallDirectory 列表 + Tweak 配置
    func syncExports() {
        do {
            try exportBlocklist()
        } catch {
            errorMessage = error.localizedDescription
        }
        exportTweakConfig()
    }

    func scheduleDirectoryReload() {
        CXCallDirectoryManager.sharedInstance.reloadExtension(
            withIdentifier: SharedConfig.directoryExtensionID
        ) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.lastReloadMessage = "刷新失败：\(error.localizedDescription)"
                } else {
                    self?.lastReloadMessage = "来电识别已刷新"
                }
            }
        }
    }

    /// 查询系统里 CallDirectory 的启用状态
    func directoryStatus(completion: @escaping (String) -> Void) {
        CXCallDirectoryManager.sharedInstance.getEnabledStatusForExtension(
            withIdentifier: SharedConfig.directoryExtensionID
        ) { status, error in
            if let error {
                completion("查询失败：\(error.localizedDescription)")
                return
            }
            switch status {
            case .enabled:            completion("已启用")
            case .disabled:           completion("未启用，请到 设置 → 电话 → 来电阻止与身份识别 打开")
            case .unknown:            completion("状态未知")
            @unknown default:         completion("状态未知")
            }
        }
    }
}

// MARK: - 种子数据解码

private struct SeedDocument: Decodable {
    struct SeedRule: Decodable {
        let id: Int
        let type: String
        let value: String
        let action: String
        let label: String
    }
    struct SeedWhitelist: Decodable {
        let id: Int
        let type: String
        let value: String
        let label: String
    }
    let rules: [SeedRule]
    let whitelist_templates: [SeedWhitelist]
}

private extension RuleType {
    init?(seedName: String) {
        switch seedName {
        case "exact":  self = .exact
        case "prefix": self = .prefix
        case "range":  self = .range
        case "regex":  self = .regex
        default:       return nil
        }
    }
}

private extension RuleAction {
    init?(seedName: String) {
        switch seedName {
        case "allow":   self = .allow
        case "mark":    self = .mark
        case "silence": self = .silence
        case "block":   self = .block
        default:        return nil
        }
    }
}
