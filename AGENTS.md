# MacLidAwake 协作规则

## 文档职责

- `README.md` 只记录已经落实的稳定事实、安装与使用入口、目录骨架、开发命令和重要文档索引。
- `AGENTS.md` 只记录长期适用的规则、流程、代码约束和验收要求。
- `CLAUDE.md` 只记录当前阶段目标、任务看板、执行决策、风险和进度。
- 产品、安全、架构和测试专项说明写入 `docs/`；不读取或恢复 `docs/archived/`，除非用户明确要求。

## 产品边界

- 产品名固定为 `MacLidAwake`，公开 CLI 固定为 `lidgo`。
- 产品只解决“临时合盖移动 MacBook 时让本地任务继续运行，并安全恢复正常睡眠”这一问题。
- 公开命令只允许：`lidgo`、`lidgo --hold`、`lidgo -r|--refresh`、`lidgo switch -f|--force`、`lidgo config ...`、`lidgo setup`、`lidgo help|-h|--help`。
- 不增加通用电源管理、caffeinate 兼容、命令包装、`status/on/off/start/stop/security` 等接口。

## 安全不变量

- 永不保存、加密保存或自动输入管理员密码；不使用 Keychain 保存认证材料。
- sudoers 只允许 `/usr/bin/pmset -a disablesleep 1` 和 `/usr/bin/pmset -a disablesleep 0` 两条精确命令。
- sudoers 必须在安装前通过 `/usr/sbin/visudo -cf`，最终权限必须为 `0440 root:wheel`。
- 特权路径使用固定绝对路径；非 setup 运行只能使用 `sudo -n`。
- `/var/db/maclidawake.lock` 必须由 root 创建为 `0660 root:admin`；普通运行只以 `O_NOFOLLOW` 打开，不得创建或跟随符号链接。
- 没有任何可验证的有效 Lease 时，目标状态必须是 `SleepDisabled=0`。
- Battery 或 Thermal 熔断必须清除全部 Lease 并保持 OFF，不得在条件恢复后自动重新开启。
- Hold 有效性必须同时校验 PID、进程启动身份与运行状态；stopped、suspended、zombie、dead、PID reuse 均不得维持 Lease。
- 强制关闭或安全熔断必须递增 generation，使旧 Hold 无法重新抢回 Lease。
- `SIGINT`、`SIGTERM`、`SIGHUP`、`SIGQUIT` 必须走 signal-to-pipe 清理路径；`SIGTSTP` 必须先释放 Lease 再停止，`SIGCONT` 只能在 generation 未变化且安全检查通过时恢复。

## 代码规范

- 使用 Swift Package Manager；业务规则位于 `LidGoCore`，可执行入口只负责参数解析、依赖组装和输出。
- 时间、进程状态、系统电源、launchctl 与文件路径均通过可替换依赖访问，测试不得依赖真实 sudo 或真实 `pmset`。
- 所有状态变更在文件锁保护下完成；状态文件使用原子替换，JSON schema 具有显式版本。
- 公开类型和跨模块接口必须有简短文档；错误信息应给出可执行的修复路径。
- 保留上游 MIT License 和 attribution，不把派生项目描述成从零实现。

## 开发测试闭环 SOP

1. 新会话先读 `AGENTS.md`、`CLAUDE.md`，并检查最近两次提交中的 Markdown 变更。
2. 从 `README.md` 的文档索引进入产品、安全或测试规格；默认不查看归档文档。
3. 先写失败测试，再实现最小变更；每个阶段运行对应测试后再提交。
4. 涉及状态机时覆盖 Timer、Hold、多 Hold、Timer+Hold、refresh、force、过期、stale、PID reuse 和 generation。
5. 涉及信号时覆盖 SIGINT、SIGTERM、SIGHUP、SIGQUIT、SIGTSTP、SIGCONT，并用监督器测试覆盖不可捕获的 SIGSTOP。
6. 涉及 setup 时验证 sudoers 正反例、文件模式、固定 argv、LaunchAgent plist 和幂等修复；自动测试不得弹出密码框。
7. 完成前执行 `swift run LidGoCoreTests`、命令级测试、Release 构建、文档/死代码扫描和 git diff 审查。
8. 真实 sudo、真实 pmset、物理合盖、低电量与危险温度只按 `docs/testing.md` 的人工步骤执行，不能用模拟结果冒充硬件验收。

## 文件与 Git 约束

- 不直接删除文件。需要从产品主干剔除的旧文件先移入仓库根目录 `.archive/`，并确保 `.archive/` 不被 Git 跟踪。
- 不覆盖或清理用户无关改动；执行恢复、清理、回退前必须确认目标。
- 本项目小型实现按用户要求直接在当前工作区完成，不创建 worktree。
- 每个阶段提交前必须有新鲜验证证据；最终推送前再次执行完整验证。
