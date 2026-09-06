# MacLidAwake

Temporarily keep a MacBook running with the lid closed, then automatically restore normal sleep behavior.

CLI：`lidgo`

MacLidAwake 面向临时合盖移动场景：让 Codex、Claude Code、编译或下载任务继续运行，并在 Timer/Hold Lease 结束或安全条件触发后恢复正常睡眠。它不是通用电源管理器，也不是命令包装器。

## 系统要求

- macOS 13 或更高版本，Apple Silicon 与 Intel Mac 均可构建。
- 管理员账号；`lidgo setup` 会由系统 `sudo` 正常请求一次认证。
- Swift 6 工具链仅在从源码构建时需要。

## 从源码安装

```bash
./scripts/build.sh
/usr/bin/install -d "${HOME}/.local/bin"
/usr/bin/install -m 0755 .build/release/lidgo "${HOME}/.local/bin/lidgo"
export PATH="${HOME}/.local/bin:${PATH}"
lidgo setup
```

`lidgo setup` 幂等安装或修复 sudoers、全局参与锁与 LaunchAgent。首个 tag 发布前，[Homebrew Formula](Formula/maclidawake.rb) 仅提供 `--HEAD`/发布模板，不代表已有稳定 release。

## 使用

```text
lidgo                              创建默认 60 分钟 Timer，或显示当前状态
lidgo -r
lidgo --refresh                   刷新纯 Timer；存在 Hold 时拒绝
lidgo --hold                      前台维持，Ctrl-C 后释放
lidgo switch -f
lidgo switch --force              强制反转全局状态
lidgo config                      显示配置
lidgo config --duration 1h30m     设置未来 Timer 的默认时长
lidgo config --battery 15         设置低电量安全阈值
lidgo setup                       安装或修复权限与 LaunchAgent
lidgo help                        显示精简帮助
```

默认命令是幂等的：已有 Timer 时只显示 deadline，不会悄悄刷新。Timer 与多个 Hold 可以并存；最后一个有效 Lease 消失时才恢复正常睡眠。

## 安全模型

- 不保存、加密保存或自动输入管理员密码，也不使用 Keychain 存储认证材料。
- sudoers 只允许 `/usr/bin/pmset -a disablesleep 1` 与 `/usr/bin/pmset -a disablesleep 0` 两条完整命令；安装前必须通过 `visudo -cf`。
- 普通运行只调用 `sudo -n`，全局 `/var/db/maclidawake.lock` 固定为 `0660 root:admin` 并以 `O_NOFOLLOW` 打开。
- 电量小于等于配置阈值、电池不可读或 thermal pressure 达到 critical 时，所有 Lease 被清除并推进 generation；条件恢复后不会自动重新开启。
- Hold 同时验证 PID、进程启动身份与运行状态；Ctrl-Z/SIGSTOP 不会留下无限期 Lease，force 或安全熔断后的旧 Hold 不能抢回。

更完整的权限边界和失败恢复见[架构与安全设计](docs/architecture-and-security.md)。

## 项目结构

```text
Sources/LidGoCore/       Lease、状态存储、安全监控和 macOS 适配器
Sources/lidgo/           CLI 与内部 agent/root setup 入口
tests/LidGoCoreTests/    零依赖 Swift 单元测试 harness
tests/run_tests.sh       隔离的无 sudo 命令级验收
scripts/build.sh         Release 构建入口
completions/_lidgo       zsh completion
Formula/                 Homebrew 发布模板
docs/                    产品、架构、安全、测试和验收记录
```

## 开发与测试

```bash
swift run LidGoCoreTests
swift build --product lidgo
bash tests/run_tests.sh
swift build -c release -Xswiftc -warnings-as-errors
```

自动测试使用临时 Application Support、fake 安全读数与 fake 电源适配器，不调用真实 sudo/pmset。物理合盖、真实低电量与 thermal 条件仍需按[测试与验收说明](docs/testing.md)人工验证。

## 重要文档索引

| 内容 | 文件 |
| --- | --- |
| 已确认的产品与 CLI 契约 | [docs/product-spec.md](docs/product-spec.md) |
| 架构、安全边界与异常恢复 | [docs/architecture-and-security.md](docs/architecture-and-security.md) |
| 自动化与真实硬件验收 | [docs/testing.md](docs/testing.md) |
| 当前阶段进展与风险 | [CLAUDE.md](CLAUDE.md) |
| 长期协作与开发规范 | [AGENTS.md](AGENTS.md) |

## 已知限制

- `SleepDisabled` 是系统全局布尔值，没有所有者信息；LidGo 的 fail-safe 清理可能覆盖其他工具或手工设置的同一值。
- LaunchAgent 只在登录用户会话内监督；开机到登录前不承诺主动恢复。
- 真实合盖效果受具体 MacBook、macOS 版本和硬件状态影响，发布前必须完成物理机抽查。

## License 与上游归属

项目基于 [ecc521/keepawake](https://github.com/ecc521/keepawake) 改造，复用了其精确 sudoers、`pmset` 与内核参与锁安全思路。继续遵守上游 MIT License，并保留 Tucker Willenborg 的版权声明。详见 [LICENSE](LICENSE)。
