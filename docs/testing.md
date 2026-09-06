# 测试与验收说明

## 自动化分层

### 单元测试

运行：

```bash
swift test
```

覆盖：

- duration 解析与配置校验。
- 默认 Timer 创建、默认幂等、refresh、config 不改现有 deadline。
- Timer + Hold、多 Hold、独立释放、Timer 到期。
- force 清理、generation 撤销、Hold 恢复条件。
- dead、stopped、zombie、PID reuse 清理。
- Battery/Thermal 全局熔断与不自动恢复。
- 损坏/残留状态 fail-safe、原子写入与并发事务。
- sudoers 文本精确范围和 LaunchAgent plist 内容。

### 命令级测试

运行：

```bash
bash tests/run_tests.sh
```

测试设置 `LIDGO_TESTING=1` 并使用临时 Application Support、fake pmset、fake launchctl 和可控安全/进程快照；不得访问 `/etc/sudoers.d`、`/var/db` 或改变真实 `SleepDisabled`。

覆盖公开命令输出、非法参数无副作用、Timer 幂等/refresh、switch force、config、多个前台 Hold、SIGINT/SIGTERM/SIGHUP/SIGQUIT、SIGTSTP/SIGCONT、模拟 SIGSTOP 监督、agent 到期和安全熔断。

### 构建与静态检查

```bash
swift build -c release
rg -n "keepawake|caffeinate|CGVirtualDisplay|status| on | off " Sources Tests tests README.md docs --glob '!docs/archived/**'
git diff --check
```

搜索结果逐条判断：upstream attribution 可以保留；公开旧命令、旧路径和产品死代码不得保留。

## 不可自动化的真实验收

以下步骤会改变真实系统睡眠状态，只能在用户确认并完成 `lidgo setup` 后执行：

1. `pmset -g` 确认初始 `SleepDisabled=0`。
2. `lidgo`，确认立即退出且 `SleepDisabled=1`；关闭 Terminal，等待 Timer 到期后确认回到 0。
3. 两个终端分别 `lidgo --hold`；依次 Ctrl-C，确认第一个退出仍为 1、最后一个退出为 0。
4. Hold 中按 Ctrl-Z，确认一个监督周期内为 0；`fg` 后确认恢复为 1。
5. 对 Hold PID 执行 `kill -STOP`，确认一个监督周期内 Lease 失效；`kill -CONT` 后在 generation 未变化且安全时恢复。
6. Hold 中按 Ctrl-\\ 产生 SIGQUIT，确认 Lease 清理并退出。
7. Timer + Hold 共存，让 Timer 到期，确认 Hold 仍维持；释放 Hold 后回到 0。
8. ON 状态执行 `lidgo switch -f`，确认全部 Hold 被撤销且不重新抢回。
9. 在受控条件下把 battery cutoff 设置到当前电量附近，确认熔断后接电不自动恢复。
10. 物理合盖并移动一段短时间，用 `pmset -g log` 与后台任务结果确认真实合盖路径。

## 安全验收原则

- 自动测试通过不等于“绝对安全”。
- 测试日志必须区分 PASS、SKIP 和未执行的硬件路径。
- 如果测试开始时发现外部 `SleepDisabled=1`，不得擅自清除；真实系统测试应停止并要求用户确认来源。
