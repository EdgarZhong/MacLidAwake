# MacLidAwake

**临时让 MacBook 合盖继续运行——之后自动恢复正常睡眠。**

[English README](README.md)

MacLidAwake 只解决一个问题：你需要合盖带着 MacBook 走一段路，但本地任务——Claude Code、Codex 这样的 AI agent、编译、下载——还要继续跑。当 Timer 到期、你结束 Hold，或安全条件触发时，Mac 自动恢复正常睡眠。

它不是通用电源管理器，不是 `caffeinate` 的兼容克隆，也不是命令包装器。

## 系统要求

- macOS 13（Ventura）或更高版本，Apple Silicon 与 Intel 均可。
- 管理员账号。`lidgo setup` 会通过系统 `sudo` 提示请求一次密码——MacLidAwake 不会看到、保存或代输你的密码。

## 安装

**Homebrew**（安装预编译通用二进制和 zsh 补全）：

```bash
git clone https://github.com/EdgarZhong/MacLidAwake.git
cd MacLidAwake
brew install --formula Formula/maclidawake.rb
```

**预编译二进制**：从 [GitHub Releases](https://github.com/EdgarZhong/MacLidAwake/releases) 下载：

```bash
tar -xzf maclidawake-*-macos.tar.gz
cd maclidawake-*-macos
xattr -d com.apple.quarantine lidgo   # 仅浏览器下载需要
install -m 0755 lidgo "${HOME}/.local/bin/lidgo"
```

**从源码构建**（需要 Swift 6 工具链）：

```bash
git clone https://github.com/EdgarZhong/MacLidAwake.git
cd MacLidAwake
./scripts/build.sh
install -m 0755 .build/release/lidgo "${HOME}/.local/bin/lidgo"
```

确保 `~/.local/bin`（或你选择的安装目录）已在 `PATH` 中。

## 初始化（只需一次）

```bash
lidgo setup
```

该命令幂等安装以下三项，损坏时也可修复：

- 一条 **sudoers 规则**，只允许免密执行 `pmset -a disablesleep 1` 与 `pmset -a disablesleep 0` 两条精确命令（安装前经 `visudo` 校验）；
- root 拥有的**参与锁** `/var/db/maclidawake.lock`；
- 每用户 **LaunchAgent**，在后台监督 Timer 与安全熔断。

## 使用

```text
lidgo                        启动默认 60 分钟 Timer（已开启时只显示状态）
lidgo --hold                 前台维持合盖运行，Ctrl-C 结束
lidgo -r | --refresh         重置 Timer（存在 Hold 时拒绝）
lidgo switch -f | --force    强制反转全局状态
lidgo config                 显示配置
lidgo config -d 45           将未来 Timer 设为 45 分钟（也支持 90m、2h、1h30m）
lidgo config -b 10           设置低电量安全阈值（百分比）
lidgo setup                  安装或修复权限与 LaunchAgent
lidgo help                   显示帮助
```

- 默认配置：**Timer 60 分钟**、**电量阈值 10%**。
- Timer 运行中再执行 `lidgo` 只显示截止时间，不会悄悄刷新。
- Timer 与多个 Hold 可以并存；只有最后一个有效 Lease 消失时才恢复正常睡眠。
- Hold 会同时校验 PID、进程启动身份与运行状态——被 Ctrl-Z 暂停或已退出的进程不会把你的 Mac 永久钉在唤醒状态。

## 安全模型

- 不保存密码、不用 Keychain、不自动输密码；日常运行只使用 `sudo -n`。
- 电量达到阈值、电池状态不可读或温度压力达到 critical 时，所有 Lease 被清除并保持关闭，条件恢复后也不会自动重新开启。
- `lidgo switch -f` 与安全熔断会递增 generation 计数，旧 Hold 无法抢回唤醒状态。
- 完整设计见 [docs/architecture-and-security.md](docs/architecture-and-security.md)。

## 卸载

```bash
launchctl bootout "gui/$(id -u)" com.maclidawake.lidgo.agent 2>/dev/null
rm -f "${HOME}/Library/LaunchAgents/com.maclidawake.lidgo.agent.plist"
sudo rm -f /etc/sudoers.d/maclidawake
sudo rm -f /var/db/maclidawake.lock
rm -rf "${HOME}/Library/Application Support/MacLidAwake"
rm -f "${HOME}/.local/bin/lidgo"   # 或：brew uninstall maclidawake
```

## 已知限制

- `SleepDisabled` 是系统全局布尔值，没有所有者信息；MacLidAwake 的 fail-safe 清理可能覆盖手工或其他工具设置的同一值。
- 监督器运行在登录用户会话内；开机到登录之前不承诺主动修复状态。
- 真实合盖效果受具体 MacBook 机型、macOS 版本和硬件状态影响。

## 开发者入口

测试、CI 与发布自动化位于 `tests/`、`scripts/` 与 `.github/workflows/`。完整规格见 [docs/testing.md](docs/testing.md) 与 [docs/product-spec.md](docs/product-spec.md)。

## License 与上游归属

MacLidAwake 基于 [ecc521/keepawake](https://github.com/ecc521/keepawake) 改造，复用了其最小权限设计：精确 sudoers 授权、`pmset` 与内核参与锁。项目继续遵守 MIT License，并保留 Tucker Willenborg 的版权声明。详见 [LICENSE](LICENSE)。
