# HANDOFF — 给 L（国际版 WorkBuddy）

> 留言人：小布（K 的 Windows 侧 WorkBuddy）
> 时间：2026-11-12 21:xx
> 详细复核：同目录 `复核报告_小布_2026-11-12.md`（含二进制证据与代码行号）

## 一句话

方案骨架和真机链路是对的，**但桌面上那两个包是第一版**，而且**观察期内 L2 是空转的**——用户 11-19 打开 App 会误判"标签没出来 = 坏了"。请按下面 3 条 P0 处理。

## P0（必须改，影响用户当前这一周）

1. **重出包**。桌面 `CallGuard.tipa` / `CallGuardTweak.deb` 是第一版（二进制里 `tweak_ready`、`MCMMetadataIdentifier`、`cg_probe` 全是 0 次命中），重装会把已修好的共享通道打回"未导出"。用最新 CI artifact 覆盖，文件名带 commit + 日期；`Info.plist` 和 `tweak_ready.json` 里都加 commit 字段。

2. **L2 观察期空转**。8 条种子规则全是 `prefix`，而 `exportBlocklist()` 只导 `exact` → `blocklist.txt` / `identify.txt` 都是 0 字节 → **这一周来电不会有任何标签**。但 `观察期与升级指南.md` 表格写的是"来电界面 显示标签"。两件事都要做：
   - 补 3 条 `exact` 种子（action=`mark`），让 L2 链路可观测；
   - 设置页加一行 `CallDirectory 条目数：拦截 N / 识别 M`（读两个导出文件行数），并改掉指南里那句标签承诺。

3. **静音会永久毁铃声**。`CGSilenceRing()` 把 `Ringtone` 音量写 0 后不恢复，用户一旦用 `silence` 动作，之后所有来电都不响。要么加 `getVolume:forCategory:` 存档 + 通话结束恢复（监听 `TUCallCenterCallStatusChangedNotification`，判 `!incomingCall && !currentCall`），要么这一版先把 `silence` 从 UI 藏掉。

## P1（同批改，成本很低）

4. `%hook SBIncomingCallAlertItem` 大概率挂不上（该类没有 `-initWithCall:`），而 Logos 在"类存在 / 方法不存在"时**静默失效**。在 `%ctor` 里用 `class_getInstanceMethod` 自检，把 `hooked` 计数写进 `tweak_ready.json`，概览页显示「挂载 N/M hook」。

5. `identify.txt` 的 label 直接拼 `\t`，用户标签里带 tab/换行会串行错位。导出时把 `\t \n \r` 替换成空格。

6. `importTweakLogs()` 的 `"".write(atomically:true)` 改成 `FileHandle.truncate(atOffset: 0)`，避免 rename 期间丢日志；顺手加个 512KB 轮转上限。

## P2

- 区间匹配 `upper_bound` 只回退一个区间，重叠规则会漏命中 → `addRule` 层做重叠检测。
- `HomeView` 的 L2 状态 `"点击查询"` 改 `onAppear` 自动查。
- 心跳加一次 2 秒后重写，规避 SpringBoard 早期 App Group 未挂载的竞态。
- `exportTweakConfig` 改成"主通道失败继续试备通道"。

## 复核过、不用动的部分

规则引擎 38/38、配置一致性 6/6、升级阈值 17/17 本地实跑全过；枚举三处对齐；entitlements 双侧 App Group 一致；appex 的流式 + 升序去重实现是对的；dylib arm64+arm64e fat、rootless 路径正确。

---

改完之后请在 `复核报告_小布_2026-11-12.md` 末尾追加一段「处理结果」，写清楚哪条改了、哪条决定不改及原因。K 会在两边对账。
