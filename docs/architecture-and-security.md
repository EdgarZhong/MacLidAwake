# 架构与安全设计

## 模块结构

```text
Package.swift
Sources/
  LidGoCore/
    Models.swift             配置、Timer、Hold、runtime state
    Paths.swift              生产路径与测试路径
    StateStore.swift         flock 事务、原子 JSON 读写
    ProcessInspector.swift   PID 启动身份与运行状态
    LeaseCoordinator.swift   Lease 规则、generation、状态输出
    PowerController.swift    精确 sudo pmset 与全局参与锁
    SafetyMonitor.swift      IOKit 电池与 thermal 采样/通知
    AgentRuntime.swift       deadline、stale、wake、熔断和 fail-safe
    SetupManager.swift       sudoers、LaunchAgent、目录、自检
    HoldSession.swift        signal pipe 与 Hold 生命周期
  lidgo/
    main.swift               CLI 解析、输出与内部 agent/root 入口
tests/
  LidGoCoreTests/            纯单元和文件事务测试
tests/
  run_tests.sh               无 sudo 命令级验收
```

## 状态结构

```swift
struct LidGoConfig: Codable, Equatable {
    var defaultDurationSeconds: Int = 3600
    var batteryCutoffPercent: Int = 15
}

struct TimerLease: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    var deadline: Date
    let generation: UInt64
}

struct HoldLease: Codable, Equatable {
    let id: UUID
    let pid: Int32
    let processStartTime: UInt64
    let generation: UInt64
    let createdAt: Date
}

struct RuntimeState: Codable, Equatable {
    var schemaVersion: Int = 1
    var generation: UInt64 = 0
    var timer: TimerLease?
    var holds: [HoldLease] = []
    var lastSafetyStop: SafetyStop?
}
```

`generation` 是全局撤销栅栏。`switch -f` 或安全熔断递增它；旧 Hold 即使仍存活或从 stop 恢复，也因 generation 不匹配而不能重建 Lease。普通 SIGTSTP/SIGSTOP 只让单个 Hold 失效，不递增 generation，从而允许 SIGCONT 在安全条件下恢复。

## 一致性边界

`StateStore.withLock` 是唯一读改写入口：

1. 打开 0700 Application Support 目录内的 lock 文件并取得 `LOCK_EX`。
2. 读取并校验 schema；损坏文件隔离为诊断副本，运行状态按空状态处理。
3. 清理过期 Timer 和无效 Hold。
4. 应用一个命令或 agent 事件。
5. 在同目录写临时 JSON、`fsync`、`rename`，最终模式 0600。
6. 释放锁。

输出状态只从事务返回值生成，避免解锁后再次读取造成 TOCTOU。

## 进程身份

`ProcessInspector` 使用 macOS `proc_pidinfo(PROC_PIDTBSDINFO)` 获取：

- PID 是否存在。
- `pbi_start_tvsec/pbi_start_tvusec` 组合的启动身份，防止 PID reuse。
- `pbi_status`，将 stopped/zombie 视为无效；running 与 sleeping 均视为可运行。

监督器至少每秒复核 Hold，因此不可捕获的 SIGSTOP 最迟在一个监督周期内失效。SIGTSTP 由前台进程主动先释放，可立即失效。

## pmset 协调

保留上游“内核统计参与者”的思想，但只有 LaunchAgent 监督器持有 `/var/db/maclidawake.lock` 的共享锁：

- 本用户存在有效 Lease：监督器取得 `LOCK_SH`，再执行精确 `pmset ... 1`。
- 本用户最后一个 Lease 消失：释放 `LOCK_SH`，尝试 `LOCK_EX|LOCK_NB`；成功表示没有其他 LidGo 监督器参与，才执行 `pmset ... 0`。
- root setup 将锁文件创建为 `0660 root:admin`，普通进程只以 `O_NOFOLLOW` 打开且不创建；非管理员用户不能占有全局锁制造拒绝释放。

这一结构保留多登录用户不互相提前清除的优点，并避免任意短命 CLI 直接长期占有全局锁。

## 信号模型

HoldSession 在创建 Lease 之前安装 handler。handler 只向非阻塞 pipe 写入信号编号；状态修改、pmset 触发和进程退出全部回到串行 run loop：

- INT/TERM/HUP/QUIT：释放自身 Lease并退出。
- TSTP：释放自身 Lease，临时恢复 SIGTSTP 默认处理并向自身重发；继续运行后恢复 handler。
- CONT：读取同一 Hold 的 generation；未被强制撤销且安全时重新登记，否则退出无效 Hold。
- STOP：无法捕获，由 AgentRuntime 的进程状态复核移除；CONT 后仍通过 generation 与安全检查。

Hold 同时轮询自己的 Lease 是否仍存在。force 或 safety 清理后，它会明确提示撤销并退出，不会自动抢回。

## sudoers 与 setup 事务

公开 `lidgo setup` 只在需要特权阶段调用：

```text
/usr/bin/sudo <当前 lidgo 绝对路径> __root-setup
```

它不使用 `sudo -S`，标准输入直连终端，允许 sudo 自己完成一次认证。root 内部入口：

1. 生成只含两条 pmset argv 的规则临时文件。
2. 设置 0440 并运行 `visudo -cf`。
3. 创建或修复 `0660 root:admin` 全局锁。
4. 仅在全部准备完成后原子安装 sudoers；失败时保留旧可用规则，不留下只完成一半的新配置。

随后用户态 setup 写入 LaunchAgent plist、bootstrap/kickstart 并执行自检。内部 `__agent`、`__root-setup` 不出现在帮助中，不属于公开 CLI。

## 安全熔断

`SafetyMonitor` 返回电量百分比与 thermal state。AgentRuntime 每次启动、定时 tick、电池/thermal 通知和 wake 时评估：

- battery `<= configured cutoff`：`trip(.battery)`。
- thermal `.critical`：`trip(.thermal)`。

`trip` 在状态事务中清空全部 Lease、递增 generation、记录原因；事务完成后 PowerController 释放参与锁并恢复睡眠。后续安全恢复只更新观察结果，不创建 Lease。

## 威胁边界与已知限制

- sudoers 把权限限制为两个字节级精确 argv，但管理员组成员本来就拥有完整 sudo 权限；它不能防范恶意本机管理员。
- `SleepDisabled` 是系统全局布尔值，不携带所有者。没有官方 API 可证明 1 是 LidGo 还是其他工具设置；按产品 fail-safe 规则，LidGo 监督器启动且无 Lease 时会尝试恢复 0，可能覆盖手工设置。
- LaunchAgent 只在用户登录会话中运行；登录前和用户明确 unload 后没有持续监督保证。
- 物理合盖、硬件电池和 thermal 行为必须在真实 MacBook 上人工验证。
