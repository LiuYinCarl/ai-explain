;;; kimi-explain.el --- 用 AI CLI (kimi / pi / codex) 解释代码并持续追问 -*- lexical-binding: t; -*-

;; 依赖: 本机已安装并登录 kimi CLI (https://www.kimi.com/code/docs/)
;;       或 pi CLI。账号验证由 CLI 自己负责，本插件不参与。
;;
;; 用法:
;;   选中一段代码后  M-x kimi-explain-region   用中文解释选中的代码
;;                   M-x kimi-ask              直接输入问题追问（同一会话）
;;   在 *ai-explain* buffer 中: a/A 追问, s 停止回复, n 开启新会话, b 切换后端, q 关闭窗口, ? 按键帮助
;;
;; 切换后端:
;;   (setq kimi-explain-backend 'pi)   ; 默认 'kimi
;;
;; 建议绑定快捷键:
;;   (global-set-key (kbd "C-c k e") #'kimi-explain-region)
;;   (global-set-key (kbd "C-c k a") #'kimi-ask)

;;; Code:

(require 'json)
(require 'subr-x)

(defgroup kimi-explain nil
  "Ask an AI CLI to explain code."
  :group 'tools)

(defcustom kimi-explain-backend 'kimi
  "使用的后端 CLI.
内置 `kimi'（ACP 常驻）、`pi'（rpc 常驻）、`codex'（一次性）三个默认后端，
以及 `kimi-oneshot'、`pi-oneshot' 两个一次性保底后端；也可以在
`kimi-explain-backends' 里添加自己的后端后把此变量设为对应的名字。"
  :type '(choice (const :tag "Kimi Code CLI (ACP 常驻)" kimi)
                 (const :tag "Kimi Code CLI (一次性，保底)" kimi-oneshot)
                 (const :tag "pi CLI (rpc 常驻)" pi)
                 (const :tag "pi CLI (一次性，保底)" pi-oneshot)
                 (const :tag "codex CLI (一次性，JSONL)" codex)
                 (symbol :tag "自定义后端")))

(defcustom kimi-explain-buffer-name "*ai-explain*"
  "展示对话内容的 buffer 名称."
  :type 'string)

(defcustom kimi-explain-use-markdown-mode t
  "非 nil 且已安装 markdown-mode 时，*ai-explain* buffer 使用 markdown-mode（只读）.
否则回退到 special-mode。修改后需要重新加载本文件才生效。"
  :type 'boolean)

(defcustom kimi-explain-prompt-template
  "请用中文解释以下代码。文件：%s（%s，第 %d-%d 行）。
要求：
1. 先用一两句话概括这段代码的作用；
2. 按主流程逐段讲解关键逻辑，只讲理解这段代码必须知道的内容；
3. 如确有必要，最后指出 1-3 个真正重要的坑或可改进点，没有就省略；
4. 控制篇幅，不要发散到无关的背景知识、边缘情况和重构建议；语言简洁，多用短句和列表。
代码如下：

```%s
%s
```"
  "解释代码时使用的 prompt 模板.
依次为： 文件路径、语言、起始行、结束行、代码块语言标识、代码内容."
  :type 'string)

;;; 后端定义
;;
;; 每个后端是一个 plist，支持三种声明方式：
;;
;; ACP 模式（最简单，面向任何实现了 Agent Client Protocol 的 agent）:
;;   :command    可执行文件路径
;;   :acp        t
;;   :arguments  启动 ACP 模式的参数列表，如 ("acp")
;;   :acp-mode   可选，会话建立后通过 session/set_mode 切换的模式 id
;;               （如 "auto"）；不配置则保持 agent 默认模式
;;   进程生命周期完全由插件管理（启动、握手、排队、掉线重启与
;;   session/resume 恢复上下文），无需提供任何回调。
;;
;; 一次性模式（每次提问新起一个进程）:
;;   :command     可执行文件路径
;;   :build-args  函数 (PROMPT)，在 *ai-explain* buffer 中调用，返回完整参数
;;                列表（含 PROMPT 和会话续接参数）；可以设置 buffer-local
;;                变量 `kimi-explain--session-id'
;;   :handle-line 函数 (LINE)，处理一行 stdout 输出，负责把内容插入
;;                *ai-explain* buffer 以及捕获 session id
;;
;; 自定义常驻模式（:persistent t，进程常驻、反复复用）:
;;   :command        可执行文件路径
;;   :ensure-process 函数 ()，在 *ai-explain* buffer 中调用，返回一个可用的
;;                   长驻进程（不存在则启动；允许异步握手，未就绪时
;;                   :send-prompt 应自行排队）
;;   :send-prompt    函数 (PROC PROMPT)，把问题发给长驻进程 PROC
;;   :handle-line    函数 (LINE)，处理一行 stdout 输出；一轮回复结束（含
;;                   出错）时必须调用 `kimi-explain--turn-done'
;;   :cancel         可选函数 (PROC)，中断当前回复但不杀进程（如 pi 的
;;                   abort）；不提供则按 s 停止时杀进程
;;
;; 新增后端只需往 `kimi-explain-backends' 里加一项，再把
;; `kimi-explain-backend' 设为它的名字。
;;
;; 进程身份在创建时捕获：filter/sentinel 等异步回调一律从 process 属性
;; （handle-line、persistent 等）取上下文，不读全局
;; `kimi-explain-backend'，因此切换后端后旧进程的迟来回调不会串线。

(defvar-local kimi-explain--session-id nil
  "当前 *ai-explain* buffer 对应的会话 ID.")

(defvar-local kimi-explain--process nil
  "当前后端进程（常驻模式下为长驻进程）.")

(defvar-local kimi-explain--busy nil
  "非 nil 表示后端正在回复中（一轮提问尚未结束）.")

(defvar-local kimi-explain--pi-saw-text nil
  "非 nil 表示当前这条 assistant 消息已经流过文本（pi 后端用）.
工具调用回合的 assistant 消息没有文本，其 message_end 不应补换行，
否则等待工具执行期间 buffer 里会多出空行。")

;;; ACP 通用后端（常驻进程）
;;
;; ACP (Agent Client Protocol) 是编辑器与 AI agent 之间的开放协议（地位
;; 类似 LSP 之于语言服务器），走 stdin/stdout 上的 JSON-RPC（ndjson，
;; 每行一个消息）。kimi、Claude Code、Gemini CLI、Codex、OpenCode 等
;; 主流 agent 都已支持。下面这组函数是协议的全部实现：启动进程、
;; initialize 握手、session/new 建会话、问题排队、掉线重启后用
;; session/resume 恢复上下文。任何 ACP agent 只用在
;; `kimi-explain-backends' 里声明 :command + :acp + :arguments 即可接入。

(defconst kimi-explain--acp-handshake-timeout 15
  "ACP 握手看门狗秒数：超时未就绪判定为失败.")

(defun kimi-explain--acp-request (proc method params)
  "向 ACP 进程 PROC 发送 JSON-RPC 请求（METHOD PARAMS），返回请求 id."
  (let ((id (1+ (or (process-get proc 'acp-next-id) 0))))
    (process-put proc 'acp-next-id id)
    (process-send-string
     proc (concat (json-encode `((jsonrpc . "2.0")
                                 (id . ,id)
                                 (method . ,method)
                                 ,@(when params `((params . ,params)))))
                  "\n"))
    id))

(defun kimi-explain--acp-respond (proc id payload)
  "向 ACP 进程 PROC 回复一个响应，PAYLOAD 形如 (result . …) 或 (error . …)."
  (when (process-live-p proc)
    (process-send-string
     proc (concat (json-encode `((jsonrpc . "2.0") (id . ,id) ,payload))
                  "\n"))))

(defun kimi-explain--acp-handshake (proc method params)
  "握手阶段发送请求：把请求 id 记为 acp-handshake-id 以便响应路由."
  (process-put proc 'acp-handshake-id
               (kimi-explain--acp-request proc method params)))

(defun kimi-explain--acp-watchdog (proc)
  "ACP 握手看门狗：超时未就绪则按失败处理，避免 busy 永久卡死."
  (when (and (process-live-p proc)
             (not (process-get proc 'acp-ready))
             (buffer-live-p (process-buffer proc)))
    (with-current-buffer (process-buffer proc)
      (kimi-explain--acp-fatal
       proc (format "ACP 握手超时（%d 秒未就绪），请检查后端 CLI 是否已登录、能否正常启动"
                    kimi-explain--acp-handshake-timeout)))))

(defun kimi-explain--acp-cancel-watchdog (proc)
  "取消 PROC 的握手看门狗（握手完成或已判定失败时调用）."
  (let ((timer (process-get proc 'acp-watchdog)))
    (when (timerp timer)
      (cancel-timer timer)
      (process-put proc 'acp-watchdog nil))))

(defun kimi-explain--acp-ensure-process ()
  "返回可用的 ACP 常驻进程，不存在则启动并开始握手.
在 *ai-explain* buffer 中调用；default-directory 已绑定为源码 buffer 的目录。"
  (if (process-live-p kimi-explain--process)
      kimi-explain--process
    (let* ((backend (kimi-explain--backend))
           (command (plist-get backend :command))
           (stderr-buf (generate-new-buffer " *kimi-explain-stderr*"))
           (proc (condition-case err
                     (make-process
                      :name "kimi-explain-acp"
                      :buffer (current-buffer)
                      :command (cons command (plist-get backend :arguments))
                      :coding 'utf-8-unix
                      :noquery t
                      :stderr stderr-buf
                      :filter #'kimi-explain--filter
                      :sentinel #'kimi-explain--sentinel)
                   (error
                    (kill-buffer stderr-buf)
                    (user-error "启动 ACP 进程失败: %s"
                                (error-message-string err))))))
      (process-put proc 'pending "")
      (process-put proc 'stderr-buffer stderr-buf)
      (process-put proc 'persistent t)
      (process-put proc 'handle-line #'kimi-explain--acp-handle-line)
      (process-put proc 'acp-cwd default-directory)
      (process-put proc 'acp-mode (plist-get backend :acp-mode))
      (process-put proc 'acp-state "init")
      (process-put proc 'acp-watchdog
                   (run-at-time kimi-explain--acp-handshake-timeout nil
                                #'kimi-explain--acp-watchdog proc))
      (kimi-explain--acp-handshake
       proc "initialize"
       '((protocolVersion . 1)
         (clientCapabilities . ((fs . ((readTextFile . :json-false)
                                       (writeTextFile . :json-false)))
                                (terminal . :json-false)))))
      proc)))

(defun kimi-explain--acp-open-session (proc)
  "initialize 完成后： 已有 session id 且对端支持 resume 则恢复会话，否则新建."
  (if (and kimi-explain--session-id (process-get proc 'acp-can-resume))
      (progn
        (process-put proc 'acp-state "resume")
        (kimi-explain--acp-handshake
         proc "session/resume"
         `((sessionId . ,kimi-explain--session-id)
           (cwd . ,(process-get proc 'acp-cwd))
           (mcpServers . []))))
    (kimi-explain--acp-new-session proc)))

(defun kimi-explain--acp-new-session (proc)
  "请求 ACP 进程 PROC 新建会话."
  (process-put proc 'acp-state "new")
  (kimi-explain--acp-handshake
   proc "session/new"
   `((cwd . ,(process-get proc 'acp-cwd))
     (mcpServers . []))))

(defun kimi-explain--acp-after-session (proc)
  "会话建立后： 配置了 :acp-mode 则切换模式，否则直接就绪."
  (let ((mode (process-get proc 'acp-mode)))
    (if mode
        (progn
          (process-put proc 'acp-state "mode")
          (kimi-explain--acp-handshake
           proc "session/set_mode"
           `((sessionId . ,kimi-explain--session-id)
             (modeId . ,mode))))
      (kimi-explain--acp-ready proc))))

(defun kimi-explain--acp-ready (proc)
  "握手完成： 标记进程就绪，并发出排队等待的问题."
  (kimi-explain--acp-cancel-watchdog proc)
  (process-put proc 'acp-ready t)
  (let ((queued (process-get proc 'acp-queued-prompt)))
    (process-put proc 'acp-queued-prompt nil)
    (if queued
        (kimi-explain--acp-send-prompt proc queued)
      ;; 没有排队的问题（不该发生），直接结束本轮以免卡住
      (kimi-explain--turn-done))))

(defun kimi-explain--acp-send-prompt (proc prompt)
  "把 PROMPT 发给 ACP 进程 PROC；握手未完成则排队，就绪后自动发出."
  (if (process-get proc 'acp-ready)
      (process-put proc 'acp-prompt-id
                   (kimi-explain--acp-request
                    proc "session/prompt"
                    `((sessionId . ,kimi-explain--session-id)
                      (prompt . [((type . "text") (text . ,prompt))]))))
    (process-put proc 'acp-queued-prompt prompt)))

(defun kimi-explain--acp-fatal (proc msg)
  "握手失败： 杀掉进程、报错并结束本轮."
  (kimi-explain--acp-cancel-watchdog proc)
  (process-put proc 'user-kill t)
  (kill-process proc)
  (kimi-explain--insert (format "\n> [%s]\n" msg))
  (kimi-explain--turn-done))

(defun kimi-explain--acp-handle-response (proc obj)
  "处理 ACP 响应 OBJ: 推进握手状态机，或结束一轮回复."
  (let ((id (alist-get 'id obj))
        (result (alist-get 'result obj))
        (err (alist-get 'error obj)))
    (cond
     ;; 本轮提问的响应：一轮结束
     ((eql id (process-get proc 'acp-prompt-id))
      (process-put proc 'acp-prompt-id nil)   ; 防对端重放导致重复收尾
      (when err
        (kimi-explain--insert
         (format "\n> [后端错误: %s]\n" (alist-get 'message err))))
      (kimi-explain--turn-done))
     ;; 握手响应：按阶段推进
     ((eql id (process-get proc 'acp-handshake-id))
      (pcase (process-get proc 'acp-state)
        ("init"
         (if err
             (kimi-explain--acp-fatal
              proc (format "ACP 初始化失败: %s" (alist-get 'message err)))
           ;; 记录对端能力：是否支持 session/resume
           ;; （能力值是空对象 {}，json-read 后是 nil，要用 assq 判断键是否存在）
           (let ((session-caps (alist-get 'sessionCapabilities
                                          (alist-get 'agentCapabilities result))))
             (process-put proc 'acp-can-resume
                          (and (assq 'resume session-caps) t)))
           (kimi-explain--acp-open-session proc)))
        ("resume"
         ;; resume 失败（会话已被清理等）退化为新会话
         (if err
             (kimi-explain--acp-new-session proc)
           (kimi-explain--acp-after-session proc)))
        ("new"
         (if err
             (kimi-explain--acp-fatal
              proc (format "ACP 创建会话失败: %s（如未登录请先在终端登录该 CLI）"
                           (alist-get 'message err)))
           (setq kimi-explain--session-id (alist-get 'sessionId result))
           (kimi-explain--acp-after-session proc)))
        ;; set_mode 成败都继续，失败只是保持 agent 默认模式
        ("mode" (kimi-explain--acp-ready proc)))))))

(defun kimi-explain--acp-handle-line (line)
  "ACP 后端： 处理一行 JSON-RPC 消息（ndjson）."
  (let ((obj (ignore-errors (json-read-from-string line))))
    (if (null obj)
        ;; 不是合法 JSON（比如警告信息），原样显示
        (kimi-explain--insert (concat line "\n"))
      (let ((method (alist-get 'method obj))
            (id (alist-get 'id obj))
            ;; filter 的 eq 守卫保证这里读到的就是产生本行输出的进程
            (proc kimi-explain--process))
        (cond
         ;; 会话通知：只关心回答正文流（思考、工具调用等不展示）
         ((equal method "session/update")
          (let ((update (alist-get 'update (alist-get 'params obj))))
            (when (equal (alist-get 'sessionUpdate update) "agent_message_chunk")
              (kimi-explain--insert
               (or (alist-get 'text (alist-get 'content update)) "")))))
         ;; 权限请求：配置了 :acp-mode 时不该出现，兜底一律取消该工具调用
         ((equal method "session/request_permission")
          (kimi-explain--acp-respond
           proc id `(result . ((outcome . ((outcome . "cancelled")))))))
         ;; 其他 agent -> client 请求：回 methodNotFound，免得对端干等
         (method
          (when id
            (kimi-explain--acp-respond
             proc id '(error . ((code . -32601)
                                (message . "Method not found"))))))
         ;; 响应：推进握手或结束本轮
         (id (kimi-explain--acp-handle-response proc obj)))))))

;;; kimi 一次性后端（保底）
;;
;; 每次提问新起一个 `kimi -p' 进程、用 --session 续接会话的旧机制。
;; ACP 模式出问题时可以 `(setq kimi-explain-backend 'kimi-oneshot)'
;; 或在 *ai-explain* buffer 按 b 切换过来兜底。

(defun kimi-explain--kimi-build-args (prompt)
  "kimi 一次性后端： 构造参数，已有会话则用 --session 续接."
  (append (when kimi-explain--session-id
            (list "--session" kimi-explain--session-id))
          (list "-p" prompt "--output-format" "stream-json")))

(defun kimi-explain--kimi-handle-line (line)
  "kimi 一次性后端： 解析 stream-json 行."
  (condition-case nil
      (let* ((obj (json-read-from-string line))
             (role (alist-get 'role obj)))
        (cond
         ((equal role "assistant")
          (let ((content (alist-get 'content obj)))
            (when (and (stringp content) (not (string-blank-p content)))
              (kimi-explain--insert (concat content "\n")))))
         ((equal role "meta")
          (when (equal (alist-get 'type obj) "session.resume_hint")
            (setq kimi-explain--session-id (alist-get 'session_id obj))))))
    (error
     ;; 不是合法 JSON（比如警告信息），原样显示
     (kimi-explain--insert (concat line "\n")))))

;;; pi 后端（--mode rpc 常驻进程）
;;
;; pi 的 `--mode rpc' 是 stdin/stdout 上的 JSON 行协议：进程常驻，写一行
;; {"type":"prompt","message":...} 即可提问；回答以 message_update 的
;; text_delta 流式到达，agent_settled 事件标志一轮结束；
;; {"type":"abort"} 可优雅中断当前回复（kimi ACP 做不到这一点）。
;; 启动时用 --session-id 固定会话 id，进程意外退出后用同一 id 重启
;; 即可恢复上下文。协议无需握手，进程起来就能收命令。

(defun kimi-explain--pi-ensure-process ()
  "返回可用的 pi rpc 常驻进程，不存在则启动."
  (if (process-live-p kimi-explain--process)
      kimi-explain--process
    ;; 没有 session id 则生成一个；进程重启后用同一 id 恢复上下文
    (unless kimi-explain--session-id
      (setq kimi-explain--session-id
            (format "emacs-%s-%04x"
                    (format-time-string "%Y%m%d-%H%M%S")
                    (random 65536))))
    (let* ((command (plist-get (kimi-explain--backend) :command))
           (stderr-buf (generate-new-buffer " *kimi-explain-stderr*"))
           (proc (condition-case err
                     (make-process
                      :name "kimi-explain-pi"
                      :buffer (current-buffer)
                      :command (list command "--mode" "rpc"
                                     "--session-id" kimi-explain--session-id)
                      :coding 'utf-8-unix
                      :noquery t
                      :stderr stderr-buf
                      :filter #'kimi-explain--filter
                      :sentinel #'kimi-explain--sentinel)
                   (error
                    (kill-buffer stderr-buf)
                    (user-error "启动 pi 进程失败: %s"
                                (error-message-string err))))))
      (process-put proc 'pending "")
      (process-put proc 'stderr-buffer stderr-buf)
      (process-put proc 'persistent t)
      (process-put proc 'handle-line #'kimi-explain--pi-handle-line)
      proc)))

(defun kimi-explain--pi-send-prompt (proc prompt)
  "把 PROMPT 发给 pi rpc 进程 PROC（无需握手，直接写入）."
  (process-send-string
   proc (concat (json-encode `((type . "prompt") (message . ,prompt)))
                "\n")))

(defun kimi-explain--pi-cancel (proc)
  "请求 pi rpc 进程 PROC 中断当前回复（不杀进程，会话保持）."
  (process-send-string proc "{\"type\":\"abort\"}\n"))

(defun kimi-explain--pi-handle-line (line)
  "pi 后端： 解析 rpc 事件流，取 text_delta；agent_settled 结束一轮."
  (let ((obj (ignore-errors (json-read-from-string line))))
    (if (null obj)
        ;; 不是合法 JSON（比如警告信息），原样显示
        (kimi-explain--insert (concat line "\n"))
      (pcase (alist-get 'type obj)
        ("message_update"
         (let ((ev (alist-get 'assistantMessageEvent obj)))
           (when (equal (alist-get 'type ev) "text_delta")
             (let ((delta (alist-get 'delta ev)))
               (when (and (stringp delta) (not (string-empty-p delta)))
                 (setq kimi-explain--pi-saw-text t)
                 (kimi-explain--insert delta))))))
        ("message_end"
         ;; 只给真正流过文本的 assistant 消息补换行；纯工具调用的
         ;; assistant 消息不补，否则等待期间 buffer 里会多出空行
         (when (and (equal (alist-get 'role (alist-get 'message obj)) "assistant")
                    kimi-explain--pi-saw-text)
           (setq kimi-explain--pi-saw-text nil)
           (kimi-explain--insert "\n")))
        ;; 一轮结束（正常完成或 abort 收尾都会到达）
        ("agent_settled"
         (setq kimi-explain--pi-saw-text nil)
         (when-let ((proc kimi-explain--process))
           (process-put proc 'cancel-pending nil))
         (kimi-explain--turn-done))))))

;;; pi 一次性后端（保底）
;;
;; 每次提问新起一个 `pi -p' 进程、用 --session-id 续接会话的旧机制。
;; rpc 模式出问题时可以 `(setq kimi-explain-backend 'pi-oneshot)'
;; 或在 *ai-explain* buffer 按 b 切换过来兜底。

(defun kimi-explain--pi-oneshot-build-args (prompt)
  "pi 一次性后端： 用 --session-id 固定会话 ID，没有则生成一个."
  (unless kimi-explain--session-id
    (setq kimi-explain--session-id
          (format "emacs-%s-%04x"
                  (format-time-string "%Y%m%d-%H%M%S")
                  (random 65536))))
  (list "--session-id" kimi-explain--session-id
        "-p" prompt "--mode" "json"))

(defun kimi-explain--pi-oneshot-handle-line (line)
  "pi 一次性后端： 解析 JSON 事件流，只取 text_delta / message_end."
  (condition-case nil
      (let ((obj (json-read-from-string line)))
        (pcase (alist-get 'type obj)
          ("message_update"
           (let ((ev (alist-get 'assistantMessageEvent obj)))
             (when (equal (alist-get 'type ev) "text_delta")
               (let ((delta (alist-get 'delta ev)))
                 (when (and (stringp delta) (not (string-empty-p delta)))
                   (setq kimi-explain--pi-saw-text t)
                   (kimi-explain--insert delta))))))
          ("message_end"
           ;; 只给真正流过文本的 assistant 消息补换行（同上，避免空行）
           (when (and (equal (alist-get 'role (alist-get 'message obj)) "assistant")
                      kimi-explain--pi-saw-text)
             (setq kimi-explain--pi-saw-text nil)
             (kimi-explain--insert "\n")))))
    (error
     ;; 不是合法 JSON（比如警告信息），原样显示
     (kimi-explain--insert (concat line "\n")))))

;;; codex 后端（一次性，JSONL）
;;
;; codex CLI 没有 ACP 模式，走 `codex exec --json' 一次性进程：
;; stdout 是 JSONL 事件流，thread.started 给出 thread_id（即会话 id），
;; 回答在 item.completed 的 agent_message 里一次性给出（非流式）；
;; 追问用 `codex exec resume --json <id> <prompt>' 续接会话。

(defun kimi-explain--codex-build-args (prompt)
  "codex 后端： 构造参数，已有会话则用 exec resume 续接."
  (if kimi-explain--session-id
      (list "exec" "resume" "--json" "--skip-git-repo-check"
            kimi-explain--session-id prompt)
    (list "exec" "--json" "--skip-git-repo-check" prompt)))

(defun kimi-explain--codex-handle-line (line)
  "codex 后端： 解析 JSONL 事件，捕获 thread_id、取 agent_message 正文."
  (condition-case nil
      (let ((obj (json-read-from-string line)))
        (pcase (alist-get 'type obj)
          ("thread.started"
           (setq kimi-explain--session-id (alist-get 'thread_id obj)))
          ("item.completed"
           (let ((item (alist-get 'item obj)))
             (when (equal (alist-get 'type item) "agent_message")
               (let ((text (alist-get 'text item)))
                 (when (and (stringp text) (not (string-blank-p text)))
                   (kimi-explain--insert (concat text "\n")))))))))
    (error
     ;; 不是合法 JSON（比如警告信息），原样显示
     (kimi-explain--insert (concat line "\n")))))

(defcustom kimi-explain-backends
  `((kimi :command "kimi"
          :acp t
          :arguments ("acp")
          :acp-mode "auto")
    (kimi-oneshot
          :command "kimi"
          :build-args ,#'kimi-explain--kimi-build-args
          :handle-line ,#'kimi-explain--kimi-handle-line)
    (pi   :command "pi"
          :persistent t
          :ensure-process ,#'kimi-explain--pi-ensure-process
          :send-prompt ,#'kimi-explain--pi-send-prompt
          :cancel ,#'kimi-explain--pi-cancel
          :handle-line ,#'kimi-explain--pi-handle-line)
    (pi-oneshot
          :command "pi"
          :build-args ,#'kimi-explain--pi-oneshot-build-args
          :handle-line ,#'kimi-explain--pi-oneshot-handle-line)
    (codex :command "codex"
           :build-args ,#'kimi-explain--codex-build-args
           :handle-line ,#'kimi-explain--codex-handle-line))
  "可用的后端 CLI 列表，元素为 (名字 . plist).
plist 格式见文件注释。"
  :type '(alist :key-type symbol :value-type sexp))

(defvar-local kimi-explain--source-buffer nil
  "发起请求的源代码 buffer，用于决定进程工作目录.")

(defun kimi-explain--backend ()
  "返回当前后端的 plist；:acp 后端自动补齐通用 ACP 回调."
  (let ((backend (or (alist-get kimi-explain-backend kimi-explain-backends)
                     (user-error "未知的后端 `%s'，请检查 `kimi-explain-backend' 和 `kimi-explain-backends'"
                                 kimi-explain-backend))))
    (if (plist-get backend :acp)
        ;; 用户声明在前、默认值在后，plist-get 取第一个，故用户可覆盖默认
        (append backend
                (list :persistent t
                      :ensure-process #'kimi-explain--acp-ensure-process
                      :send-prompt #'kimi-explain--acp-send-prompt
                      :handle-line #'kimi-explain--acp-handle-line))
      backend)))

(defun kimi-explain--kill-process ()
  "杀掉当前后端进程（用户主动操作，标记后 sentinel 不报异常）.
在 *ai-explain* buffer 中调用。"
  (when (process-live-p kimi-explain--process)
    (process-put kimi-explain--process 'user-kill t)
    (kill-process kimi-explain--process))
  ;; kill-process 是异步的，立即摘掉引用，防止极快的下一次提问
  ;; 复用到这个将死的进程；旧进程的迟来回调由 sentinel 的 eq 守卫挡住
  (setq kimi-explain--process nil
        kimi-explain--busy nil))

(defun kimi-explain--kill-buffer-cleanup ()
  "*ai-explain* buffer 被关闭时：杀掉后端进程，避免常驻进程变孤儿."
  (when (process-live-p kimi-explain--process)
    (process-put kimi-explain--process 'user-kill t)
    (kill-process kimi-explain--process)))

(defvar kimi-explain-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'kimi-ask)
    (define-key map (kbd "A") #'kimi-ask)
    (define-key map (kbd "s") #'kimi-explain-stop)
    (define-key map (kbd "n") #'kimi-explain-new-session)
    (define-key map (kbd "b") #'kimi-explain-switch-backend)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'describe-mode)
    map)
  "*ai-explain* buffer 的按键映射.")

(declare-function markdown-mode "markdown-mode")
;; mode 定义在下方的 if 分支里，编译器看不到，先声明
(declare-function kimi-explain-mode "kimi-explain")

(defun kimi-explain--mode-line ()
  "mode-line 片段：显示当前后端，回复中时附带状态提示."
  (if kimi-explain--busy
      (format " [%s:回复中]" kimi-explain-backend)
    (format " [%s]" kimi-explain-backend)))

(if (and kimi-explain-use-markdown-mode (require 'markdown-mode nil t))
    (define-derived-mode kimi-explain-mode markdown-mode "AI-Explain"
      "展示 AI 对话内容的 major mode（只读，基于 markdown-mode）.
\\{kimi-explain-mode-map}"
      (read-only-mode 1)
      (visual-line-mode 1)
      (setq-local mode-line-format
                  (append (default-value 'mode-line-format)
                          '((:eval (kimi-explain--mode-line))))))
  (define-derived-mode kimi-explain-mode special-mode "AI-Explain"
    "展示 AI 对话内容的 major mode（只读，基于 special-mode）.
\\{kimi-explain-mode-map}"
    (read-only-mode 1)
    (visual-line-mode 1)
    (setq-local mode-line-format
                (append (default-value 'mode-line-format)
                        '((:eval (kimi-explain--mode-line)))))))

(defun kimi-explain--get-buffer ()
  "返回 *ai-explain* buffer，不存在则创建."
  (or (get-buffer kimi-explain-buffer-name)
      (with-current-buffer (get-buffer-create kimi-explain-buffer-name)
        (insert "# AI 代码讲解\n\n选中代码后 `M-x kimi-explain-region` 解释；本 buffer 中： `a` 或 `A` 追问，`s` 停止回复，`n` 新会话，`b` 切换后端，`q` 关闭，`?` 查看全部按键。\n\n")
        (kimi-explain-mode)
        (add-hook 'kill-buffer-hook #'kimi-explain--kill-buffer-cleanup nil t)
        (current-buffer))))

(defun kimi-explain--insert (text)
  "在 *ai-explain* buffer 末尾插入 TEXT（绕过 read-only），并停掉等待动画。"
  (with-current-buffer (kimi-explain--get-buffer)
    (kimi-explain--spinner-stop)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (insert text))))
  (kimi-explain--scroll-to-end))

(defun kimi-explain--turn-done ()
  "标记一轮回复结束（常驻后端的 :handle-line 在收到结束信号时调用）.
在 *ai-explain* buffer 中调用。"
  (kimi-explain--spinner-stop)
  (setq kimi-explain--busy nil)
  (kimi-explain--insert "\n---\n\n"))

(defun kimi-explain--scroll-to-end ()
  "让所有显示 *ai-explain* 的窗口滚动到末尾。"
  (dolist (win (get-buffer-window-list kimi-explain-buffer-name nil t))
    (set-window-point win (with-current-buffer kimi-explain-buffer-name (point-max)))))

;;; 等待动画（spinner）

(defconst kimi-explain--spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "spinner 的帧.")

(defvar-local kimi-explain--spinner-timer nil)
(defvar-local kimi-explain--spinner-idx 0)
(defvar-local kimi-explain--spinner-beg nil)
(defvar-local kimi-explain--spinner-end nil)

(defun kimi-explain--spinner-start ()
  "在 buffer 末尾开始显示等待动画。在 *ai-explain* buffer 中调用。"
  (kimi-explain--spinner-stop)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (setq kimi-explain--spinner-beg (point-marker))
      (insert (propertize (concat (aref kimi-explain--spinner-frames 0) " 思考中…")
                          'face 'shadow))
      (setq kimi-explain--spinner-end (point-marker))
      (set-marker-insertion-type kimi-explain--spinner-end t)))
  (setq kimi-explain--spinner-idx 0
        kimi-explain--spinner-timer
        (run-at-time 0.1 0.1 #'kimi-explain--spinner-tick (current-buffer)))
  (add-hook 'kill-buffer-hook #'kimi-explain--spinner-stop nil t))

(defun kimi-explain--spinner-tick (buf)
  "更新 BUF 中的 spinner 帧。"
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and (markerp kimi-explain--spinner-beg)
                 (marker-position kimi-explain--spinner-beg))
        (setq kimi-explain--spinner-idx
              (mod (1+ kimi-explain--spinner-idx)
                   (length kimi-explain--spinner-frames)))
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char kimi-explain--spinner-beg)
            (delete-region kimi-explain--spinner-beg kimi-explain--spinner-end)
            (insert (propertize
                     (concat (aref kimi-explain--spinner-frames kimi-explain--spinner-idx)
                             " 思考中…")
                     'face 'shadow))))))))

(defun kimi-explain--spinner-stop ()
  "停止并清除等待动画（内容到达或进程结束时调用）。"
  (when (timerp kimi-explain--spinner-timer)
    (cancel-timer kimi-explain--spinner-timer)
    (setq kimi-explain--spinner-timer nil))
  (when (and (markerp kimi-explain--spinner-beg)
             (marker-position kimi-explain--spinner-beg))
    (let ((inhibit-read-only t))
      (delete-region kimi-explain--spinner-beg kimi-explain--spinner-end))
    (set-marker kimi-explain--spinner-beg nil)
    (set-marker kimi-explain--spinner-end nil)))

(defun kimi-explain--filter (proc chunk)
  "进程过滤器： 累积 CHUNK，按完整行交给进程自己的 handle-line 处理。
后端身份在进程创建时已捕获到 process 属性上，不读全局后端变量。"
  (when (buffer-live-p (process-buffer proc))
    (let ((pending (process-get proc 'pending)))
      (setq chunk (concat (or pending "") chunk))
      (let ((lines (split-string chunk "\n")))
        ;; 最后一段可能是不完整的行，留到下次
        (process-put proc 'pending (car (last lines)))
        (with-current-buffer (process-buffer proc)
          ;; 只投递仍占着 `kimi-explain--process' 的进程的输出；旧进程
          ;; （停止/新会话/切后端后）的迟来输出直接丢弃。该守卫同时保证
          ;; handle-line 里读到的 `kimi-explain--process' 就是 PROC 本身
          (when (eq kimi-explain--process proc)
            (let ((handle-line (process-get proc 'handle-line)))
              (when handle-line
                (dolist (line (butlast lines))
                  (unless (string-blank-p line)
                    (process-put proc 'got-stdout t)
                    (funcall handle-line line)))))))))))

(defun kimi-explain--flush-pending (proc)
  "把 PROC 过滤器中残留的不完整末行交给 handle-line 处理（进程退出时调用）。
用户主动杀掉的进程不再 flush，避免残留的半行 JSON 被插进 buffer。"
  (when (and (not (process-get proc 'user-kill))
             (buffer-live-p (process-buffer proc)))
    (let ((pending (process-get proc 'pending)))
      (unless (string-blank-p (or pending ""))
        (process-put proc 'pending "")
        (process-put proc 'got-stdout t)
        (with-current-buffer (process-buffer proc)
          (let ((handle-line (process-get proc 'handle-line)))
            (when handle-line
              (funcall handle-line pending))))))))

(defun kimi-explain--sentinel (proc event)
  "进程结束回调。"
  (when (memq (process-status proc) '(exit signal))
    (kimi-explain--flush-pending proc)
    ;; 进程已死，握手看门狗（如果有）不必再留到 15 秒后空转
    (kimi-explain--acp-cancel-watchdog proc)
    (let ((stderr-buf (process-get proc 'stderr-buffer))
          (stderr-text nil))
      (when (buffer-live-p stderr-buf)
        (setq stderr-text (string-trim (with-current-buffer stderr-buf (buffer-string))))
        (kill-buffer stderr-buf))
      (when (buffer-live-p (process-buffer proc))
        (with-current-buffer (process-buffer proc)
          ;; 只处理仍占着 `kimi-explain--process' 的进程；旧进程
          ;; （已被停止/新会话/切后端替换）的迟来回调静默忽略，
          ;; 防止它清掉新一轮的状态或插入过期消息
          (when (eq kimi-explain--process proc)
            (setq kimi-explain--process nil
                  kimi-explain--busy nil)
            (kimi-explain--spinner-stop)
            (let ((stderr-quote
                   (if (string-blank-p (or stderr-text ""))
                       ""
                     (concat "\n> stderr: "
                             (string-join (split-string stderr-text "\n")
                                          "\n> ")))))
              (cond
               ((process-get proc 'user-kill)
                nil)                    ; 用户主动 kill（停止/新会话/切后端），不报错
               ((process-get proc 'persistent)
                ;; 常驻进程意外退出：下次提问会自动重启进程并恢复会话
                (kimi-explain--insert
                 (format "\n\n> [后端进程退出: %s，下次提问将自动重启]%s\n"
                         (string-trim event) stderr-quote))
                (kimi-explain--turn-done))
               ((and (eq (process-status proc) 'exit)
                     (zerop (process-exit-status proc)))
                ;; 正常退出但 stdout 一片空白：把 stderr 亮出来帮助诊断
                (when (and (not (process-get proc 'got-stdout))
                           (not (string-blank-p (or stderr-text ""))))
                  (kimi-explain--insert
                   (format "\n\n> [后端正常退出但没有输出，stderr 如下]\n> %s\n"
                           (string-join (split-string stderr-text "\n") "\n> "))))
                (kimi-explain--turn-done))
               (t
                (kimi-explain--insert
                 (format "\n\n> [后端进程异常结束: %s]%s\n"
                         (string-trim event) stderr-quote))
                (kimi-explain--turn-done))))))))))

(defun kimi-explain--check-not-busy ()
  "后端正在回复时报错（入口函数在插入问题块之前调用，避免留下悬空问题）."
  (when (with-current-buffer (kimi-explain--get-buffer) kimi-explain--busy)
    (user-error "后端正在回复中，请等待结束（在 %s 按 s 可停止）"
                kimi-explain-buffer-name)))

(defun kimi-explain--send (prompt &optional source-buffer)
  "把 PROMPT 发送给当前后端（自动续接已有会话），输出实时显示到 *ai-explain* buffer."
  (let ((buf (kimi-explain--get-buffer)))
    (with-current-buffer buf
      (kimi-explain--check-not-busy)
      (condition-case err
          (progn
            (setq kimi-explain--source-buffer
                  (or source-buffer kimi-explain--source-buffer))
            (let* ((backend (kimi-explain--backend))
                   (command (plist-get backend :command))
                   (default-directory
                    (if (buffer-live-p kimi-explain--source-buffer)
                        (with-current-buffer kimi-explain--source-buffer
                          default-directory)
                      default-directory)))
              (unless (executable-find command)
                (user-error "找不到命令 `%s'，请确认后端 CLI 已安装且在 PATH 中"
                            command))
              (message "kimi-explain: 正在用后端 `%s' 回答…" kimi-explain-backend)
              (if (plist-get backend :persistent)
                  ;; 常驻模式：复用长驻进程；握手未完成时 :send-prompt 自行排队
                  (let ((proc (funcall (plist-get backend :ensure-process))))
                    (setq kimi-explain--process proc
                          kimi-explain--busy t)
                    (kimi-explain--spinner-start)
                    (funcall (plist-get backend :send-prompt) proc prompt))
                ;; 一次性模式：每个问题新起一个进程
                (let* ((args (funcall (plist-get backend :build-args) prompt))
                       (stderr-buf (generate-new-buffer " *kimi-explain-stderr*"))
                       (proc (condition-case err
                                 (make-process
                                  :name "kimi-explain"
                                  :buffer buf
                                  :command (cons command args)
                                  :coding 'utf-8-unix
                                  :noquery t
                                  :stderr stderr-buf
                                  :filter #'kimi-explain--filter
                                  :sentinel #'kimi-explain--sentinel)
                               (error
                                (kill-buffer stderr-buf)
                                (user-error "启动后端进程失败: %s"
                                            (error-message-string err))))))
                  (process-put proc 'pending "")
                  (process-put proc 'stderr-buffer stderr-buf)
                  (process-put proc 'handle-line (plist-get backend :handle-line))
                  (setq kimi-explain--process proc
                        kimi-explain--busy t)
                  (kimi-explain--spinner-start)))))
        (user-error
         ;; 发送失败时在 buffer 里补一行说明，免得问题块悬空
         (kimi-explain--insert (format "> [发送失败: %s]\n\n"
                                       (error-message-string err)))
         (signal 'user-error (cdr err)))))
    (display-buffer buf)))

(defun kimi-explain--language-id ()
  "根据 major-mode 猜测 markdown 代码块的语言标识."
  (let ((name (symbol-name major-mode)))
    (cond
     ((string-match "\\`\\(?:c\\+\\+\\|c\\)\\(?:-ts\\)?-mode" name)
      (if (string-prefix-p "c++" name) "cpp" "c"))
     ((string-match-p "python" name) "python")
     ((string-match-p "rust" name) "rust")
     ((string-match-p "go" name) "go")
     ((string-match-p "\\(?:java\\)?script\\|typescript" name) "javascript")
     ((string-match-p "emacs-lisp\\|lisp" name) "elisp")
     ((string-match-p "sh\\|shell" name) "bash")
     (t (replace-regexp-in-string "-mode\\'" "" name)))))

(defun kimi-explain--quote-block (text)
  "把 TEXT 的每行加上 `> ' 前缀，作为 markdown 引用块展示（与回答正文区分）。"
  (concat "> " (string-join (split-string text "\n") "\n> ")))

;;;###autoload
(defun kimi-explain-region (beg end)
  "用当前后端解释选中的区域 (BEG END)，结果实时显示到 *ai-explain* buffer.
已有会话会自动续接，可以连续选中不同代码多次调用进行追问。"
  (interactive "r")
  (unless (use-region-p)
    (user-error "请先选中一段代码"))
  (kimi-explain--check-not-busy)
  (let* ((code (buffer-substring-no-properties beg end))
         (file (or (buffer-file-name) (buffer-name)))
         (lang (kimi-explain--language-id))
         (start-line (line-number-at-pos beg))
         (end-line (line-number-at-pos end))
         (prompt (format kimi-explain-prompt-template
                         file lang start-line end-line lang code))
         (source (current-buffer)))
    (kimi-explain--insert
     (format "## 解释 %s:%d-%d\n\n%s\n\n"
             (file-name-nondirectory file) start-line end-line
             (kimi-explain--quote-block
              (format "```%s\n%s\n```" lang (string-trim-right code)))))
    (deactivate-mark)
    (kimi-explain--send prompt source)))

;;;###autoload
(defun kimi-ask (question)
  "直接向当前后端提问 QUESTION（续接当前会话），用于追问."
  ;; busy 检查放在 read-string 之前，免得用户白敲一次问题
  (interactive (progn
                 (kimi-explain--check-not-busy)
                 (list (read-string "提问: "))))
  (when (string-blank-p question)
    (user-error "问题不能为空"))
  (kimi-explain--check-not-busy)
  ;; 问题用 > 引用块展示，与回答正文区分开
  (kimi-explain--insert
   (format "## 追问\n\n%s\n\n" (kimi-explain--quote-block question)))
  (kimi-explain--send question))

;;;###autoload
(defun kimi-explain-stop ()
  "停止当前正在进行的回复.
后端提供 :cancel 回调（如 pi 的 abort）时优先优雅中断，进程和会话都保留；
否则直接杀掉进程——会话 ID 保留在 buffer 里，下次提问自动重启并恢复上下文。
若优雅中断发出后端却迟迟不结束，再按一次 s 会杀掉进程兜底。"
  (interactive)
  (with-current-buffer (kimi-explain--get-buffer)
    (if (not kimi-explain--busy)
        (message "没有正在进行的回复")
      (let ((cancel (plist-get (kimi-explain--backend) :cancel))
            (proc kimi-explain--process))
        (if (and cancel
                 (process-live-p proc)
                 (not (process-get proc 'cancel-pending)))
            ;; 优雅中断：turn-done 由后端在一轮真正结束时触发
            (progn
              (process-put proc 'cancel-pending t)
              (funcall cancel proc)
              (kimi-explain--insert "\n\n> [已停止]\n"))
          (kimi-explain--kill-process)
          (kimi-explain--insert "\n\n> [已停止]\n\n---\n\n"))))))

;;;###autoload
(defun kimi-explain-new-session ()
  "丢弃当前会话上下文，下一次提问将开启全新会话."
  (interactive)
  (with-current-buffer (kimi-explain--get-buffer)
    (kimi-explain--kill-process)
    (setq kimi-explain--session-id nil))
  (kimi-explain--insert "\n---\n\n# 新会话\n\n"))

;;;###autoload
(defun kimi-explain-switch-backend (backend)
  "切换后端 CLI（kimi / pi / 自定义），并开启新会话."
  (interactive
   (list (intern (completing-read "后端: "
                                  (mapcar #'car kimi-explain-backends)
                                  nil t nil nil
                                  (symbol-name kimi-explain-backend)))))
  (if (eq backend kimi-explain-backend)
      (message "已是后端 `%s'" backend)
    (setq kimi-explain-backend backend)
    (with-current-buffer (kimi-explain--get-buffer)
      (kimi-explain--kill-process)
      (setq kimi-explain--session-id nil))
    (kimi-explain--insert (format "\n---\n\n# 切换到后端 `%s'，新会话\n\n" backend))))

(provide 'kimi-explain)
;;; kimi-explain.el ends here
