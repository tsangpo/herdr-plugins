# IME Keeper 远程 pane 与 LazyVim 模式输入法同步交接文档

本文交给接手实现的开发者或编码代理。任务是在保持官方 Herdr 的前提下，扩展现有 ime-keeper，同时实现远程 pane 输入法记忆和 LazyVim 模式同步：Normal 使用 ABC，Insert 恢复上次编辑时的输入法。Normal 下打开 which-key 时也应使用 ABC。

当前已完成源码调查及 Ubuntu API 的只读验证，尚未修改插件代码、安装组件或完成 Mac 实机验证。本文是实施交接，不是修复完成报告。

## 用户环境与已确定的选择

- Mac 使用 macOS 26、系统拼音和 ABC，终端为 Ghostty。
- 用户通过 Herdr remote 连接 Ubuntu，在 Ubuntu 使用 LazyVim。
- Mac 已安装 `tsangpo/herdr-plugins` 仓库中的 `ime-keeper`。
- 用户要求保持官方 Herdr，不维护 Herdr 补丁。
- 用户接受将连接入口改为 `ime-keeper remote <SSH目标>`：连接期间同步输入法，退出时一起停止。
- 用户表示可以在 Ubuntu 安装插件，但选定方案无需这样做；现有 Ubuntu Herdr API 已能提供焦点事件。
- 本次交接同时包含远程 pane 切换与 LazyVim Normal/Insert 模式同步，两者均需完成和验收。先实现 pane 基础，再接入模式状态，但不能只完成前者就标记整体完成。
- 第一版支持多个远程 pane，其中绑定一个启用了模式同步的 Neovim 实例；其他 pane 保留原有输入法记忆。

工作应位于 `/home/tsangpo/workspace/tsangpo/herdr-plugins/ime-keeper`，Lua 集成源码也随此插件仓库维护。Ubuntu 的实际 LazyVim 配置位于 `/home/tsangpo/.config/nvim`。

## 已确认的事实与根因判断

### 插件当前只处理服务端事件

插件 manifest 声明 `platforms = ["macos"]`，启动时调用 `focus`，监听 `pane.focused`、`pane.closed`、`pane.moved`、`tab.closed` 和 `workspace.closed`。

插件通过 `HERDR_SOCKET_PATH` 对应的 Herdr 查询当前 pane 和前台进程。输入法切换使用 Carbon TIS；状态、会话锁和全局输入法切换锁已经存在。

Herdr 的插件 hook 在对应服务端执行。Ubuntu 的远程 pane 焦点变化不会自动执行 Mac 安装的插件。结合用户报告，这是当前不触发切换的源码层面解释；尚未读取 Mac 插件日志做端到端复现。

不能通过给现有规则增加 `nvim` 来补齐事件通道，也不能把 macOS Swift 可执行文件直接搬到 Ubuntu。

### Ubuntu API 已做只读验证

当前 Ubuntu 服务端报告版本 `0.9.3`、协议 `22`；CLI 报告版本 `0.9.0`。无需为本任务重启或升级服务。

API socket 为：

```text
/home/tsangpo/.config/herdr/herdr.sock
```

已连接该 socket 发送以下请求，服务返回 `subscription_started`：

```json
{
  "id": "ime-plan-events",
  "method": "events.subscribe",
  "params": {
    "subscriptions": [
      { "type": "pane.focused" },
      { "type": "pane.closed" },
      { "type": "pane.moved" },
      { "type": "tab.closed" },
      { "type": "workspace.closed" }
    ]
  }
}
```

另已验证 `pane.current` 返回有效当前 pane。验证后连接已关闭；没有主动切换 pane，也没有测试 SSH 转发或 Mac 输入法。

### 官方接口的限制

- 插件 manifest 没有通用 OSC 回调，不能仅添加一个 OSC 监听项完成此功能。
- `events.subscribe` 的能力比插件 manifest 事件 hook 更广；订阅公开 API 是本方案的接入点。
- `pane.focused` 不携带操作客户端身份。多个客户端同时操作同一远程会话时，不能据此可靠判断某一 Mac 的独立焦点。
- Herdr 的私有远程 TUI socket 不是本方案的公开 JSON API socket，不应混用。

## 选定的实现方案

新增入口：

```sh
ime-keeper remote <ssh-target> [--session <name>]
```

数据流如下：

```text
Mac ime-keeper 包装进程
  ├─ 启动官方 herdr --remote，保留交互终端
  ├─ 管理 SSH 本地 Unix socket 转发
  │    └─ 订阅 Ubuntu Herdr 公开 API
  │         └─ 焦点事件 → Mac 保存和恢复 pane 输入法
  └─ 接收经同一 SSH 连接反向转发的模式通知
       └─ Ubuntu LazyVim Lua 模块 → Mac 按当前 pane 和 Vim 模式同步
```

### 连接与生命周期

1. 复用用户的 SSH 配置与认证方式，明确选定远程主机和会话。通过远端 Herdr 状态查询发现公开 API socket，允许显式指定远端 Herdr 路径；不要把上面的机器路径写死为通用默认值。
2. 使用系统 OpenSSH 将远端 API Unix socket 转发到 Mac 的私有临时目录，并为 LazyVim 模式消息增加反向 Unix socket 转发。两条转发由同一个辅助 SSH 连接管理。无需暴露 TCP 服务、开启 Mac 远程登录或在 Ubuntu 安装常驻服务；Ubuntu 只增加 Lua 模块。
3. 先建立事件订阅并收到确认，再通过独立 API 连接读取当前状态。事件用于触发重新查询，不能把旧事件无条件覆盖到新快照上。
4. 启动官方 `herdr --remote` 并保留其终端输入输出。包装进程自行运行监听逻辑，不使用插件 startup hook 假装托管常驻服务，不安装 LaunchAgent。
5. 包装进程退出或收到终止信号时，停止它创建的 SSH 转发与监听，清理其临时 socket。不能停止远程 Herdr 服务或杀死其他连接。
6. 监听或转发失败时暂停输入法控制，记录错误并退避重连；不因为辅助功能失败而终止可正常使用的 Herdr 连接。

### 焦点与输入法恢复

- 收到有效焦点事件立即采集离开 pane 时的输入源；沿用现有 100ms 稳定窗口、会话焦点锁和全局切换锁。
- 稳定窗口结束后重新查询远程当前 pane，验证它仍是目标，再执行恢复。快速连续切换只应作用于最终有效目标。
- 普通 pane 保留优先级：已保存的 pane 输入源 → 第一个匹配的命令规则 → 保持当前输入源。绑定 Neovim 的 pane 先按下文的模式规则处理，不能被通用 pane 恢复逻辑覆盖。
- 前台进程信息必须从远程查询，不能误查 Mac 的本地 pane。规则仍按进程名或 `argv0` basename 区分大小写、按数组顺序匹配。
- 手动切换输入法应在离开 pane 时成为新的记忆。
- Mac 长期运行的监听逻辑应维持主线程事件循环，避免 TIS 读取到过期输入源。验证实际拼音输入，不能仅验证菜单栏图标。
- Ghostty 不在前台时暂停输入法切换；回到前台后重新查询和同步。其他 Mac 应用中的输入法变化不能误记为远程 pane 的选择。

### LazyVim 模式通知通道

这部分是新增设计，尚未实现或端到端验证。不能把 Herdr 的焦点事件当成 Vim 模式事件，也不通过 OSC 52、剪贴板、标题或屏幕文本推断模式。

- 在仓库中提供独立 Lua 模块及 LazyVim 加载示例，默认仅在 `NVIM_IME=1 nvim` 且存在 Herdr pane 上下文时启用。
- Lua 监听 `ModeChanged`，用 Neovim 的实际模式分类，覆盖 `Esc`、`Ctrl-C`、`i/a/o`、`Ctrl-O`、映射及程序触发的模式切换。不改写 which-key 或空格映射。
- 包装进程在 Mac 建立专用模式接收 socket，通过 SSH `-R` 映射到 Ubuntu 用户私有状态目录。默认远端路径为 `${XDG_STATE_HOME:-$HOME/.local/state}/ime-keeper/nvim.sock`，父目录权限为 0700；允许 Lua `setup({ socket_path = ... })` 显式覆盖。包装命令打印实际路径和配置示例。
- 默认只允许一个受控远程连接使用该端点；已被占用时明确报错，不删除其他进程的 socket。Lua 校验 `HERDR_SOCKET_PATH` 对应的会话，不能误连到另一会话的接收器。
- Lua 使用异步 Unix socket，发送有大小上限的逐行 JSON。消息包含协议版本、随机 Neovim 实例 ID、进程 PID、Herdr socket、pane ID、递增序号、消息类型及当前模式；类型为 `attach`、`mode`、`detach`。回包包含序号及接受或失败结果。
- 接收端仅接受模式状态，不提供任意命令执行接口；校验会话、pane、已绑定实例和消息顺序。第二个 Neovim 实例拒绝接管，不影响其正常编辑。
- 启动、重连时重新发送 `attach` 与当前模式；退出时通过 `VimLeavePre` 尽力发送 `detach`。连接断开时停止应用模式状态，丢弃待发的旧消息，重连后以当前模式为准。故障不能阻塞编辑器或不断弹出通知。
- 启动包装命令时，已运行的 Herdr 服务及 pane 不会自动继承新环境变量。因此 Lua 从约定状态路径或显式配置找 socket，不依赖给 Mac 包装进程设置环境变量来传播路径。

### Vim 模式与输入法记忆

模式状态和 pane 输入法记忆分开存储；每个绑定实例单独保存 `insertInputSourceID`、最近模式及实例身份，不按 buffer 保存。

| 状态或操作 | 预期行为 |
| --- | --- |
| 首次绑定且该 pane 当前可见并受控 | 先记录当前输入法，再按实际模式同步；后台绑定不能采集另一个 pane 的输入法。 |
| 进入 Normal | 若刚离开 Insert 或 Replace，保存当前编辑输入法，然后切到 `com.apple.keylayout.ABC`。 |
| 进入 Insert 或 Replace | 恢复 `insertInputSourceID`；首次未建立编辑记忆时，使用该 pane 的正常恢复结果作为初始值。 |
| Visual、操作等待、命令行模式 | 使用 ABC，不覆盖编辑输入法记忆。 |
| Normal 内再次触发模式事件或打开 which-key | 维持 ABC，不把 ABC 写成新的编辑输入法。 |
| Insert 内手动选择 ABC 或拼音 | 下次离开编辑状态或离开 pane 时保存该选择，后续 Insert 恢复它。 |
| `Ctrl-O` 临时进入 Normal | 暂存当前编辑输入法并切 ABC，返回 Insert 后恢复，不丢失拼音记忆。 |
| 离开绑定的 pane | 若处于 Insert 或 Replace，保存编辑输入法；若处于 Normal，不用自动设置的 ABC 覆盖编辑记忆。 |
| 返回绑定的 pane | 根据最新模式决定 ABC 或编辑记忆；通用 pane 恢复不能在其后再次切回错误输入源。 |
| Neovim 正常退出 | 清除模式接管；若仍在受控 pane，且输入源仍是工具设置的值，恢复编辑记忆并交回通用 pane 逻辑。 |

模式判定优先于该 pane 的通用恢复，但命令规则仍只在焦点进入时评估，不在每次模式变化时运行。后台 pane 的消息只能更新模式缓存，不能切换 Mac 输入法，也不能从当前 Mac 输入法推断后台编辑器的记忆。

焦点和模式事件共用一个串行协调器与全局输入法切换锁。对模式消息不额外套用 pane 焦点的 100ms 去抖；已有焦点处理未完成时先保存其离开输入源，再重新查询当前 pane 并应用最新有效模式。模式序号只解决同一实例的顺序，不能当作 Herdr 焦点事件的全局顺序。

pane 移动后旧 ID 可能失效，需依据 Herdr 的移动事件迁移绑定，并让 Lua 在重新连接时重新解析当前 pane；关闭、进程结束、切换到终端子任务或实例失效时释放模式接管。失效期间不得仅凭旧 Normal 状态持续强制 ABC。

网络和 macOS 输入法激活存在延迟，不承诺零延迟。验收时需要连续切换后立即输入，记录首字符是否被旧输入法处理；若出现问题，先修复串行处理或 macOS 输入源激活流程，不能仅以图标变化作为成功依据。

### 状态与并发

- 现有本地状态和规则保持兼容。远程命名空间纳入 SSH 目标、会话与远端 socket，避免不同机器出现相同 pane ID 时串用记忆。
- 继续把配置写入插件配置目录、运行状态写入插件状态目录，原子保存；损坏的配置或状态只报错，不覆盖。
- pane 移动时迁移记忆；pane、tab、workspace 关闭时清理对应状态。
- 重连后重新订阅并读取快照，清理已消失的 pane。若不能确认远程服务实例连续性，清除不可信的旧 pane 记忆，避免重用 ID 导致错误恢复。
- 为受控远程连接增加所有权锁，重复启动时明确报错。已有本地 focus handler 与远程监听器需协调，不能交替覆盖输入法；仅有互斥锁不足以表示哪个上下文当前拥有控制权。
- `status` 增加远程目标、会话、连接状态、当前 pane、监听进程、绑定 Neovim 实例、最新模式、编辑输入法记忆、模式通道状态和最近错误，便于排查。

### 安装入口

当前插件依赖 Herdr 注入的环境变量，而用户从 shell 启动包装命令时未必具备这些变量。实现需要提供稳定的命令入口，并解析或注入与 Herdr 一致的插件配置和状态目录，不能要求用户手工补齐环境变量。

安装说明应同时覆盖 GitHub 安装与本地开发链接。原有 pane 记忆功能继续可用，不需要用户重写现有 `version: 1` 规则配置。

提供 Lua 模块安装到 LazyVim 的说明，保留用户已有 autocmd 和按键配置；示例说明如何显式启用、指定 socket、诊断连接以及停用。没有加载 Lua 模块的 pane 应继续正常使用原有 pane 输入法记忆。

## 仓库约束与建议修改位置

先读取目标仓库当前的 `ime-keeper/AGENTS.md`，不要依赖本交接中的副本摘要。现有约束包括：一个无第三方依赖的 SwiftPM 可执行文件；保持插件 ID `tsangpo.ime-keeper`；保留规则优先级、100ms 稳定窗口、锁及状态存储规则。

用户已经选择“随连接启动的监听桥接”。将其实现为有界生命周期的包装进程，无需独立后台服务；同步更新开发文档，清楚区分它与原有一次性事件 handler。

用户现已明确要求把 LazyVim 模式切换纳入同一实施任务。现有 AGENTS 中“保存 pane 优先”的规则继续适用于普通 pane；绑定编辑器增加模式优先级，并在实施时同步说明该扩展。保持输入法控制可执行文件仅运行在 macOS；新增的 Ubuntu Lua 模块不等于新增 Linux 版输入法插件。

建议按职责拆分：

- `Core.swift`：可测试的 pane 身份、远程状态及恢复决策。
- `main.swift`：保留 CLI 分发，抽取已有状态存储、输入法访问和 focus 处理供两条路径复用。
- 新增专用 Swift 文件实现公开 API 客户端、SSH 转发、模式消息接收和统一输入法协调器，避免继续堆大入口文件。
- 增加独立 Lua 集成模块及加载示例，随插件仓库维护，部署到 Ubuntu 的 LazyVim 配置。
- 更新测试、README 和必要的 manifest/安装入口。保持 macOS 可执行插件的平台限定；无需新增 Linux 插件实现。

不要修改 Herdr 核心、Ghostty 或 Freightcom 仓库，不发布或部署未经过 Mac 验收的构建。

## 验证和完成标准

### 自动化验证

在插件目录执行：

```sh
swift test
swift build -c release
```

保留现有规则顺序、basename、记忆优先级、手动覆盖、关闭/移动清理及损坏配置测试。新增以下有意义的覆盖：

- 本地与远程、不同主机与会话的状态隔离。
- JSON 分帧、订阅确认、查询错误及 `events_lost` 恢复。
- 快速焦点变化、事件和查询交错、过期响应不产生错误切换。
- 重复包装进程、SSH 子进程退出、清理仅作用于自己创建的资源。
- Ghostty 失焦期间不切换、不污染 pane 记忆。
- Normal/Insert/Replace/Visual/命令行分类；首次绑定、重复 Normal、`Ctrl-O`、编辑时手动切换 ABC 后的记忆行为。
- 模式 JSON 的分帧、超限、无效实例、过期序号、重连及第二实例拒绝。
- pane 焦点与模式事件交错、后台消息、pane 移动、Neovim 退出时的接管释放。
- 使用 headless Neovim 和伪造接收端验证 Lua 发送真实模式、连接失败不阻塞，以及重连只同步当前状态。此测试不替代 Mac 输入法验证。

### Mac 实机验收

1. 用包装命令连接当前 Ubuntu 官方 Herdr。
2. 在 pane A 选择 ABC，在 pane B 选择系统拼音；反复切换后分别恢复。
3. 在任一 pane 手动改变输入法，再离开返回，恢复新的选择。
4. 覆盖键盘、鼠标、跨 tab/workspace 切换，pane 移动与关闭。
5. 连续快速切换后只有最终目标生效；检查实际中文输入与候选框。
6. 切换到其他 Mac 应用，不应被远程事件改变输入法；回到 Ghostty 后重新同步。
7. 模拟辅助连接断开及重连，Herdr 交互不因监听故障终止。
8. 退出包装命令后没有遗留监听或 SSH 转发，Ubuntu Herdr 服务仍运行。
9. 重新连接并启用 LazyVim 模块：Insert 选择系统拼音，退出到 Normal 后自动 ABC，按空格打开 which-key 可直接输入快捷键，重新进入 Insert 恢复拼音。
10. 分别使用 `Esc`、`Ctrl-C`、`i/a/o`、`Ctrl-O`、映射、Replace、Visual 和命令行路径；重复 Normal 通知不覆盖拼音记忆。
11. 在 Insert 手动改为 ABC，下次 Insert 恢复 ABC；多个 buffer 共用该实例的编辑输入法记忆。
12. 在绑定 Neovim 与普通 pane 间切换，验证 pane 恢复和模式恢复不会互相覆盖；后台模式消息不改变当前 pane 的输入法。
13. 覆盖 Neovim 退出、绑定 pane 移动、模式通道断线重连和第二实例接入；失效状态不能持续控制 Mac 输入法。

只有以上 Mac 验收通过才能标记完成。当前环境只能验证 Ubuntu 端和部分纯逻辑，不能替代 macOS 实测。

## 接手时需要补充的环境事实

这些尚未从 Mac 获取，不应凭空假定：

- Mac Herdr 的实际版本、插件安装目录、已安装插件 revision，以及本地 Swift 工具链。
- 用户实际使用的 SSH 目标别名和 Herdr 会话名。
- SSH 本地与反向 Unix socket 转发是否均获准；当前仅验证了 Ubuntu 本机 API，没有验证转发链路或模式消息通道。
- Mac 是否还在另一个本地 Herdr pane 内运行 remote，以及现有本地 focus handler 是否会与包装进程竞争。

第一版按一个受控 Ghostty 窗口、一个远程连接、一个绑定 Neovim 实例验收，可以有多个普通远程 pane。LazyVim Normal/Insert 同步属于必做范围。同一会话多客户端独立焦点、多 Ghostty 窗口自动归属、多 Neovim 实例同时接管不在本次完成标准内。

## 源码依据

调查日期为 2026 年 9 月 30 日。交接时记录的分支 HEAD 如下；它们不代表用户 Mac 已安装的 revision。

- 插件仓库：`7ae12ec0c2009f383e5a186698cd71e8ae1544a7`。
- Herdr 上游：`331775c3e51e8cca4d122468180738101bd9e6b0`。上游源码调查与 Ubuntu 已运行版本应分别看待。

参考入口：

- [ime-keeper README](https://github.com/tsangpo/herdr-plugins/tree/main/ime-keeper)
- [插件开发约束](https://github.com/tsangpo/herdr-plugins/blob/main/ime-keeper/AGENTS.md)
- [插件 manifest](https://github.com/tsangpo/herdr-plugins/blob/main/ime-keeper/herdr-plugin.toml)
- [现有输入法与事件实现](https://github.com/tsangpo/herdr-plugins/blob/main/ime-keeper/Sources/ImeKeeper/main.swift)
- [Herdr 插件 hook 执行位置](https://github.com/herdrdev/herdr/blob/master/src/app/api/plugins/runtime.rs)
- [Herdr 事件定义及插件 hook 白名单](https://github.com/herdrdev/herdr/blob/master/src/api/schema/events.rs)
- [Herdr 公开 socket API](https://herdr.dev/docs/socket-api/)
