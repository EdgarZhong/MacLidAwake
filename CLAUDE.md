# MacLidAwake 当前阶段执行看板

## 当前核心目标

在现有 `ecc521/keepawake` clone 上完成 MacLidAwake 重构，交付公开命令 `lidgo`，保留成熟的最小权限模型，并实现持久 Timer Lease、并发 Hold Lease、安全熔断、异常恢复和完整测试。

次要目标：本地验收通过后，使用 GitHub CLI 在账号 `EdgarZhong` 下创建新仓库、填写元数据并推送。仓库 visibility 尚待用户确认，因此不得提前创建。

## 已确认执行口径

- 直接在当前 `main` 工作区实现，不创建 worktree。
- 不再使用子 Agent；实现、审查和验证全部由当前会话串行完成。
- 清理信号包含 `SIGINT`、`SIGTERM`、`SIGHUP`、`SIGQUIT`。
- 保留上游 MIT License 和 attribution。
- 旧实验与旧 CLI 不直接删除，移入未跟踪的 `.archive/` 后从产品主干剔除。
- 当前机器在开始时已有外部 `SleepDisabled=1`，且未安装 keepawake sudoers；自动测试不得清除或接管该外部状态。

## 原项目基线

- HEAD：`7603dad1a953ad383f9d17a7221d0c829a9d9d4f`。
- 旧实现：单文件 Swift CLI，以 root 创建的 `/var/db/keepawake.lock` 和共享 `flock` 协调前台 session，通过严格 NOPASSWD sudoers 执行两条 `pmset` 命令。
- 可复用：精确 sudoers、`visudo -cf`、固定绝对路径、`O_NOFOLLOW`、内核锁、IOKit 电池 API、thermal 通知、signal-to-pipe、主队列串行清理。
- 必须替换：caffeinate 兼容参数、进程内 duration、命令包装、`-w`、自动恢复的 Battery/Thermal 策略、无持久状态的布尔参与模型。
- 基线测试：20 passed、0 failed、2 skipped；真实 hold 因未安装旧 sudoers 跳过。

## 本轮任务看板

- [x] 阶段 1：建立 Swift Package、配置/Lease 模型、原子状态仓库和纯状态机测试（14 tests passed；Release warnings-as-errors 构建通过）。
- [x] 阶段 2：实现进程身份、pmset 协调、常驻 LaunchAgent 监督器、Timer 到期和 Battery/Thermal 熔断（26 tests passed；Release warnings-as-errors 构建通过）。
- [x] 阶段 3：实现公开 CLI、Hold 信号语义、setup/自检与命令级测试（37 tests passed；16 command scenarios passed；Release warnings-as-errors 构建通过）。
- [ ] 阶段 4：完成命名迁移、README/docs/打包/CI/补全、归档死代码并做最终用户级验收。
- [ ] 阶段 5：确认 GitHub visibility，创建 `EdgarZhong/MacLidAwake`、设置简介/topics、替换 origin 并推送。

## 关键架构决策

- 同一用户的运行状态存放在 `~/Library/Application Support/MacLidAwake/`，文件锁保护所有读改写事务。
- root 预置的全局参与锁采用 `0660 root:admin`，不沿用上游过宽的 `0666`。
- 电池状态无法读取时按 fail-safe 安全熔断处理，并记录 `batteryUnavailable`；不会因恢复可读而自动重建 Lease。
- launchd 以 `com.maclidawake.lidgo.agent` 常驻监督器维持 Timer，清理过期/stale Hold，并负责实际 `pmset` 协调。
- runtime state 包含 `schemaVersion`、`generation`、可选 Timer、Hold 列表和最近安全停止原因。
- Hold 使用 UUID + PID + 进程启动时间验证身份；监督器轮询进程状态以识别 SIGSTOP。
- SIGTSTP handler 先原子释放自身 Lease，再向自身发送不可忽略的 SIGSTOP；这避免非交互/orphaned process group 忽略 job-control stop，SIGCONT 仍走 generation、owner 与安全复核。
- Agent 自身也通过 signal-to-pipe 处理 INT/TERM/HUP/QUIT，在 launchd 重载或退出前先将本用户电源目标恢复为 OFF。
- 强制关闭和安全熔断清空 Lease 并递增 generation；普通 Hold 停止/死亡不递增，以允许同一前台进程在 SIGCONT 后有条件恢复。
- Thermal 固定采用上游默认的 critical 门槛，不提供关闭入口；Battery 在电量小于等于配置阈值时触发，恢复条件不会自动重建 Lease。
- 测试通过注入的目录、时钟、进程检查器和 pmset fake 覆盖全路径，不触碰当前外部 `SleepDisabled=1`。
- Ruling：本机 Command Line Tools 的 Swift 6.3.2 不含 `XCTest`/Swift Testing；改用零依赖 `LidGoCoreTests` 可执行 harness。若判断错误，代价是偏离惯用 `swift test` 工作流，但不会降低断言范围或失败门禁。

## 当前风险与限制

- 物理合盖是否持续运行无法由软件模拟，必须人工验收。
- 真实 Battery/Thermal 条件无法稳定自动制造，自动测试只能验证状态机与 fake 系统适配器。
- LaunchAgent 属于登录用户会话；开机到用户登录之前不承诺主动修复状态。
- 系统 `SleepDisabled` 是全局设置，LidGo 在无有效 Lease 时执行 fail-safe 清理可能与手工设置或其他工具发生冲突，必须在文档中明确。

## 完成定义

- 规格中全部公开命令和 Lease 行为均有自动化测试。
- Release 构建无 warning，测试零失败，代码中无公开旧 keepawake/caffeinate 接口和无用实验依赖。
- sudoers、LaunchAgent、状态目录和安全恢复路径均有命令级验证。
- `docs/autonomous-runs/20260906-0000-maclidawake.md` 记录每条用户行为路径、预期和实测证据；实际完成时用真实开始时间修正文件名。
- GitHub 创建与推送只有在本地验收通过且 visibility 明确后执行。
