# emacs-ai-explain.el

在 Emacs 里选中代码，一键让 AI CLI（kimi / pi）用中文解释，并在专用 buffer 中实时展示回答、持续追问。



https://github.com/user-attachments/assets/4342856e-86d5-404a-a6fa-fc8391af4d16



## 特性

- **选中即解释**：`C-c k e` 把选中的代码连同文件名、语言、行号一起发给 AI，prompt 要求"先概括、按主流程讲解、控制篇幅不发散"
- **持续追问**：所有提问在同一个会话中进行，上下文不丢。可以选中另一段代码再按 `C-c k e`，或按 `a` 直接输入问题
- **常驻进程**：kimi（ACP）和 pi（rpc）后端都走长连接，进程只启动一次，追问没有重复加载的开销；进程生命周期（启动、握手、掉线重启恢复）完全由插件管理
- **可插拔后端**：内置 kimi（ACP 常驻）、pi（rpc 常驻）、codex（一次性）及 kimi/pi 各自的 oneshot 保底后端，通过统一的 plist 接口抽象（ACP / 一次性 / 自定义常驻三种模式）；接入任何一个 ACP agent 只需一行声明
- **实时反馈**：等待时显示旋转动画（`⠋ 思考中…`），回答逐 token 流式输出
- **markdown 渲染**：对话 buffer 默认使用 markdown-mode（只读），标题和代码块有语法高亮
- **后端可见**：`*ai-explain*` 的 mode-line 常驻显示当前后端（回复中时显示 `[kimi:回复中]`），提问时 minibuffer 也会提示一次
- **零账号处理**：登录、鉴权完全由 CLI 自己负责，插件不碰任何 token

## 依赖

- Emacs 27+（推荐 29+）
- 以下任一 CLI，且已在终端登录可用：
  - [kimi CLI](https://www.kimi.com/code/docs/)（默认后端，使用 `kimi acp` 常驻模式）
  - pi CLI（使用 `--mode rpc` 常驻模式）
  - codex CLI（使用 `codex exec --json` 一次性模式，追问走 `codex exec resume` 续接会话）
- 可选：`markdown-mode`（装了就用，没装自动回退 special-mode）

## 安装

把 `emacs-ai-explain.el` 放到任意目录（比如 `~/dev/github/emacs-ai-explain/`），然后在 init 文件中：

```elisp
(use-package emacs-ai-explain
  :ensure nil
  :load-path "~/dev/github/emacs-ai-explain"
  :init
  (which-key-add-key-based-replacements   ; 可选，需要 which-key
    "C-c k"   "emacs-ai-explain"
    "C-c k e" "解释选中代码"
    "C-c k a" "追问")
  :bind (("C-c k e" . emacs-ai-explain-region)
         ("C-c k a" . emacs-ai-explain-ask)))
```

不用 use-package 的话：

```elisp
(add-to-list 'load-path "~/dev/github/emacs-ai-explain")
(require 'emacs-ai-explain)
(global-set-key (kbd "C-c k e") #'emacs-ai-explain-region)
(global-set-key (kbd "C-c k a") #'emacs-ai-explain-ask)
```

## 用法

### 日常流程

1. 在代码 buffer 中**选中一段代码**，按 `C-c k e`
2. `*ai-explain*` buffer 弹出，先显示 `⠋ 思考中…` 动画，回答随后逐字流入
3. 追问方式任选：
   - 再选中别的代码按 `C-c k e`（自动带上新代码的上下文）
   - 在 `*ai-explain*` buffer 中按 `a` 直接输入问题
   - 在任意 buffer 按 `C-c k a`

### `*ai-explain*` buffer 按键

| 按键 | 作用 |
|------|------|
| `a` / `A` | 追问（minibuffer 输入） |
| `s` | 停止当前正在进行的回复 |
| `n` | 丢弃上下文，开启新会话 |
| `b` | 切换后端（kimi / pi / 自定义），并开新会话 |
| `q` | 关闭窗口 |
| `?` | 查看全部按键说明 |

buffer 是只读的，这些单字母键不会干扰任何文本输入；提问在 minibuffer 中完成。

### 命令一览

| 命令 | 作用 |
|------|------|
| `emacs-ai-explain-region` | 解释选中区域 |
| `emacs-ai-explain-ask` | 自由提问（续接当前会话） |
| `emacs-ai-explain-stop` | 停止当前回复 |
| `emacs-ai-explain-new-session` | 开启新会话 |
| `emacs-ai-explain-switch-backend` | 交互式切换后端 |

## 配置项

```elisp
;; 默认后端（内置 kimi、kimi-oneshot、pi、pi-oneshot、codex 五个）
(setq emacs-ai-explain-backend 'pi)

;; 对话 buffer 名字
(setq emacs-ai-explain-buffer-name "*ai-explain*")

;; 设为 nil 则不使用 markdown-mode（回退 special-mode）
(setq emacs-ai-explain-use-markdown-mode nil)

;; 解释代码用的 prompt 模板，6 个 % 依次是：
;; 文件路径、语言、起始行、结束行、代码块语言标识、代码内容
(setq emacs-ai-explain-prompt-template "请用中文解释以下代码……")
```

## 设计

### 整体架构

```
Emacs                          CLI 进程
─────                          ────────
emacs-ai-explain-region / emacs-ai-explain-ask
  └─ 构造 prompt（文件、语言、行号、代码）
  └─ emacs-ai-explain--send
       ├─ 启动 spinner 动画
       ├─ 常驻模式: 复用长驻进程（首次自动启动+握手）
       └─ 一次性模式: make-process: pi -p …
              │ stdout 逐行到达
              ▼
       process filter（按完整行切分，残留行留到下次）
              │
              ▼
       后端 :handle-line（解析 JSON，提取正文/session id）
              │
              ▼
       插入 *ai-explain* buffer（停 spinner、滚动到底部）
```

### 会话如何"不关闭"

两个默认后端各用一种常驻协议，掉线恢复策略相同（保存 session id，重启后续接）：

- **kimi（ACP 常驻模式）**：`kimi acp` 把 CLI 变成一个 ACP（Agent Client Protocol）进程——stdin/stdout 上的 JSON-RPC 长连接，消息为 ndjson（每行一个 JSON）。进程只启动一次，握手（`initialize` → `session/new` → `session/set_mode auto`）后会话保持在进程内，追问只是多发一个 `session/prompt` 请求。进程被杀或意外退出也不用慌：插件保存着 session id，下次提问自动重启进程，并用 `session/resume` 恢复上下文（对端是否支持 resume 由 `initialize` 返回的能力声明决定，不支持则自动退化为新会话）
- **pi（rpc 常驻模式）**：`pi --mode rpc` 是 pi 自己的 stdin/stdout JSON 行协议——写一行 `{"type":"prompt",...}` 提问，`message_update/text_delta` 流式到达，`agent_settled` 标志一轮结束；协议无需握手，进程起来就能收命令。启动时用 `--session-id <id>` 固定会话（插件生成 `emacs-<时间戳>-<随机数>`），进程被杀或意外退出后用同一 id 重启即可恢复上下文。额外福利：`{"type":"abort"}` 支持优雅中断，按 `s` 停止不必杀进程

两种模式下关掉 Emacs 会话文件都保留在 CLI 侧，不会丢。

### 后端抽象

每个后端是 `emacs-ai-explain-backends` 里的一个 plist，支持三种声明方式：

```elisp
;; 1. ACP 模式：任何实现了 Agent Client Protocol 的 agent，一行接入
(名字 :command   "可执行文件路径"
      :acp       t
      :arguments ("acp")        ; 启动 ACP 模式的参数
      :acp-mode  "auto")        ; 可选：建会话后用 session/set_mode 切换的模式

;; 2. 一次性模式：每次提问新起一个进程
(名字 :command    "可执行文件路径"
      :build-args  (lambda (prompt) …)   ; 在 *ai-explain* buffer 中调用，返回完整参数列表
      :handle-line (lambda (line) …))    ; 处理一行 stdout：插入正文、捕获 session id

;; 3. 自定义常驻模式：进程长驻、反复复用（ACP 模式就是用它实现的）
(名字 :command        "可执行文件路径"
      :persistent     t
      :ensure-process (lambda () …)          ; 返回长驻进程（可异步握手，未就绪时 send-prompt 自行排队）
      :send-prompt    (lambda (proc prompt) …)
      :handle-line    (lambda (line) …)      ; 一轮回复结束（含出错）时调用 emacs-ai-explain--turn-done
      :cancel         (lambda (proc) …))     ; 可选：中断当前回复但不杀进程（如 pi 的 abort）
```

ACP（[Agent Client Protocol](https://agentclientprotocol.com)）是编辑器与 AI agent 之间的开放协议，地位类似 LSP 之于语言服务器；kimi、Claude Code、Gemini CLI、Codex、OpenCode 等主流 agent 都已支持。声明 `:acp t` 的后端不需要写任何回调——进程启动、`initialize` 握手、建会话、问题排队、掉线重启与 `session/resume` 恢复上下文全部由插件内置的通用 ACP 适配器完成。

内置实现：

| 后端 | 模式 | 命令 / 协议 | 输出解析 |
|------|------|-------------|----------|
| `kimi` | ACP 常驻 | `kimi acp`（ACP JSON-RPC over stdin/stdout） | ndjson 消息流；`session/update` 的 `agent_message_chunk` 取增量（真流式），握手时捕获 `sessionId` |
| `kimi-oneshot` | 一次性（保底） | `kimi [--session id] -p PROMPT --output-format stream-json` | 每行一个 JSON；`role=assistant` 取 `content`，`type=session.resume_hint` 取 `session_id` |
| `pi` | rpc 常驻 | `pi --mode rpc --session-id ID`（pi 私有 JSON 行协议） | `message_update/text_delta` 取增量（真流式），`agent_settled` 结束一轮；`abort` 支持优雅停止 |
| `pi-oneshot` | 一次性（保底） | `pi --session-id ID -p PROMPT --mode json` | JSON 事件流；`message_update/text_delta` 取增量，`message_end` 换行 |
| `codex` | 一次性 | `codex exec [--skip-git-repo-check] --json PROMPT` / 追问走 `codex exec resume --json ID PROMPT` | JSONL 事件流；`thread.started` 取 `thread_id`，`item.completed` 的 `agent_message` 取正文（非流式） |

`kimi-oneshot` / `pi-oneshot` 是常驻模式之前的旧机制，保留作保底：常驻模式出问题时 `(setq emacs-ai-explain-backend 'kimi-oneshot)`（或 `'pi-oneshot`）、按 `b` 切换即可，代价是每次提问都要重启进程；kimi 一次性后端的回答还非流式。

### 添加自己的后端

如果 CLI 支持 ACP，一行声明即可：

```elisp
(add-to-list 'emacs-ai-explain-backends
             '(gemini :command "gemini" :acp t :arguments ("--acp")))

(setq emacs-ai-explain-backend 'gemini)
```

（各 agent 启动 ACP 模式的参数不同，以其官方文档为准。）

不支持 ACP 的 CLI 用一次性模式，以假想的 `foo` 为例（支持 `foo chat --resume <id> "prompt"`，纯文本输出）：

```elisp
(defun my-foo-build-args (prompt)
  (append (when emacs-ai-explain--session-id
            (list "--resume" emacs-ai-explain--session-id))
          (list "chat" prompt)))

(defun my-foo-handle-line (line)
  (emacs-ai-explain--insert (concat line "\n")))

(add-to-list 'emacs-ai-explain-backends
             `(foo :command "foo"
                   :build-args ,#'my-foo-build-args
                   :handle-line ,#'my-foo-handle-line))

(setq emacs-ai-explain-backend 'foo)
```

不支持会话续接的 CLI 也可以接：`:build-args` 忽略 session id 即可，只是每次提问都没有上下文。

### 等待动画

发送请求后在 buffer 末尾插入 `⠋ 思考中…`（braille 十帧，0.1s 一换）。第一个内容到达、一轮回复结束、进程退出、用户中断或 buffer 被关闭时都会自动清理，不会残留。

### 已知限制

- **CLI 拥有工具权限**：kimi ACP 会话被切到 auto 权限模式、pi 默认带工具，解释代码时它们可能会读取你的项目文件（通常是优点——能结合上下文；不想要可在 `:build-args` 里给 pi-oneshot 加 `--no-tools`）
- 同一时刻一个会话只能有一个进行中的请求，回复未完成时再提问会被拒绝并提示
- 按 `s` 停止的实现因后端而异：pi 用 `abort` 优雅中断（进程、会话都保留，中断迟迟不生效时再按一次 `s` 杀进程兜底）；kimi ACP 未实现 `session/cancel`，只能杀进程，session id 已保留，下次提问自动重启并恢复上下文，代价是多一次进程启动
- ACP 握手有 15 秒看门狗：对端无响应时判定失败并提示（常见原因是 CLI 未登录）
- 关闭 `*ai-explain*` buffer 会同时结束后端进程，重开后是新会话（会话状态是 buffer-local 的）

## 文件

```
emacs-ai-explain/
├── emacs-ai-explain.el    ; 全部代码（单文件，约 900 行）
└── README.md
```
