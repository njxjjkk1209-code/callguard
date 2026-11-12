//
//  Database.swift
//  SQLite 数据访问层。
//
//  用 WAL 模式，因为主 App 会写、CallDirectory extension 会读，
//  两个进程并发访问同一个库，WAL 是唯一稳妥的选择。
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m):   return "数据库打开失败：\(m)"
        case .prepareFailed(let m): return "SQL 编译失败：\(m)"
        case .stepFailed(let m):   return "SQL 执行失败：\(m)"
        }
    }
}

final class Database {

    static let shared = Database()

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    private init() {}

    // MARK: - 生命周期

    func openIfNeeded() throws {
        lock.lock(); defer { lock.unlock() }
        guard db == nil else { return }

        let path = SharedConfig.databaseURL.path
        var handle: OpaquePointer?

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw DBError.openFailed(msg)
        }

        db = h
        sqlite3_busy_timeout(h, 3000)

        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA foreign_keys=ON;")

        try migrate()
    }

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS rules (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            type        INTEGER NOT NULL,
            value       TEXT    NOT NULL,
            label       TEXT    NOT NULL DEFAULT '',
            action      INTEGER NOT NULL DEFAULT 1,
            enabled     INTEGER NOT NULL DEFAULT 1,
            source      TEXT    NOT NULL DEFAULT 'user',
            hit_count   INTEGER NOT NULL DEFAULT 0,
            created_at  INTEGER NOT NULL
        );
        """)

        try exec("""
        CREATE TABLE IF NOT EXISTS whitelist (
            number      TEXT PRIMARY KEY,
            is_prefix   INTEGER NOT NULL DEFAULT 0,
            note        TEXT NOT NULL DEFAULT ''
        );
        """)

        try exec("""
        CREATE TABLE IF NOT EXISTS call_log (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            number      TEXT    NOT NULL,
            action      INTEGER NOT NULL,
            rule_id     INTEGER,
            label       TEXT NOT NULL DEFAULT '',
            ts          INTEGER NOT NULL
        );
        """)

        try exec("CREATE INDEX IF NOT EXISTS idx_rules_type ON rules(type);")
        try exec("CREATE INDEX IF NOT EXISTS idx_log_ts ON call_log(ts DESC);")

        // 兼容旧库：列已存在时 ALTER 会报错，忽略即可
        try? exec("ALTER TABLE rules ADD COLUMN last_hit_at INTEGER NOT NULL DEFAULT 0;")
    }

    // MARK: - 低层执行

    @discardableResult
    func exec(_ sql: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw DBError.stepFailed("db 未打开") }

        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.stepFailed(msg)
        }
        return true
    }

    private func prepare(_ sql: String, _ binds: [Any?]) throws -> OpaquePointer {
        guard let db else { throw DBError.stepFailed("db 未打开") }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        for (i, value) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let v as Int:
                sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Int64:
                sqlite3_bind_int64(s, idx, v)
            case let v as Bool:
                sqlite3_bind_int(s, idx, v ? 1 : 0)
            case let v as String:
                // Swift String 不能直接传给 UnsafePointer<CChar>，必须走 withCString
                v.withCString { ptr in
                    sqlite3_bind_text(s, idx, ptr, -1, SQLITE_TRANSIENT)
                }
            case .none:
                sqlite3_bind_null(s, idx)
            default:
                let str = "\(value!)"
                str.withCString { ptr in
                    sqlite3_bind_text(s, idx, ptr, -1, SQLITE_TRANSIENT)
                }
            }
        }
        return s
    }

    /// 安全读取 TEXT 列（sqlite3_column_text 返回 UInt8 指针，不能直接喂 String(cString:)）
    private func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }

    @discardableResult
    func run(_ sql: String, _ binds: [Any?] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw DBError.stepFailed("db 未打开") }

        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - 规则

    func fetchRules() throws -> [Rule] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw DBError.stepFailed("db 未打开") }

        let sql = """
        SELECT id, type, value, label, action, enabled, hit_count, created_at, last_hit_at
        FROM rules ORDER BY id DESC;
        """
        let stmt = try prepare(sql, [])
        defer { sqlite3_finalize(stmt) }

        var out: [Rule] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let lastHit = sqlite3_column_int64(stmt, 8)
            out.append(Rule(
                id:       sqlite3_column_int64(stmt, 0),
                type:     RuleType(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .exact,
                value:    columnText(stmt, 2),
                label:    columnText(stmt, 3),
                action:   RuleAction(rawValue: Int(sqlite3_column_int(stmt, 4))) ?? .mark,
                enabled:  sqlite3_column_int(stmt, 5) != 0,
                hitCount: Int(sqlite3_column_int(stmt, 6)),
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7))),
                lastHitAt: lastHit > 0
                    ? Date(timeIntervalSince1970: TimeInterval(lastHit))
                    : nil
            ))
        }
        return out
    }

    func insertRule(type: RuleType, value: String, label: String,
                    action: RuleAction, source: String = "user") throws -> Int64 {
        try run("""
        INSERT INTO rules (type, value, label, action, enabled, source, created_at)
        VALUES (?, ?, ?, ?, 1, ?, ?);
        """, [type.rawValue, value, label, action.rawValue, source, Int(Date().timeIntervalSince1970)])
    }

    func updateRuleAction(id: Int64, action: RuleAction) throws {
        try run("UPDATE rules SET action = ? WHERE id = ?;", [action.rawValue, id])
    }

    func setRuleEnabled(id: Int64, enabled: Bool) throws {
        try run("UPDATE rules SET enabled = ? WHERE id = ?;", [enabled, id])
    }

    func deleteRule(id: Int64) throws {
        try run("DELETE FROM rules WHERE id = ?;", [id])
    }

    func bumpHitCount(id: Int64) throws {
        try run("""
        UPDATE rules SET hit_count = hit_count + 1, last_hit_at = ? WHERE id = ?;
        """, [Int(Date().timeIntervalSince1970), id])
    }

    /// 批量升级：把满足条件的 mark 规则改成 block
    func promoteRules(ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "UPDATE rules SET action = ? WHERE id IN (\(placeholders)) AND action = ?;"
        var binds: [Any?] = [RuleAction.block.rawValue]
        binds.append(contentsOf: ids.map { Optional($0) })
        binds.append(RuleAction.mark.rawValue)

        try run(sql, binds)
        return ids.count
    }

    // MARK: - 白名单

    func fetchWhitelist() throws -> [WhitelistEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw DBError.stepFailed("db 未打开") }

        let stmt = try prepare("SELECT number, is_prefix, note FROM whitelist ORDER BY number;", [])
        defer { sqlite3_finalize(stmt) }

        var out: [WhitelistEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(WhitelistEntry(
                number:   columnText(stmt, 0),
                isPrefix: sqlite3_column_int(stmt, 1) != 0,
                note:     columnText(stmt, 2)
            ))
        }
        return out
    }

    func addWhitelist(number: String, isPrefix: Bool, note: String = "") throws {
        try run("""
        INSERT OR REPLACE INTO whitelist (number, is_prefix, note) VALUES (?, ?, ?);
        """, [number, isPrefix, note])
    }

    func removeWhitelist(number: String) throws {
        try run("DELETE FROM whitelist WHERE number = ?;", [number])
    }

    // MARK: - 日志

    func insertLog(number: String, action: RuleAction, ruleId: Int64?,
                   label: String, ts: Date = Date()) throws {
        try run("""
        INSERT INTO call_log (number, action, rule_id, label, ts) VALUES (?, ?, ?, ?, ?);
        """, [number, action.rawValue, ruleId, label, Int(ts.timeIntervalSince1970)])
    }

    func fetchLogs(limit: Int = 200) throws -> [CallLogEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw DBError.stepFailed("db 未打开") }

        let stmt = try prepare("""
        SELECT id, number, action, rule_id, label, ts
        FROM call_log ORDER BY ts DESC LIMIT ?;
        """, [limit])
        defer { sqlite3_finalize(stmt) }

        var out: [CallLogEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(CallLogEntry(
                id:     sqlite3_column_int64(stmt, 0),
                number: columnText(stmt, 1),
                action: RuleAction(rawValue: Int(sqlite3_column_int(stmt, 2))) ?? .mark,
                ruleId: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3),
                label:  columnText(stmt, 4),
                ts:     Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5)))
            ))
        }
        return out
    }

    func clearLogs() throws {
        try exec("DELETE FROM call_log;")
    }

    /// 今日拦截数
    func todayBlockedCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw DBError.stepFailed("db 未打开") }

        let start = Calendar.current.startOfDay(for: Date())
        let stmt = try prepare("""
        SELECT COUNT(*) FROM call_log WHERE ts >= ? AND action >= 2;
        """, [Int(start.timeIntervalSince1970)])
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// 累计拦截数
    func totalBlockedCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw DBError.stepFailed("db 未打开") }

        let stmt = try prepare("SELECT COUNT(*) FROM call_log WHERE action >= 2;", [])
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }
}
