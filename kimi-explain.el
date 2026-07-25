;;; kimi-explain.el --- 用 AI CLI (kimi / pi) 解释代码并持续追问 -*- lexical-binding: t; -*-

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
内置 `kimi 和 `pi 两种；也可以在 `kimi-explain-backends' 里添加自己的后端后
把此变量设为对应的名字。"
  :type '(choice (const :tag "Kimi Code CLI" kimi)
                 (const :tag "pi CLI" pi)
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
;; 每个后端是一个 plist:
;;   :command     可执行文件路径
;;   :build-args  函数 (PROMPT)，在 *ai-explain* buffer 中调用，返回完整参数列表
;;                （含 PROMPT 和会话续接参数）；可以设置 buffer-local 变量
;;                `kimi-explain--session-id'
;;   :handle-line 函数 (LINE)，处理一行 stdout 输出，负责把内容插入
;;                *ai-explain* buffer 以及捕获 session id
;;
;; 新增后端只需往 `kimi-explain-backends' 里加一项，再把
;; `kimi-explain-backend' 设为它的名字。

(defvar-local kimi-explain--session-id nil
  "当前 *ai-explain* buffer 对应的会话 ID.")

(defun kimi-explain--kimi-build-args (prompt)
  "kimi 后端： 构造参数，已有会话则用 --session 续接."
  (append (when kimi-explain--session-id
            (list "--session" kimi-explain--session-id))
          (list "-p" prompt "--output-format" "stream-json")))

(defun kimi-explain--kimi-handle-line (line)
  "kimi 后端： 解析 stream-json 行."
  (condition-case nil
      (let* ((obj (json-read-from-string line))
             (role (alist-get 'role obj)))
        (cond
         ((equal role "assistant")
          (let ((content (alist-get 'content obj)))
            (unless (string-blank-p (or content ""))
              (kimi-explain--insert (concat content "\n")))))
         ((equal role "meta")
          (when (equal (alist-get 'type obj) "session.resume_hint")
            (setq kimi-explain--session-id (alist-get 'session_id obj))))))
    (error
     ;; 不是合法 JSON（比如警告信息），原样显示
     (kimi-explain--insert (concat line "\n")))))

(defun kimi-explain--pi-build-args (prompt)
  "pi 后端： 用 --session-id 固定会话 ID，没有则生成一个."
  (unless kimi-explain--session-id
    (setq kimi-explain--session-id
          (format "emacs-%s-%04x"
                  (format-time-string "%Y%m%d-%H%M%S")
                  (random 65536))))
  (list "--session-id" kimi-explain--session-id
        "-p" prompt "--mode" "json"))

(defun kimi-explain--pi-handle-line (line)
  "pi 后端： 解析 JSON 事件流，只取 text_delta / message_end."
  (condition-case nil
      (let ((obj (json-read-from-string line)))
        (pcase (alist-get 'type obj)
          ("message_update"
           (let ((ev (alist-get 'assistantMessageEvent obj)))
             (when (equal (alist-get 'type ev) "text_delta")
               (kimi-explain--insert (alist-get 'delta ev)))))
          ("message_end"
           (let ((msg (alist-get 'message obj)))
             (when (equal (alist-get 'role msg) "assistant")
               (kimi-explain--insert "\n"))))))
    (error nil)))

(defcustom kimi-explain-backends
  `((kimi :command "kimi"
          :build-args ,#'kimi-explain--kimi-build-args
          :handle-line ,#'kimi-explain--kimi-handle-line)
    (pi   :command "pi"
          :build-args ,#'kimi-explain--pi-build-args
          :handle-line ,#'kimi-explain--pi-handle-line))
  "可用的后端 CLI 列表，元素为 (名字 . plist).
plist 格式见文件注释。"
  :type '(alist :key-type symbol :value-type plist))

(defvar-local kimi-explain--process nil
  "当前正在运行的后端进程.")

(defvar-local kimi-explain--source-buffer nil
  "发起请求的源代码 buffer，用于决定进程工作目录.")

(defun kimi-explain--backend ()
  "返回当前后端的 plist."
  (or (alist-get kimi-explain-backend kimi-explain-backends)
      (user-error "未知的后端 `%s'，请检查 `kimi-explain-backend' 和 `kimi-explain-backends'"
                  kimi-explain-backend)))

(defun kimi-explain--kill-process ()
  "杀掉当前后端进程（用户主动操作，标记后 sentinel 不报异常）.
在 *ai-explain* buffer 中调用。"
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

(if (and kimi-explain-use-markdown-mode (require 'markdown-mode nil t))
    (define-derived-mode kimi-explain-mode markdown-mode "AI-Explain"
      "展示 AI 对话内容的 major mode（只读，基于 markdown-mode）.
\\{kimi-explain-mode-map}"
      (read-only-mode 1)
      (visual-line-mode 1))
  (define-derived-mode kimi-explain-mode special-mode "AI-Explain"
    "展示 AI 对话内容的 major mode（只读，基于 special-mode）.
\\{kimi-explain-mode-map}"
    (read-only-mode 1)
    (visual-line-mode 1)))

(defun kimi-explain--get-buffer ()
  "返回 *ai-explain* buffer，不存在则创建."
  (or (get-buffer kimi-explain-buffer-name)
      (with-current-buffer (get-buffer-create kimi-explain-buffer-name)
        (insert "# AI 代码讲解\n\n选中代码后按 `C-c k e` 解释；本 buffer 中： `a` 或 `A` 追问，`s` 停止回复，`n` 新会话，`b` 切换后端，`q` 关闭，`?` 查看全部按键。\n\n")
        (kimi-explain-mode)
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
  "进程过滤器： 累积 CHUNK，按完整行交给后端的 :handle-line 处理。"
  (when (buffer-live-p (process-buffer proc))
    (let ((pending (process-get proc 'pending)))
      (setq chunk (concat (or pending "") chunk))
      (let ((lines (split-string chunk "\n")))
        ;; 最后一段可能是不完整的行，留到下次
        (process-put proc 'pending (car (last lines)))
        (with-current-buffer (process-buffer proc)
          (let ((handle-line (plist-get (kimi-explain--backend) :handle-line)))
            (dolist (line (butlast lines))
              (unless (string-blank-p line)
                (process-put proc 'got-stdout t)
                (funcall handle-line line)))))))))

(defun kimi-explain--flush-pending (proc)
  "把 PROC 过滤器中残留的不完整末行交给后端处理（进程退出时调用）。"
  (when (buffer-live-p (process-buffer proc))
    (let ((pending (process-get proc 'pending)))
      (unless (string-blank-p (or pending ""))
        (process-put proc 'pending "")
        (process-put proc 'got-stdout t)
        (with-current-buffer (process-buffer proc)
          (funcall (plist-get (kimi-explain--backend) :handle-line) pending))))))

(defun kimi-explain--sentinel (proc event)
  "进程结束回调。"
  (when (memq (process-status proc) '(exit signal))
    (kimi-explain--flush-pending proc)
    (let ((stderr-buf (process-get proc 'stderr-buffer))
          (stderr-text nil))
      (when (buffer-live-p stderr-buf)
        (setq stderr-text (string-trim (with-current-buffer stderr-buf (buffer-string))))
        (kill-buffer stderr-buf))
      (when (buffer-live-p (process-buffer proc))
        (with-current-buffer (process-buffer proc)
          ;; 防止旧进程的 sentinel 清掉新进程占用的变量
          (when (eq kimi-explain--process proc)
            (setq kimi-explain--process nil)))
        (cond
         ((process-get proc 'user-kill)
          nil)                          ; 用户主动 kill（新会话/切后端），不报错
         ((and (eq (process-status proc) 'exit) (zerop (process-exit-status proc)))
          ;; 正常退出但 stdout 一片空白：把 stderr 亮出来帮助诊断
          (when (and (not (process-get proc 'got-stdout))
                     (not (string-blank-p (or stderr-text ""))))
            (kimi-explain--insert
             (format "\n\n> [后端正常退出但没有输出，stderr 如下]\n> %s\n"
                     (string-join (split-string stderr-text "\n") "\n> "))))
          (kimi-explain--insert "\n---\n\n"))
         (t
          (kimi-explain--insert
           (format "\n\n> [后端进程异常结束: %s]%s\n\n"
                   (string-trim event)
                   (if (string-blank-p (or stderr-text ""))
                       ""
                     (concat "\n> stderr: "
                             (string-join (split-string stderr-text "\n") "\n> ")))))))))))

(defun kimi-explain--send (prompt &optional source-buffer)
  "把 PROMPT 发送给当前后端（自动续接已有会话），输出实时显示到 *ai-explain* buffer."
  (let ((buf (kimi-explain--get-buffer)))
    (with-current-buffer buf
      (when (process-live-p kimi-explain--process)
        (user-error "后端正在回复中，请等待结束（在 %s 按 s 可停止）"
                    kimi-explain-buffer-name))
      (setq kimi-explain--source-buffer (or source-buffer kimi-explain--source-buffer))
      (let* ((backend (kimi-explain--backend))
             (command (plist-get backend :command))
             (_ (unless (executable-find command)
                  (user-error "找不到命令 `%s'，请确认后端 CLI 已安装且在 PATH 中"
                              command)))
             (default-directory
              (if (buffer-live-p kimi-explain--source-buffer)
                  (with-current-buffer kimi-explain--source-buffer default-directory)
                default-directory))
             (args (funcall (plist-get backend :build-args) prompt))
             (stderr-buf (generate-new-buffer " *kimi-explain-stderr*"))
             (proc (make-process
                    :name "kimi-explain"
                    :buffer buf
                    :command (cons command args)
                    :noquery t
                    :stderr stderr-buf
                    :filter #'kimi-explain--filter
                    :sentinel #'kimi-explain--sentinel)))
        (process-put proc 'pending "")
        (process-put proc 'stderr-buffer stderr-buf)
        (setq kimi-explain--process proc)
        (kimi-explain--spinner-start)))
    (display-buffer buf)))

(defun kimi-explain--language-id ()
  "根据 major-mode 猜测 markdown 代码块的语言标识."
  (let ((name (symbol-name major-mode)))
    (cond
     ((string-match "\\`\\(?:c\\+\\+\\|c\\)-mode" name)
      (if (string-prefix-p "c++" name) "cpp" "c"))
     ((string-match-p "python" name) "python")
     ((string-match-p "rust" name) "rust")
     ((string-match-p "go" name) "go")
     ((string-match-p "\\(?:java\\)?script\\|typescript" name) "javascript")
     ((string-match-p "emacs-lisp\\|lisp" name) "elisp")
     ((string-match-p "sh\\|shell" name) "bash")
     (t (replace-regexp-in-string "-mode\\'" "" name)))))

;;;###autoload
(defun kimi-explain-region (beg end)
  "用当前后端解释选中的区域 (BEG END)，结果实时显示到 *ai-explain* buffer.
已有会话会自动续接，可以连续选中不同代码多次调用进行追问。"
  (interactive "r")
  (unless (use-region-p)
    (user-error "请先选中一段代码"))
  (let* ((code (buffer-substring-no-properties beg end))
         (file (or (buffer-file-name) (buffer-name)))
         (lang (kimi-explain--language-id))
         (start-line (line-number-at-pos beg))
         (end-line (line-number-at-pos end))
         (prompt (format kimi-explain-prompt-template
                         file lang start-line end-line lang code))
         (source (current-buffer)))
    (kimi-explain--insert
     (format "## 解释 %s:%d-%d\n\n```%s\n%s\n```\n\n"
             (file-name-nondirectory file) start-line end-line lang
             (string-trim-right code)))
    (deactivate-mark)
    (kimi-explain--send prompt source)))

;;;###autoload
(defun kimi-ask (question)
  "直接向当前后端提问 QUESTION（续接当前会话），用于追问."
  (interactive "s提问: ")
  (when (string-blank-p question)
    (user-error "问题不能为空"))
  (kimi-explain--insert (format "## 追问\n\n%s\n\n" question))
  (kimi-explain--send question))

;;;###autoload
(defun kimi-explain-stop ()
  "停止当前正在进行的回复."
  (interactive)
  (with-current-buffer (kimi-explain--get-buffer)
    (if (process-live-p kimi-explain--process)
        (progn
          (kimi-explain--kill-process)
          (kimi-explain--insert "\n\n> [已停止]\n\n---\n\n"))
      (message "没有正在进行的回复"))))

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
  (unless (eq backend kimi-explain-backend)
    (setq kimi-explain-backend backend)
    (with-current-buffer (kimi-explain--get-buffer)
      (kimi-explain--kill-process)
      (setq kimi-explain--session-id nil))
    (kimi-explain--insert (format "\n---\n\n# 切换到后端 `%s'，新会话\n\n" backend))))

(provide 'kimi-explain)
;;; kimi-explain.el ends here
