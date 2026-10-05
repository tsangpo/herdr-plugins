# IME Keeper 远程实现交接

本文件记录当前实现与验收边界，替代早期反向 socket 方案。用户已确定：本地 Neovim 保留直调 Swift，远程 Neovim 经 Herdr metadata 推送，两者共用事件格式和输入法策略。不要修改 Herdr。

## 已实现的路径

```text
本地 Neovim → local_transport → Swift editor-event → 公共编辑器策略 → macOS TIS
远程 Neovim → pane.report_metadata → pane.updated → SSH 本地转发
                                                     ↓
                         Mac ime-keeper remote → 公共编辑器策略 → macOS TIS
```

- 入口：`ime-keeper remote <ssh-target> [--session <name>] [--remote-herdr <path>]`。
- 包装进程启动官方 `herdr --remote`，辅助 SSH 转发远端公开 API socket；没有反向转发、独立模式 socket、远端 Swift 或系统常驻服务。
- 本地启动方式不变。Herdr 0.9.3 的公开 API 可以订阅 `pane.updated`，但插件 hook 白名单排除了它，所以不能仅添加 manifest hook 统一本地传输。
- 远端通过 LazyVim 的 `tsangpo/herdr-plugins` GitHub 配置安装相同 Lua runtime，用 `:Lazy sync` 安装、`:Lazy update ime-keeper` 更新，无需复制目录。在远端 Herdr pane 中直接运行 `nvim` 自动启用，`NVIM_IME=0 nvim` 可临时关闭；无需在 Ubuntu 安装 macOS Herdr 插件。
- 首版从 Ghostty 普通 shell 启动，拒绝本地 Herdr pane 内嵌套启动。一个受控远程终端、一个包装连接（可与其他标签页的本地 Herdr 共存）、同一远端会话一个交互客户端。支持多个 pane 各自运行一个 Neovim。

## 协议与策略

Lua 每次原子更新六个 `ime_keeper_*` tokens：`version`、`instance`、`pid`、`sequence`、`event`、`mode`。固定 source 为 `ime-keeper:nvim`，不使用 Herdr 的 source 级 `seq`，避免耗尽其有界序号来源表。实例序号由 Mac 验证。

Token 值不超过 80 字节。每秒更新一次五秒 TTL，心跳保持相同编辑器序号；Herdr 的 TTL 更新本身可能触发 `pane.updated`，不能假设值相同便不发事件。Lua 异步通信，错误进入 status，退避重试只发布最新状态。正常退出尽力发布 exit，异常退出由 TTL 和前台进程检查释放接管。

Normal、Visual、命令行等使用 ABC；Insert/Replace 恢复编辑输入法；退出或挂起恢复进入编辑器前的 shell 输入法。编辑与 shell 记忆分别保存，不用强制 ABC 覆盖它们。后台消息不采样或改变当前输入法。TTL 失效保留不生效的实例记忆，以便同一编辑器恢复通知时重新验证后使用。

远端前台校验不能使用 Mac PID。Neovim 可能把 TUI 与 Lua core 分成两个进程，需接受直接前台 PID，或远端系统查询验证的直接父子关系。

焦点保留 100ms 稳定窗口，模式无额外去抖。先订阅再取快照，应用前重新查询当前 pane 和 tokens，并检查事件代次。两秒健康检查用于发现失去前台控制权等状态变化。通过 Ghostty AppleScript 查询选中终端 ID；远程终端所在标签页或 split 未选中、Ghostty 失焦、查询失败期间不采样或切换，实际切换前再次确认终端。

## 生命周期与状态

- 配置和状态目录兼容原有插件环境与 Herdr 的 XDG 默认路径；Mac shell 入口不依赖本地 Herdr 正在运行。
- 包装进程只长期持有防重复启动的 remote-instance 锁；全局输入法锁只在实际操作时持有。本地 handler 根据选中终端避让远程，进程退出后的残留注册文件不阻塞本地。控制方交接时清除 applied policy 观察标记，保留已记录的输入法偏好。锁及 socket 描述符设置 close-on-exec。升级后须重启旧的 0.3.0 包装进程一次，以释放旧生命周期锁。
- pane 通过 terminal identity 迁移，关闭清理。远程状态命名空间包含 SSH 目标、会话和远端 socket。
- 辅助连接故障暂停控制并退避重连，不终止官方客户端。当前 API 缺少稳定的服务实例标识，所以每次辅助重连都保守地清空旧记忆，再从当前 metadata 建立状态。
- 损坏的配置或状态报错，不覆盖。诊断写入 `remote-status.json`，避免污染交互终端。`ime-keeper remote-status` 可在退出后读取。
- 退出只停止自己的客户端、SSH 和临时 socket，不停止远端服务。

## 验证记录与剩余验收

已验证本地原有模式测试、远程策略测试、Lua 真实 Unix socket 异步传输，以及独立 Herdr 服务中的 metadata 推送和 TTL 清理。

在 Ubuntu `/tmp` 下独立 XDG/命名会话验证了 SSH Unix socket 转发、两个真实 Neovim TUI 的 Normal/Insert/Ctrl-C 通知、TUI/core PID 关系、后台焦点保持及退出 TTL 清理。另通过带替代客户端的 PTY 测试运行实际 Swift 包装进程，验证模式缓存、辅助 SSH 断开与重连及退出清理。测试未操控用户工作会话；替代客户端测试不等于官方 TUI 与桌面输入法的完整验收。

仍需用户在真实 Ghostty 客户端中验证实际中文字符和候选框，特别是切换后立即输入的首字符。这不能由菜单栏图标、后台通知或 headless 测试代替。安装步骤和手工验收清单见 [README](ime-keeper/README.md#remote-neovim--lazyvim)。未自动部署到用户 LazyVim 配置或重新链接 manifest。

## 开发验证命令

在 `ime-keeper` 目录执行：

```sh
swift test
swift build -c release
NVIM_LOG_FILE=/tmp/ime-keeper-nvim-tests.log nvim --headless -u NONE -i NONE -l nvim/tests/integration.lua
NVIM_LOG_FILE=/tmp/ime-keeper-nvim-tests.log nvim --headless -u NONE -i NONE -l nvim/tests/remote.lua
IME_KEEPER_LIVE_TESTS=1 swift test
```

最后一项只启动/停止自己的临时命名 Herdr 服务。PTY 自动测试必须持续读取 master 输出，否则测试端可阻塞子进程退出。更多约束见 [AGENTS.md](ime-keeper/AGENTS.md)。
