//
//  Rule.swift
//  数据模型。
//

import Foundation

enum RuleType: Int, CaseIterable, Identifiable, Codable {
    case exact  = 0
    case prefix = 1
    case range  = 2
    case regex  = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .exact:  return "精确号码"
        case .prefix: return "号段前缀"
        case .range:  return "号码区间"
        case .regex:  return "正则模式"
        }
    }

    var hint: String {
        switch self {
        case .exact:  return "13800138000"
        case .prefix: return "170 / 95 / 400"
        case .range:  return "13100000000-13100000999"
        case .regex:  return #"86(170|171)\d{8}"#
        }
    }
}

enum RuleAction: Int, CaseIterable, Identifiable, Codable {
    case allow   = 0
    case mark    = 1
    case silence = 2
    case block   = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .allow:   return "放行"
        case .mark:    return "仅标记"
        case .silence: return "静音"
        case .block:   return "拦截"
        }
    }

    /// 是否算作"拦截"（用于统计）
    var isBlocking: Bool { self == .silence || self == .block }
}

struct Rule: Identifiable, Hashable {
    var id: Int64
    var type: RuleType
    var value: String
    var label: String
    var action: RuleAction
    var enabled: Bool
    var hitCount: Int
    var createdAt: Date
    var lastHitAt: Date?

    /// 观察期是否已满（默认 7 天）
    func observed(days: Int = 7, now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) >= Double(days) * 86_400
    }

    /// 是否够格从「仅标记」升级成「拦截」
    func promotable(minHits: Int = 3, days: Int = 7, now: Date = Date()) -> Bool {
        enabled && action == .mark && hitCount >= minHits && observed(days: days, now: now)
    }
}

struct WhitelistEntry: Identifiable, Hashable {
    var id: String { number }
    var number: String
    var isPrefix: Bool
    var note: String
}

struct CallLogEntry: Identifiable, Hashable {
    var id: Int64
    var number: String
    var action: RuleAction
    var ruleId: Int64?
    var label: String
    var ts: Date
}
