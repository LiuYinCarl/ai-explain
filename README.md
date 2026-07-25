# kimi-explain.el

在 Emacs 里选中代码，一键让 AI CLI（kimi / pi）用中文解释，并在专用 buffer 中实时展示回答、持续追问。

## 特性

- **选中即解释**：`C-c k e` 把选中的代码连同文件名、语言、行号一起发给 AI，prompt 要求"先概括、按主流程讲解、控制篇幅不发散"
- **持续追问**：所有提问在同一个会话中进行，上下文不丢。可以选中另一段代码再按 `C-c k e`，或按 `a` 直接输入问题
- **可插拔后端**：内置 kimi 和 pi 两个 CLI 后端，通过统一的 plist 接口抽象；新增一个后端只需写两个函数
- **实时反馈**：等待时显示旋转动画（`⠋ 思考中…`）；pi 后端为逐 token 流式输出
- **markdown 渲染**：对话 buffer 默认使用 markdown-mode（只读），标题和代码块有语法高亮
- **零账号处理**：登录、鉴权完全由 CLI 自己负责，插件不碰任何 token

## 依赖

- Emacs 27+（推荐 29+）
- 以下任一 CLI，且已在终端登录可用：
  - [kimi CLI](https://www.kimi.com/code/docs/)（默认后端）
  - pi CLI
- 可选：`markdown-mode`（装了就用，没装自动回退 special-mode）

## 安装

把 `kimi-explain.el` 放到任意目录（比如 `~/dev/github/kimi-explain/`），然后在 init 文件中：

```elisp
(use-package kimi-explain
  :ensure nil
  :load-path "~/dev/github/kimi-explain"
  :init
  (which-key-add-key-based-replacements   ; 可选，需要 which-key
    "C-c k"   "kimi-explain"
    "C-c k e" "解释选中代码"
    "C-c k a" "追问")
  :bind (("C-c k e" . kimi-explain-region)
         ("C-c k a" . kimi-ask)))
```

不用 use-package 的话：

```elisp
(add-to-list 'load-path "~/dev/github/kimi-explain")
(require 'kimi-explain)
(global-set-key (kbd "C-c k e") #'kimi-explain-region)
(global-set-key (kbd "C-c k a") #'kimi-ask)
```

## 用法

### 日常流程

1. 在代码 buffer 中**选中一段代码**，按 `C-c k e`
2. `*ai-explain*` buffer 弹出，先显示 `⠋ 思考中…` 动画，回答随后流入
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
| `kimi-explain-region` | 解释选中区域 |
| `kimi-ask` | 自由提问（续接当前会话） |
| `kimi-explain-stop` | 停止当前回复 |
| `kimi-explain-new-session` | 开启新会话 |
| `kimi-explain-switch-backend` | 交互式切换后端 |

## 配置项

```elisp
;; 默认后端（内置 kimi、pi 两个）
(setq kimi-explain-backend 'pi)

;; 对话 buffer 名字
(setq kimi-explain-buffer-name "*ai-explain*")

;; 设为 nil 则不使用 markdown-mode（回退 special-mode）
(setq kimi-explain-use-markdown-mode nil)

;; 解释代码用的 prompt 模板，6 个 % 依次是：
;; 文件路径、语言、起始行、结束行、代码块语言标识、代码内容
(setq kimi-explain-prompt-template "请用中文解释以下代码……")
```

## 设计

### 整体架构

```
Emacs                          CLI 进程
─────                          ────────
kimi-explain-region / kimi-ask
  └─ 构造 prompt（文件、语言、行号、代码）
  └─ kimi-explain--send
       ├─ 启动 spinner 动画
       └─ make-process: kimi -p … / pi -p …
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

插件并不常驻一个 CLI 进程，而是利用 CLI 自带的会话持久化：

- **kimi**：每次 `kimi -p` 的 stream-json 输出末尾有一条 meta 行携带 `session_id`，插件捕获后，下次提问用 `kimi --session <id> -p …` 续接
- **pi**：支持 `--session-id <id>` 指定会话（不存在则自动创建），插件自己生成 `emacs-<时间戳>-<随机数>` 作为 id

因此每次提问都是"新进程 + 旧会话"，效果等同于实例不关闭，还避开了在 Emacs 里驱动交互式 TUI 的复杂度。会话上下文由 CLI 端持久化，即使关掉 Emacs，会话文件仍保留。

### 后端抽象

每个后端是 `kimi-explain-backends` 里的一个 plist：

```elisp
(名字 :command    "可执行文件路径"
      :build-args  (lambda (prompt) …)   ; 在 *ai-explain* buffer 中调用，返回完整参数列表
      :handle-line (lambda (line) …))    ; 处理一行 stdout：插入正文、捕获 session id
```

内置实现：

| 后端 | 命令行 | 输出解析 |
|------|--------|----------|
| `kimi` | `kimi [--session id] -p PROMPT --output-format stream-json` | 每行一个 JSON；`role=assistant` 取 `content`，`type=session.resume_hint` 取 `session_id` |
| `pi` | `pi --session-id ID -p PROMPT --mode json` | JSON 事件流；`message_update/text_delta` 取增量（真流式），`message_end` 换行 |

### 添加自己的后端

以假想的 `foo` CLI 为例（支持 `foo chat --resume <id> "prompt"`，纯文本输出）：

```elisp
(defun my-foo-build-args (prompt)
  (append (when kimi-explain--session-id
            (list "--resume" kimi-explain--session-id))
          (list "chat" prompt)))

(defun my-foo-handle-line (line)
  (kimi-explain--insert (concat line "\n")))

(add-to-list 'kimi-explain-backends
             `(foo :command "foo"
                   :build-args ,#'my-foo-build-args
                   :handle-line ,#'my-foo-handle-line))

(setq kimi-explain-backend 'foo)
```

不支持会话续接的 CLI 也可以接：`:build-args` 忽略 session id 即可，只是每次提问都没有上下文。

### 等待动画

发送请求后在 buffer 末尾插入 `⠋ 思考中…`（braille 十帧，0.1s 一换）。第一个内容到达、进程结束、用户中断或 buffer 被关闭时都会自动清理，不会残留。

### 已知限制

- **kimi 后端不是流式**：kimi 的 stream-json 在回答完成时才发完整消息，等待期间只有 spinner（这是 CLI 本身的输出格式限制）
- **CLI 拥有工具权限**：`kimi -p` 默认 auto 权限、pi 默认带工具，解释代码时它们可能会读取你的项目文件（通常是优点——能结合上下文；不想要可在 `:build-args` 里给 pi 加 `--no-tools`）
- 同一时刻一个会话只能有一个进行中的请求，回复未完成时再提问会被拒绝并提示

## 文件

```
kimi-explain/
├── kimi-explain.el    ; 全部代码（单文件，约 430 行）
└── README.md
```
