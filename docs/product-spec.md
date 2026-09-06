# MacLidAwake 产品规格

## 定位

MacLidAwake 是面向 macOS/MacBook 的极简 CLI。它让用户在临时合盖移动电脑时继续运行 Codex、Claude Code、编译、下载等本地任务，并在租约结束或安全条件触发后恢复正常睡眠。

产品名为 `MacLidAwake`，CLI 名为 `lidgo`。它不是通用电源管理器，也不是 caffeinate 替代品。

## 公开 CLI 契约

公开接口仅包含：

```text
lidgo
lidgo --hold
lidgo -r
lidgo --refresh
lidgo switch -f
lidgo switch --force
lidgo config
lidgo config --duration 90m
lidgo config --duration 2h
lidgo config --duration 1h30m
lidgo config --battery 15
lidgo setup
lidgo help
lidgo -h
lidgo --help
```

不增加 `status`、`on`、`off`、`security`、`start`、`stop`、caffeinate flags、命令包装或外部 PID 等公开入口。

### 默认命令

- 完全 OFF：按 `config.defaultDuration` 创建唯一 Timer Lease，立即返回。
- 已有 Timer：只显示剩余时间和 deadline，不刷新。
- 已有 Hold：只显示 Hold 数量；Timer 与 Hold 可同时显示，不改变状态。

### Refresh

- OFF：等价于默认命令，创建默认 Timer。
- 只有 Timer：deadline 更新为当前时间加 `defaultDuration`。
- 存在任意 Hold：拒绝且不得修改任何 Lease。

### Hold

- `lidgo --hold` 创建属于当前前台进程的 Hold Lease，并持续运行到释放、撤销或安全停止。
- 多个终端可各自持有 Hold；每个 Hold 独立释放，最后一个有效 Lease 消失时恢复正常睡眠。
- `SIGINT`、`SIGTERM`、`SIGHUP`、`SIGQUIT`：删除自己的 Lease 后退出。
- `SIGTSTP`：先删除自己的 Lease，再允许进程停止。
- `SIGSTOP`：监督器必须识别进程 stopped 并移除 Lease。
- `SIGCONT`：仅在原 generation 未变化且电池/温度仍安全时重新申请 Lease。
- force 或安全熔断撤销后，旧 Hold 不得自动重新申请。

### Switch

- `lidgo switch`：只提示必须使用 force，不改变状态。
- OFF + force：创建默认 Timer。
- ON + force：清除 Timer 和全部 Hold，递增 generation，恢复正常睡眠；存活 Hold 必须感知撤销并退出或保持无效。

### Config

- 默认配置：Timer 60 分钟、Battery cutoff 15%、Thermal safety enabled。
- duration 支持 `90m`、`2h`、`1h30m`，必须大于 0。
- battery 必须为 1–99 的整数。
- 一次调用可同时更新 duration 和 battery。
- 配置修改只影响未来 Timer 和 refresh，不改变现有 Timer deadline。

### Setup

`lidgo setup` 必须幂等完成：macOS 与 `pmset` 检查、一次正常 sudo 认证、严格 sudoers 安装/修复、`visudo -cf`、状态/配置目录、LaunchAgent 安装/修复、启动和完整自检。不得保存密码或自动向 sudo stdin 写入密码。

## Lease 状态模型

状态包含最多一个 Timer Lease 和任意数量 Hold Lease：

```text
存在至少一个有效 Lease  -> SleepDisabled = 1
最后一个有效 Lease 消失 -> SleepDisabled = 0
```

Timer 和 Hold 可共存。Timer 到期只删除 Timer；仍有 Hold 时继续保持。Hold 释放只删除自己；仍有 Timer 或其他 Hold 时继续保持。

Hold 身份不得只依赖 PID，至少校验 PID、进程启动时间和运行状态，区分 running、sleeping、stopped/suspended、zombie、dead 和 PID reuse。

## 安全模型

sudoers 只授权：

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

规则安装前使用 `/usr/sbin/visudo -cf`，最终文件为 `0440 root:wheel`。普通运行使用 `sudo -n`，不保存或注入任何认证凭据。

Battery ≤ cutoff、MacBook 电池状态无法读取或 thermal pressure 达到 critical 时：

1. 清除全部 Timer/Hold Lease。
2. 递增 generation。
3. 取消 Timer。
4. 设置 `SleepDisabled=0`。
5. 保持 OFF；条件恢复后不自动开启。

## Timer 与监督器

Timer 不依赖创建它的 shell。`lidgo setup` 安装 `com.maclidawake.lidgo.agent` LaunchAgent；监督器负责 deadline、Hold 有效性、Battery/Thermal、唤醒后复核和 fail-safe 恢复。

禁止以 `sleep ... &` 作为 Timer 实现。

## 状态与并发

配置、Timer、Hold、generation 和安全停止元数据位于：

```text
~/Library/Application Support/MacLidAwake/
```

所有读改写事务使用文件锁；JSON 状态具有 schema version；写入使用同目录原子替换。两个默认命令、多个 Hold、refresh/force、Timer 到期/Hold 退出和安全熔断同时发生时，不得丢失更新。

## 异常恢复

无法确认时优先恢复正常睡眠。发现 Timer 已过期、Hold dead/stopped/stale、PID reuse、状态文件损坏或没有合法 Lease 时，清理无效状态并将目标状态恢复为 `SleepDisabled=0`。系统重启、LaunchAgent 重启和 wake 后均重新执行一致性检查。

## 法律与归属

项目基于 `https://github.com/ecc521/keepawake` 改造，继续遵守上游 MIT License，保留 Tucker Willenborg 的版权声明，并在 README 中明确 attribution。
