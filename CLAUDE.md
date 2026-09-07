# MacLidAwake 当前阶段执行看板

## 当前核心目标

在现有 `ecc521/keepawake` clone 上完成 MacLidAwake 重构，交付公开命令 `lidgo`，保留成熟的最小权限模型，并实现持久 Timer Lease、并发 Hold Lease、安全熔断、异常恢复和完整测试。

次要目标：把 CLI 与本机默认配置统一为 Timer 60 分钟、Battery cutoff 10%，随后完成真实 `lidgo setup` 与安全冒烟验收。2026-09-07 用户重新授权 GitHub 公开发布，发布流程已随 v1.0.0 完成（Release 工作流第二次运行成功，已产出 tarball+sha256 并回提 Formula；main 上排队不前的 CI 运行按用户指示取消，不再纠缠）。

## 已确认执行口径

- 直接在当前 `main` 工作区实现，不创建 worktree。
- 不再使用子 Agent；实现、审查和验证全部由当前会话串行完成。
- CLI 内置默认配置与本机配置均固定为 Timer 60 分钟、Battery cutoff 10%。
- duration 裸整数按分钟解释；显式单位只支持小写 `h`、`m`，不支持 `s`；保留 `1h30m` 组合写法。
- `lidgo config` 的 duration/battery 同时支持 `-d`/`--duration` 与 `-b`/`--battery`；同一配置项不得重复指定。
- `lidgo setup` 的首次 sudo 认证必须直接继承终端 stdin/stdout/stderr，并与调用进程保持同一前台进程组，禁止捕获认证提示或密码输入。2026-09-06 真实试装暴露 Foundation `Process` 会新建后台进程组，造成密码回显并停止；现已改用默认属性的 `posix_spawn`，PGID 回归测试与假口令无回显测试通过，真实 sudo 复验待完成。
- 当前优先完成公开发布收尾：远端仓库已建，Release 自动化已上线。
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
- [x] 阶段 4：完成命名迁移、README/docs/打包/CI/补全、归档死代码并做最终用户级验收（38 tests passed；28 command scenarios passed；Release/build/Formula/style/static checks passed）。
- [x] 阶段 5：将 CLI 与本机默认配置统一为 60 分钟/10%，完成真实 setup、Timer/Hold 清理与恢复验收（用户确认本机测试与验证通过）。
- [x] 阶段 6（2026-09-07 用户重新授权并执行）：CLI 全部用户可见文案英文化（Sources/completions/tests 零残留 CJK）；README 重写为面向用户的双语版本（英文 `README.md` + `README.zh-Hans.md`）；CI 增加 macos-13(Intel)/macos-latest 矩阵；新增 `.github/workflows/release.yml`：tag `v*` 触发，跑测试、构建 arm64+x86_64 universal 二进制、打包 tar.gz + sha256、创建 GitHub Release，并把 `Formula/maclidawake.rb` 重写为指向该 tarball 的二进制 formula 后自动回提 main；创建公开 `EdgarZhong/MacLidAwake` 并推送，首发 tag `v1.0.0`。

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
- 最终验收前后只读采样均为 `SleepDisabled=0`；项目开始时观察到的外部 1 已在本测试范围外发生变化，自动测试全程未调用真实 pmset。
- Ruling：本机 Command Line Tools 的 Swift 6.3.2 不含 `XCTest`/Swift Testing；改用零依赖 `LidGoCoreTests` 可执行 harness。若判断错误，代价是偏离惯用 `swift test` 工作流，但不会降低断言范围或失败门禁。

## 当前风险与限制

- 物理合盖是否持续运行无法由软件模拟，必须人工验收。
- 真实 Battery/Thermal 条件无法稳定自动制造，自动测试只能验证状态机与 fake 系统适配器。
- LaunchAgent 属于登录用户会话；开机到用户登录之前不承诺主动修复状态。
- 系统 `SleepDisabled` 是全局设置，LidGo 在无有效 Lease 时执行 fail-safe 清理可能与手工设置或其他工具发生冲突，必须在文档中明确。
- Release formula 为预编译二进制安装；首个 tag 前的 HEAD-only 源码 formula 会被 release 工作流整体重写。

## 完成定义

- 规格中全部公开命令和 Lease 行为均有自动化测试。
- Release 构建无 warning，测试零失败，代码中无公开旧 keepawake/caffeinate 接口和无用实验依赖。
- sudoers、LaunchAgent、状态目录和安全恢复路径均有命令级验证。
- `docs/autonomous-runs/20260906-0000-maclidawake.md` 记录每条用户行为路径、预期和实测证据；实际完成时用真实开始时间修正文件名。
- GitHub 创建与推送只有在本地验收通过且 visibility 明确后执行。
