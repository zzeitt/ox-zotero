# ox-zotero —— Org Mode → Zotero 导出后端

将 Org 文章导出到 Zotero 文库：创建条目、上传 HTML 附件、写入 Note，一站式完成。

## 设计理念

- **ox-html 负责所有 Org→HTML 转换**——ox-zotero 不重复造轮子，通过 `org-export-define-derived-backend` 继承 ox-html 的全部转码器
- **ox-zotero 只做两件事**：提取元数据、调用 zot.py 上传
- 工作流：`Org 文件 → ox-html → HTML → zot.py → Zotero 条目 + 附件 + Note`

## 前置条件

### 1. zot.py CLI 工具

需要安装 [zot-tool](https://github.com/zzeitt/zot-tool)（≥ v1.8.5）：

```bash
git clone https://github.com/zzeitt/zot-tool.git ~/.claude/skills/zot-tool
pip install pyzotero
```

### 2. 环境变量

```bash
export ZOTERO_API_KEY="your-api-key"          # https://www.zotero.org/settings/keys
export ZOTERO_LIBRARY_ID="your-library-id"
export ZOTERO_WEBDAV_URL="https://dav.jianguoyun.com/dav/zotero/"
export ZOTERO_WEBDAV_USER="your-webdav-user"
export ZOTERO_WEBDAV_PASS="your-webdav-pass"
```

> **注意**：`ZOTERO_WEBDAV_*` 仅附件上传需要。未配置时 item 创建和 Note 写入正常，附件上传会跳过。

### 3. Emacs 依赖

- Emacs ≥ 26（Org Mode 内置 ox-html）
- `json` 库（Emacs 内置）

## 安装

```elisp
;; 方式一：直接加载
(load-file "~/.emacs.d/forOrgs/myscripts/ox-zotero/ox-zotero.el")

;; 方式二：加入 load-path
(add-to-list 'load-path "~/.emacs.d/forOrgs/myscripts/ox-zotero")
(require 'ox-zotero)
```

## 配置

```elisp
;; zot.py 脚本路径（默认值）
(setq org-zot-script-path "~/.claude/skills/zot-tool/scripts/zot.py")

;; Python 命令（默认 "python3"，Windows 上可能需改为 "python"）
(setq org-zot-python-command "python3")

;; 默认 Zotero item 类型
(setq org-zot-default-item-type "blogPost")

;; 默认 Collection key（可选）
(setq org-zot-default-collection-key "")
```

## Org 文件前置声明

在 `.org` 文件头部添加：

```org
#+TITLE: 我的文章标题
#+ZOTERO_ITEM_TYPE: blogPost
#+ZOTERO_COLLECTION: 4SETYG73
#+ZOTERO_TAGS: #标签1🔗, #标签2💻
#+ZOTERO_URL: https://example.com/post
#+ZOTERO_EXTRA: {"extra": "额外字段"}
```

- `#+TITLE:` —— **必填**，同时作为 Zotero 条目标题和附件文件名
- `#+ZOTERO_COLLECTION:` —— **必填**，8 位 key 或名称
- `#+ZOTERO_ITEM_TYPE:` —— 默认 `blogPost`
- `#+ZOTERO_ITEM_KEY` —— 首次 `z f` 后自动写回，无需手动设置

## 使用

`M-x org-export-dispatch` → `z` 打开导出菜单：

| 按键 | 功能 | 说明 |
|------|------|------|
| `z b` | HTML 预览 | 在 `*Zotero HTML Export*` buffer 中预览 |
| `z f` | 完整导出 | 创建条目 + HTML 附件 + Note → 写回 key |
| `z n` | 更新导出 | 更新附件 + Note（需要 `#+ZOTERO_ITEM_KEY`） |
| `z k` | 显示 key | 在 minibuffer 显示当前 item key |

## 导出行为

### `z f`（首次导出）

1. 提取元数据（`#+TITLE:`、`#+ZOTERO_TAGS:` 等）
2. ox-html 将 Org 导出为**完整 HTML**（含 `<html>`、`<head>`、`<body>`——与 `org-export-dispatch → h h` 结果一致）
3. `zot.py add` 创建 Zotero 条目
4. `zot.py attach` 上传完整 HTML 文件附件（文件名基于 title，如 `我的文章.html`）
5. `zot.py setnote` 写入**body-only HTML**（提取自完整 HTML）作为 child note
6. 写回 `#+ZOTERO_ITEM_KEY`

### `z n`（更新导出）

跳过创建条目步骤，直接更新附件和 Note。

### 错误处理

- 每次调用 zot.py 前会输出**可复现的命令行**（`🔧 cd ... && python3 zot.py ...`）
- 附件上传失败时**保留临时文件**，输出手动重试命令
- 所有后端输出通过 `*Messages*` buffer 可见

## CSS 样式配置

ox-zotero 不做任何 CSS 管理——HTML 的样式完全由 Org 文件通过标准 ox-html 机制控制。导出附件与 `org-export-dispatch → h h` 产生**完全一致**的 HTML。

### 推荐方式：`#+HTML_HEAD:` 内联 CSS

在 `.org` 文件头部声明内联样式（离线可用，无外部依赖）：

```org
#+HTML_HEAD: <style>
#+HTML_HEAD: /* 从 md2html 借鉴的 github-markdown.css 内容 */
#+HTML_HEAD: body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
#+HTML_HEAD: .markdown-body { max-width: 980px; margin: 0 auto; padding: 32px; }
#+HTML_HEAD: /* ... 更多样式 ... */
#+HTML_HEAD: </style>
```

### GitHub 风格样式

如需完整的 GitHub 风格排版，可参考 [md2html](https://github.com/zzeitt/md2html) 项目获取 `github-markdown.css` + `layout.css`，将其内联到 `#+HTML_HEAD:` 中：

```bash
# 获取 CSS 文件
git clone https://github.com/zzeitt/md2html.git /tmp/md2html
cd /tmp/md2html && ./scripts/install.sh
# github-markdown.css → lib/github-markdown.css
```

然后在 Org 文件中引用（内联方式）：

```org
#+HTML_HEAD: <style>
#+HTML_HEAD: /* 将 lib/layout.css + lib/github-markdown.css 内容粘贴到这里 */
#+HTML_HEAD: </style>
```

### AI / Agent 配置指引

如果你是 AI agent，在帮用户配置 Org 文件时：

1. 优先使用 `#+HTML_HEAD:` 内联 `<style>`——**不要**用 `<link>` 标签（Zotero 离线打开时外部路径不可达）
2. CSS 内容完全内联，不依赖 CDN 或网络资源
3. 常用最小样式模板：
   ```org
   #+HTML_HEAD: <style>
   #+HTML_HEAD: body { font-family: system-ui, sans-serif; line-height: 1.6;
   #+HTML_HEAD:        max-width: 800px; margin: 0 auto; padding: 2em; }
   #+HTML_HEAD: pre { background: #f5f5f5; padding: 1em; overflow-x: auto; }
   #+HTML_HEAD: code { font-family: "Cascadia Code", monospace; }
   #+HTML_HEAD: table { border-collapse: collapse; width: 100%; }
   #+HTML_HEAD: th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
   #+HTML_HEAD: </style>
   ```
4. 用户可随时修改或移除这些 CSS——ox-zotero 不限制

## 架构

单文件，由 ox-html 派生，不做模板覆盖——ox-html 生成什么 HTML，ox-zotero 就原样传输到 Zotero：

```
ox-zotero.el
  ├── defcustom 选项（3 个）
  ├── Subprocess Bridge（call-process-region 封装）
  ├── Collection 解析
  ├── 元数据提取 & zot.py 参数构建
  ├── Item 创建、附件上传、Note 写入
  ├── HTML 工具（org-zot--extract-body 提取 body 给 note）
  ├── Item Key 写回
  ├── 导出入口（z b / z f / z n / z k）
  └── Backend Definition（纯选项 + 菜单，无覆盖）
```

## 依赖链

```
ox-zotero.el
  ├── ox（org-export-define-derived-backend）
  ├── ox-html（父后端，所有 element transcoder）
  ├── json（ZOTERO_EXTRA 解析）
  └── zot.py CLI
        ├── zot add     → 创建 Zotero 条目
        ├── zot attach  → 上传 HTML 附件（WebDAV）
        └── zot setnote → 写入原始 Note（无 LLM 摘要）
```

## 许可

GPL v3

## 相关项目

- [zzeitt/zot-tool](https://github.com/zzeitt/zot-tool) —— Zotero CLI 管理工具
- [ox-conf](https://github.com/zzeitt/ox-conf) —— 同系列的 Confluence 导出后端
