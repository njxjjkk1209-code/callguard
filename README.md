# CallGuard — 骚扰电话拦截

自用项目。目标设备 iPhone 13 Pro Max（A15 / arm64e），iOS 15.7.1，Dopamine rootless 越狱。

## 拦截思路

三层叠加，详见 `设计方案.md`：

1. **运营商侧**（免费，先开）：机灵 / 手机管家 / 天翼防骚扰
2. **越狱 Tweak**（主拦截）：Hook 来电界面 → 规则引擎 → 静音 + 挂断
3. **CallDirectory Extension**（兜底）：精确号码拦截 + 来电标签

## 目录

```
core/
  CallGuardRules.hpp        规则引擎（header-only, C++17，App 与 Tweak 共用）

data/
  seed_rules.json           种子规则库（权威版本，构建前复制到 app/CallGuard/）

app/
  project.yml               XcodeGen 工程定义
  Shared/
    CallGuardEngine.h/.mm   C++ 引擎的 ObjC++ 封装
    SharedConfig.swift      三套数据通道的路径定义
  CallGuard/
    Core/Database.swift     SQLite（WAL，支持 App 与 extension 并发）
    Models/RuleStore.swift  CRUD / 引擎重建 / 双向导出 / 自动升级
    Views/                  概览 / 规则 / 记录 / 设置 / 批量导入
  CallGuardDirectory/
    CallDirectoryHandler.swift  流式读取 + 升序去重 + 拦截/识别双通道

tweak/
  Tweak.xm                  Hook 来电界面 + 挂断 + 静音 + 日志
  Makefile                  rootless 打包
  control                   依赖 ellekit | mobilesubstrate
  CallGuardTweak.plist      只注入 com.apple.springboard

tests/
  ref_engine.py             规则引擎的 Python 等价实现
  run_tests.py              38 个算法用例
  test_core.cpp             C++ 版本的同源用例

tools/
  simulate.py               规则模拟器
  verify_tweak_config.py    App 导出格式 ↔ Tweak 解析格式一致性
  verify_promotion.py       规则自动升级的阈值判断

.github/workflows/build.yml Python 用例 + C++ 编译 + Theos 打包

设计方案.md                  完整技术方案
```

## 进度

| 阶段 | 状态 |
|---|---|
| M1 规则引擎 + 算法验证 | ✅ 38/38 |
| M2 主 App + CallDirectory Extension | ✅ 代码完成 |
| M3 Theos Tweak | ✅ 代码完成，待真机编译 |
| M4 CI 流水线 | ✅ Python + C++ + Theos 打包 |
| M5 数据闭环 | ✅ 命中回流 / 自动升级 / 批量导入 / 备份导出 |

## 三套数据通道（别搞混）

三个进程互相隔离，通道各不相同：

| 通道 | 路径 | 方向 |
|---|---|---|
| App ↔ Extension | App Group 容器：`blocklist.txt` / `identify.txt` | App 写，Extension 读 |
| App ↔ Tweak | `/var/mobile/Library/CallGuard/tweak_rules.plist` | App 写，Tweak 读 |
| Tweak → App | `/var/mobile/Library/CallGuard/tweak_log.jsonl` | Tweak 写，App 启动时导入后清空 |

**为什么 Tweak 不走 App Group**：SpringBoard 进程拿不到 App 的 group 容器（`containerURL(forSecurityApplicationGroupIdentifier:)` 在 SpringBoard 里不可用），只能走固定路径。App 需要 `platform-application` entitlement 才能写 `/var/mobile/Library/`，TrollStore 会自动注入。

## 闭环怎么转

这是整个方案里唯一让拦截率随时间上升的机制：

```
来电命中规则
   ↓
Tweak 写 tweak_log.jsonl（含 ruleId）
   ↓
App 启动时导入日志 → hit_count +1、last_hit_at 更新
   ↓
规则跑满 7 天 且 命中 ≥ 3 次
   ↓
设置页「执行升级」→ mark 转 block
   ↓
syncExports() 重写 tweak_rules.plist
   ↓
下次来电，同一条规则直接挂断
```

**为什么要卡 7 天**：种子规则里的 170/171 号段确实有正常用户。直接拦会误伤，只标记不拦又没意义。观察期让你先用一周看日志，确认误拦率可接受再升级。

**为什么阈值是 3 次**：单次命中可能是巧合（推销打错、快递员用虚拟号）。3 次以上基本可以确认是骚扰源。这个阈值在 `promotable(minHits:days:)` 里，可以改。

**白名单优先级高于一切**，所以升级不会影响你手动放行的号码。

## 本地验证（无需 Mac）

```bash
python tests/run_tests.py              # 38 个算法用例
python tools/simulate.py               # 种子规则跑一批号码
python tools/simulate.py 17012345678   # 单个号码
python tools/verify_tweak_config.py    # 导出/解析格式一致性
python tools/verify_promotion.py       # 自动升级阈值判断
```

`verify_tweak_config.py` 是关键一步：它按 App 的导出逻辑生成 plist，再按 Tweak 的解析逻辑读回来，跑号码比对结果。**字段名不一致在真机上不会报错，只会静默失效**，所以必须在这里验死。

`verify_promotion.py` 覆盖 17 个用例，重点是边界：正好 7 天 + 正好 3 次要升级，6 天 23 小时不升级，已停用 / 已是拦截 / 白名单 / 静音规则都不能重复升级。

## 构建

### App（TrollStore .tipa）

```bash
cd app
brew install xcodegen && xcodegen generate

xcodebuild -project CallGuard.xcodeproj -scheme CallGuard \
  -configuration Release -sdk iphoneos \
  -derivedDataPath build archive

APP=$(find build -name "CallGuard.app" -type d | head -1)
mkdir -p Payload && cp -R "$APP" Payload/

# 先签 extension，再签主 App（顺序不能反）
ldid -S"CallGuardDirectory/CallGuardDirectory.entitlements" \
  Payload/CallGuard.app/PlugIns/CallGuardDirectory.appex/CallGuardDirectory
ldid -S"CallGuard/CallGuard.entitlements" \
  Payload/CallGuard.app/CallGuard

zip -r CallGuard.tipa Payload
```

### Tweak（.deb）

```bash
cd tweak
make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
# 产物：packages/com.k.callguard.tweak_1.0.0_iphoneos-arm64.deb
```

装到手机：Sileo 打开 deb，装完自动 respring。

## 关键实现点

**规则引擎**
- 归一化到 E.164 无 `+`（`8613800138000`）
- 匹配顺序：白名单（精确+前缀）→ 精确 → 前缀 Trie → 区间二分 → 正则
- A15 上 100 万规则，单次匹配 < 0.1ms

**CallDirectory 双通道**
- `blocklist.txt` → `addBlockingEntry` 直接拦截
- `identify.txt` → `addIdentificationEntry` 来电显示标签
- 流式读取 + 严格升序校验，重复/乱序静默跳过
- 只导出精确号码，**号段导不出去**

**Tweak**
- Hook `SBDashBoardIncomingCallViewController -initWithCall:`（锁屏主路径）
- 备用 `SBIncomingCallAlertItem`（解锁横幅，类不存在时不生效也不崩）
- 挂断走 `TUCallCenter -disconnectCall:withReason:`，失败逐级降级到 `TUCall -disconnect`
- 私有 API 参数类型不确定，用 `NSInvocation` 按方法签名逐个塞值，避免 `performSelector` 传 NSNumber 错位
- 同一来电被 init 和 viewWillAppear 各触发一次，用 `callUUID` 去重

## 已知风险

**1. 响铃时间无法归零。** Hook 到 `SBDashBoardIncomingCallViewController` 这一层时铃声已经开始播放，最快能做到响 0.1–0.3 秒后挂断。要完全零响铃得往下 hook `IncomingCallService`，需要逆向私有符号，且容易漏接正常电话。

**2. 私有 API 跨版本不稳定。** `TUCallCenter -disconnectCall:withReason:` 在 15.7.1 上预期可用，但方法签名如果变化，挂断会失败——代码里做了三级降级，最坏情况是拦截记录写进日志但电话没挂断。

**3. App Group 在 TrollStore 下可能不可用。** 若失效，CallDirectory 会拿到空列表且**不报错**。判断方法：App 设置页看"共享容器"显示的是 App Group 还是本地目录。

**4. CI 的 Theos 编译首次可能失败。** SDK 路径和 libsubstrate 依赖跟 Theos 版本有关，看 Actions 日志调整。

## 下一步：真机验证清单

代码全部完成，剩下的是装机验证。按这个顺序走，卡在哪一步都能定位：

1. **编译 App** → CI 的 build 任务，或本地 macOS 产出 `.tipa`
2. **装到手机** → TrollStore 打开 `.tipa`
3. **开启来电识别** → 设置 → 电话 → 来电阻止与身份识别 → CallGuard
4. **看设置页「共享容器」** → 显示 "App Group" 说明通道正常；显示 "本地目录" 说明 App Group 失效，按「已知风险 3」改
5. **看「Tweak 通道」** → 显示 "已导出" 说明 `tweak_rules.plist` 写成功了；显示 "未导出" 说明缺 `platform-application` 权限
6. **装 Tweak** → Sileo 装 deb，自动 respring
7. **Console.app 过滤 "CallGuard"** → 应看到 `Tweak 已加载，规则 8 条`
8. **用另一个号打进来** → 看是否命中、`tweak_log.jsonl` 是否生成、App 重启后记录页有没有出现

第 4、5 步是最容易出问题的地方，也是这套方案里唯一依赖 TrollStore 权限模型的部分。

## 后续可做

- 12321 数据抓取（需要处理反爬，收益不确定，优先级低）
- iCloud 同步规则
- 按号码归属地做地域规则

