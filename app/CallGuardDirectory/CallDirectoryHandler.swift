//
//  CallDirectoryHandler.swift
//  CallDirectory 兜底层。
//
//  两条通道：
//    1. blocklist.txt   → addBlockingEntry      直接拦截（action == block）
//    2. identify.txt    → addIdentificationEntry 来电显示标签（action == mark）
//
//  硬约束（踩过就知道）：
//    · 号码必须是 E.164 无 '+' 的整数形式
//    · 每个列表必须严格升序，重复会整批失败
//    · extension 内存约 40-50MB，超过会被 jetsam 杀掉
//    · 不支持前缀匹配，号段规则到不了这里
//

import CallKit
import Foundation

final class CallDirectoryHandler: CXCallDirectoryProvider {

    override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        context.delegate = self

        do {
            try addBlockingEntries(to: context)
            try addIdentificationEntries(to: context)
            context.completeRequest()
        } catch {
            context.cancelRequest(withError: error)
        }
    }

    // MARK: - 拦截列表

    private func addBlockingEntries(to context: CXCallDirectoryExtensionContext) throws {
        let url = SharedConfig.blocklistExportURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        try streamLines(from: url) { number, _ in
            context.addBlockingEntry(withNextSequentialPhoneNumber: number)
        }
    }

    // MARK: - 识别标签

    private func addIdentificationEntries(to context: CXCallDirectoryExtensionContext) throws {
        let url = SharedConfig.identifyExportURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        try streamLines(from: url) { number, label in
            context.addIdentificationEntry(
                withNextSequentialPhoneNumber: number,
                label: label.isEmpty ? "疑似骚扰" : label
            )
        }
    }

    // MARK: - 流式解析
    //
    // 逐块读取，避免一次性把整个文件读进内存。
    // 同时在这里保证「严格升序」：只接受比上一条更大的号码，
    // 重复和乱序会被静默跳过，防止整批加载失败。

    private func streamLines(
        from url: URL,
        _ handler: (CXCallDirectoryPhoneNumber, String) -> Void
    ) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        var buffer = Data()
        var lastNumber: CXCallDirectoryPhoneNumber = 0

        func consume(_ line: Data) {
            guard let (number, label) = parse(line) else { return }
            guard number > lastNumber else { return }   // 升序 + 去重
            lastNumber = number
            handler(number, label)
        }

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                consume(Data(line))
            }
        }

        if !buffer.isEmpty {
            consume(buffer)
        }
    }

    private func parse(_ line: Data) -> (CXCallDirectoryPhoneNumber, String)? {
        guard !line.isEmpty else { return nil }

        let parts = line.split(separator: 0x09, maxSplits: 1, omittingEmptySubsequences: false)
        guard let numberPart = parts.first,
              let number = Int64(String(decoding: numberPart, as: UTF8.self)),
              number > 0 else {
            return nil
        }

        let label = parts.count > 1
            ? String(decoding: parts[1], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            : ""

        return (number, label)
    }
}

// MARK: - CXCallDirectoryExtensionContextDelegate

extension CallDirectoryHandler: CXCallDirectoryExtensionContextDelegate {

    func requestFailed(for extensionContext: CXCallDirectoryExtensionContext,
                       withError error: Error) {
        // 系统侧失败，记录到统一日志，便于用 Console.app 排查
        NSLog("[CallGuard] CallDirectory request failed: %@", error.localizedDescription)
    }
}
