# MacLidAwake 重构实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 使用 `executing-plans` 逐任务实现；本轮按用户要求禁止子 Agent 和 worktree。所有步骤使用 checkbox 跟踪。

**Goal:** 在现有 keepawake 仓库中交付安全优先、极简、可持久计时的 MacLidAwake CLI `lidgo`。

**Architecture:** 使用 Swift Package 将纯 Lease 状态机与 macOS 系统适配器分离。CLI 只提交原子状态事务，常驻 LaunchAgent 监督 Timer、Hold 进程和安全条件，并通过保留的精确 sudoers 与全局 flock 协调 `pmset`。

**Tech Stack:** Swift 6、Swift Package Manager、Foundation、Darwin/libproc、IOKit、AppKit/NSWorkspace、launchd、零依赖 Swift 可执行测试 harness、Bash。

**Spec:** `docs/product-spec.md`

## Global Constraints

- 产品名固定为 `MacLidAwake`，公开命令固定为 `lidgo`。
- 默认时长固定为 60 分钟，Battery cutoff 固定默认为 15%，Thermal safety 固定启用并在 critical 触发。
- sudoers 只允许 `/usr/bin/pmset -a disablesleep 1` 和 `/usr/bin/pmset -a disablesleep 0`。
- 不保存密码、不使用 Keychain、不向 sudo stdin 输入密码；非 setup 特权调用只使用 `sudo -n`。
- Timer 必须独立于终端，由 `com.maclidawake.lidgo.agent` LaunchAgent 监督。
- Hold 清理信号固定包含 SIGINT、SIGTERM、SIGHUP、SIGQUIT；停止/恢复固定包含 SIGTSTP、SIGSTOP、SIGCONT。
- Battery/Thermal 熔断后必须保持 OFF，禁止自动重建 Lease。
- 保留 MIT License 与 `ecc521/keepawake` attribution。
- 不创建 worktree、不使用子 Agent；每阶段在当前工作区测试、审查并提交。

---

### Task 1: Swift Package、模型与原子状态机

**Files:**
- Create: `Package.swift`
- Create: `Sources/LidGoCore/Models.swift`
- Create: `Sources/LidGoCore/Paths.swift`
- Create: `Sources/LidGoCore/DurationParser.swift`
- Create: `Sources/LidGoCore/StateStore.swift`
- Create: `Sources/LidGoCore/LeaseCoordinator.swift`
- Create: `tests/LidGoCoreTests/DurationParserTests.swift`
- Create: `tests/LidGoCoreTests/LeaseCoordinatorTests.swift`
- Create: `tests/LidGoCoreTests/StateStoreTests.swift`
- Modify: `CLAUDE.md`

**Interfaces:**
- Produces: `LidGoConfig`, `TimerLease`, `HoldLease`, `RuntimeState`, `SafetyStop`, `ProcessSnapshot`。
- Produces: `DurationParser.parse(_:) -> Int?`。
- Produces: `StateStore.withLock<T>(_ body: (inout RuntimeState, inout LidGoConfig) throws -> T) throws -> T`。
- Produces: `LeaseCoordinator` 的 create/show/refresh/addHold/removeHold/forceToggle/reconcile/tripSafety 纯规则。

- [x] **Step 1: 写 duration 与配置失败测试**

```swift
XCTAssertEqual(DurationParser.parse("90m"), 5_400)
XCTAssertEqual(DurationParser.parse("2h"), 7_200)
XCTAssertEqual(DurationParser.parse("1h30m"), 5_400)
XCTAssertNil(DurationParser.parse("0m"))
XCTAssertNil(DurationParser.parse("1h-5m"))
XCTAssertThrowsError(try LidGoConfig(defaultDurationSeconds: 3600, batteryCutoffPercent: 0).validated())
```

- [x] **Step 2: 运行定向测试并确认因类型不存在而失败**

Run: `swift run LidGoCoreTests`

Expected: 编译失败，报告 `DurationParser`/`LidGoConfig` 未定义。

- [x] **Step 3: 实现模型、路径和 duration parser**

```swift
public struct RuntimeState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var generation: UInt64 = 0
    public var timer: TimerLease?
    public var holds: [HoldLease] = []
    public var lastSafetyStop: SafetyStop?
}
```

生产路径固定为 `~/Library/Application Support/MacLidAwake`；只有 `LIDGO_TESTING=1` 时允许 `LIDGO_HOME` 覆盖，防止普通运行被环境变量重定向到不可信路径。

- [x] **Step 4: 写 Lease 规则失败测试**

测试必须逐项断言：默认 OFF 创建 Timer、重复默认不刷新、纯 Timer refresh、Hold 存在时 refresh 无状态变化、Timer+Hold、两个 Hold 独立释放、Timer 到期保留 Hold、force 清空并递增 generation、安全熔断清空且条件恢复不重建、dead/stopped/zombie/PID reuse 清理。

- [x] **Step 5: 运行定向测试并确认失败**

Run: `swift run LidGoCoreTests`

Expected: 编译失败或断言失败，因为 `LeaseCoordinator` 尚未实现。

- [x] **Step 6: 实现纯 LeaseCoordinator**

```swift
public mutating func forceToggle(now: Date, config: LidGoConfig) -> ToggleResult {
    reconcile(now: now)
    if state.timer != nil || !state.holds.isEmpty {
        state.timer = nil
        state.holds.removeAll()
        state.generation &+= 1
        return .turnedOff
    }
    state.timer = TimerLease(now: now, duration: config.defaultDurationSeconds,
                             generation: state.generation)
    state.lastSafetyStop = nil
    return .turnedOn(state.timer!)
}
```

所有方法返回用于 CLI 输出的不可变 result，调用方不在解锁后重新推导结果。

- [x] **Step 7: 写 StateStore 并发/损坏失败测试**

并发 50 次事务递增 generation，最终必须恰为 50；写入后 config/state 文件模式为 0600；损坏 JSON 必须按空 runtime fail-safe 返回诊断错误，不能保留伪 Lease。

- [x] **Step 8: 实现 flock 与原子 JSON StateStore**

同目录临时文件写入后执行 `synchronizeFile()`、`chmod(0600)`、`rename()`；锁文件打开时使用 `O_NOFOLLOW|O_CREAT`，父目录创建为 0700。

- [x] **Step 9: 运行 Task 1 全部测试**

Run: `swift run LidGoCoreTests`

Expected: 0 failures。

- [x] **Step 10: 审查并提交 Task 1**

Run: `git diff --check`

Commit: `feat: add lease state core`

---

### Task 2: macOS 监督器、pmset 与安全熔断

**Files:**
- Create: `Sources/LidGoCore/ProcessInspector.swift`
- Create: `Sources/LidGoCore/PowerController.swift`
- Create: `Sources/LidGoCore/SafetyMonitor.swift`
- Create: `Sources/LidGoCore/AgentRuntime.swift`
- Create: `tests/LidGoCoreTests/ProcessInspectorTests.swift`
- Create: `tests/LidGoCoreTests/PowerControllerTests.swift`
- Create: `tests/LidGoCoreTests/AgentRuntimeTests.swift`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: Task 1 models、`StateStore`、`LeaseCoordinator`。
- Produces: `ProcessInspecting.snapshot(pid:) -> ProcessSnapshot?`，真实实现基于 `proc_pidinfo`。
- Produces: `PowerControlling.setAwake(_:)`，真实实现只生成两条固定 pmset argv。
- Produces: `SafetyReading.snapshot() -> SafetySnapshot`。
- Produces: `AgentRuntime.tick()` 与 `AgentRuntime.run()`。

- [x] **Step 1: 写进程身份与状态失败测试**

使用当前测试进程断言 snapshot 存在、start identity 非零、状态可运行；使用完成的子进程断言 dead；通过 fake snapshot 断言 stopped/zombie 和 start identity 不符均被 coordinator 清除。

- [x] **Step 2: 实现 ProcessInspector**

```swift
let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                        Int32(MemoryLayout<proc_bsdinfo>.size))
```

将 `pbi_start_tvsec` 与 `pbi_start_tvusec` 组合为稳定 `UInt64`；`SRUN`/`SSLEEP` 有效，`SSTOP`/`SZOMB` 无效，未知或读取失败按无效处理。

- [x] **Step 3: 写 PowerController 失败测试**

fake runner 必须只收到：

```swift
["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]
["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]
```

测试多次相同目标不重复调用、多个监督器共享锁时其中一个释放不执行 0、最后一个释放才执行 0、缺失/符号链接全局锁拒绝运行。

- [x] **Step 4: 实现 PowerController**

只允许 root setup 创建 `0660 root:admin` 的 `/var/db/maclidawake.lock`；监督器 `open(O_RDWR|O_NOFOLLOW)`。awake 时取得共享锁后 `pmset 1`；sleep 时释放共享锁并在取得排他锁后 `pmset 0`。

- [x] **Step 5: 写 AgentRuntime 失败测试**

测试 Timer 到期、Timer 到期仍有 Hold、SIGSTOP 模拟、PID reuse、Battery 等于阈值、Thermal critical、熔断后电量/温度恢复不自动开启、空 Lease 启动执行 fail-safe 0、损坏 state 执行 fail-safe 0、wake 重新 reconcile。

- [x] **Step 6: 实现 SafetyMonitor 与 AgentRuntime**

Agent 每 1 秒 tick，并由 IOPS、thermal 与 wake 通知提前触发。每次 tick 在状态锁内清理/熔断，解锁后根据 `hasValidLeases` 调用 PowerController；所有回调汇入同一串行队列。

- [x] **Step 7: 运行 Task 2 全部测试**

Run: `swift run LidGoCoreTests`

Expected: 全部 0 failures。

- [x] **Step 8: 审查并提交 Task 2**

Run: `git diff --check`

Commit: `feat: add launch agent runtime and safety cutoffs`

---

### Task 3: CLI、Hold 信号与幂等 setup

**Files:**
- Create: `Sources/LidGoCore/Command.swift`
- Create: `Sources/LidGoCore/StatusFormatter.swift`
- Create: `Sources/LidGoCore/HoldSession.swift`
- Create: `Sources/LidGoCore/SetupManager.swift`
- Create: `Sources/lidgo/main.swift`
- Modify: `Package.swift`
- Create: `tests/LidGoCoreTests/CommandTests.swift`
- Create: `tests/LidGoCoreTests/SetupManagerTests.swift`
- Create: `tests/run_tests.sh`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: Task 1/2 全部核心接口。
- Produces: `Command.parse(_:)`，仅产生公开契约命令或隐藏 `__agent`/`__root-setup`。
- Produces: `HoldSession.run()`。
- Produces: `SetupManager.setup()`、`SetupManager.rootSetup()`、`SetupManager.selfCheck()`。

- [ ] **Step 1: 写 CLI parser 失败测试**

覆盖所有合法形态及等价别名；断言 `lidgo switch` 返回 confirmationRequired；断言 `status/on/off/start/stop/security/install/uninstall/--release/-t/-w/-disu` 全部失败且不改变状态。

- [ ] **Step 2: 实现 Command 与输出格式**

帮助必须精简并包含：默认、refresh、hold、switch force、config、setup、help。Timer 输出包含剩余分钟和本地 deadline；Timer+Hold 同时逐行显示；refresh+Hold 输出拒绝原因。

- [ ] **Step 3: 写 Hold 信号失败测试**

命令级测试在 fake agent 环境中启动 Hold 并分别发送 INT、TERM、HUP、QUIT，断言自己的 Lease 被移除；发送 TSTP，断言停止前 Lease 已移除；发送 CONT，断言 generation 未变时恢复；先 force 再 CONT，断言不得恢复；用 fake inspector 标记 stopped 覆盖 SIGSTOP。

- [ ] **Step 4: 实现 HoldSession signal-to-pipe**

handler 仅 `write()` 信号编号。INT/TERM/HUP/QUIT 统一 release+exit；TSTP release 后恢复默认处理并重发；CONT 通过状态事务校验 generation、安全快照与 owner identity 后恢复。Hold 每 250ms 检查 Lease 是否被 force/safety 撤销。

- [ ] **Step 5: 写 setup 失败测试**

断言规则同时包含且只包含两条 pmset 命令，`visudo -cf` 在安装前执行，文件模式为 0440，LaunchAgent label/ProgramArguments/KeepAlive/RunAtLoad 正确；重复 setup 不改变有效内容，损坏 plist/规则会修复；非 root 内部入口拒绝。

- [ ] **Step 6: 实现 setup 与 LaunchAgent**

公开 setup 先检查 `/usr/bin/pmset` 和 macOS，再把终端 stdin/stdout/stderr 交给 `/usr/bin/sudo <binary> __root-setup`；root helper 使用安全临时文件、`visudo -cf` 与 `/usr/bin/install`；用户态写 plist 后执行 `launchctl bootout`（忽略未加载）和 `bootstrap`，最后运行 self-check。

- [ ] **Step 7: 实现 lidgo main 的全部命令**

默认/refresh/switch/config/hold 都先做同一事务 reconcile，再 kickstart agent。配置更新只写 config；创建 Lease 前读取真实安全快照并在不安全时拒绝。隐藏 agent 直接进入 `AgentRuntime.run()`。

- [ ] **Step 8: 完成无 sudo 命令级测试**

使用 `LIDGO_TESTING=1`、临时目录和 fake system adapter；禁止读取或修改真实 `/etc/sudoers.d`、`/var/db`、`~/Library/LaunchAgents` 和真实 `pmset`。

- [ ] **Step 9: 运行 Task 3 验证**

Run: `swift run LidGoCoreTests`

Run: `bash tests/run_tests.sh`

Expected: 全部 0 failures，无真实系统状态变化。

- [ ] **Step 10: 审查并提交 Task 3**

Run: `git diff --check`

Commit: `feat: implement lidgo commands and setup`

---

### Task 4: 产品收口、死代码归档与最终验收

**Files:**
- Create: `scripts/build.sh`
- Create: `completions/_lidgo`
- Create: `.github/workflows/ci.yml`
- Create: `Formula/maclidawake.rb`
- Create: `docs/autonomous-runs/20260906-0000-maclidawake.md`（执行时以真实 HHmm 命名）
- Modify: `README.md`
- Modify: `docs/architecture-and-security.md`
- Modify: `docs/testing.md`
- Modify: `CLAUDE.md`
- Modify: `.gitignore`
- Archive locally and remove from product tree: `cli/keepawake/`, `experiments/`, old `tests/run_tests.sh` content

**Interfaces:**
- Consumes: 完整 `lidgo` 实现和全部测试证据。
- Produces: 稳定 README 入口、发布构建、completion、CI、Homebrew Formula 和逐路径验收记录。

- [ ] **Step 1: 写构建/CI/Formula/completion**

`scripts/build.sh` 运行 `swift build -c release`；CI 使用 macOS runner 执行 `swift run LidGoCoreTests`、命令级测试和 release build；Formula 从 `EdgarZhong/MacLidAwake` release source 构建并安装 `lidgo` 与 zsh completion，测试 `lidgo help`。在首个 tag 前 Formula 明确作为发布模板，不宣称可安装的已发布版本。

- [ ] **Step 2: 归档旧产品死代码**

先把 `.archive/` 加入 `.gitignore`，再将 `cli/keepawake/` 与 `experiments/` 移入 `.archive/upstream-keepawake/`，确保 Git 不跟踪归档内容。保留 `LICENSE`，README 保留 upstream attribution。

- [ ] **Step 3: 重写 README 与文档索引**

README 首屏必须出现 `MacLidAwake`、`CLI: lidgo` 和句子：

```text
Temporarily keep a MacBook running with the lid closed, then automatically restore normal sleep behavior.
```

README 记录稳定安装/使用、安全摘要、目录、开发命令、限制和 docs 索引，不放动态任务看板。

- [ ] **Step 4: 运行完整自动验证**

Run: `swift run LidGoCoreTests`

Run: `bash tests/run_tests.sh`

Run: `swift build -c release`

Run: `git diff --check`

Run: `rg -n "keepawake|caffeinate|CGVirtualDisplay" Sources Tests tests scripts completions README.md docs --glob '!docs/archived/**'`

Expected: 测试/构建 0 failures；搜索只剩合法 attribution 或历史说明。

- [ ] **Step 5: 按用户行为路径写入并执行验收记录**

在 `docs/autonomous-runs/YYYYMMDD-HHmm-maclidawake.md` 枚举默认 Timer、幂等、refresh、Hold、多 Hold、四个清理信号、TSTP/CONT、模拟 STOP、Timer+Hold、force、Battery、Thermal、stale、setup、help/config。每项记录预期、命令、结果和 PASS/SKIP；物理合盖、真实 cutoff、真实 sudo 明确标为未执行或需用户确认。

- [ ] **Step 6: 最终自审并提交**

逐条对照 `docs/product-spec.md`，检查公开命令、权限、race、signal、cleanup、fail-safe 和 docs 职责；更新 CLAUDE 任务状态。

Commit: `docs: complete MacLidAwake product migration`

- [ ] **Step 7: GitHub 外部发布门**

确认用户选择 public 或 private 后执行：

```text
gh repo create EdgarZhong/MacLidAwake --source=. --description "A safety-first macOS CLI for temporarily keeping a MacBook running with the lid closed, with automatic sleep restoration." --public|--private
gh repo edit EdgarZhong/MacLidAwake --add-topic macos --add-topic macbook --add-topic swift --add-topic cli --add-topic sleep
git push -u origin main
```

在执行前再次检查 `gh auth status`、远端目标和完整验证；不得推送到原 `ecc521/keepawake`。
