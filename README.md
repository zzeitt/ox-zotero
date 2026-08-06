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
;; 将 ox-html-enhanced 和 ox-zotero 所在目录加入 load-path
(add-to-list 'load-path "/path/to/ox-html-enhanced")
(add-to-list 'load-path "/path/to/ox-zotero")

;; ox-html-enhanced 通过 advice 全局增强 ox-html，需先加载
(require 'ox-html-enhanced)
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
#+FILETAGS: :AI🤖:Emacs💜:技术🔧:
#+ZOTERO_ITEM_TYPE: blogPost
#+ZOTERO_COLLECTION: 4SETYG73
#+ZOTERO_URL: https://example.com/post
#+ZOTERO_EXTRA: {"extra": "额外字段"}
```

- `#+TITLE:` —— **必填**，同时作为 Zotero 条目标题和附件文件名
- `#+FILETAGS:` —— 可选，Org 原生语法（冒号分隔）。Create 时写入，Update 时同步覆盖
- `#+ZOTERO_COLLECTION:` —— **必填**，8 位 key 或名称
- `#+ZOTERO_ITEM_TYPE:` —— 默认 `blogPost`
- `#+ZOTERO_TAGS:` —— 可选（兼容旧版），逗号分隔。`#+FILETAGS:` 优先
- `#+ZOTERO_ATTACH_NAME:` —— 可选，自定义附件文件名（默认取自 `#+TITLE:`）
- `#+ZOTERO_ITEM_KEY` —— 首次 `z z` 后自动写回，无需手动设置

## 使用

`M-x org-export-dispatch` → `z` 打开导出菜单：

| 按键 | 功能 | 说明 |
|------|------|------|
| `z b` | 预览 | 在 `*Zotero HTML Export*` buffer 中预览 |
| `z z` | 创建或更新 | 无 key 则创建 + 写回，有 key 则更新 |
| `z o` | 打开 | 在 Zotero 桌面端打开当前条目 |
| `z k` | 显示 key | 在 minibuffer 显示当前 item key |

## 导出行为

### `z z`（创建或更新）

1. 提取元数据（`#+TITLE:`、`#+ZOTERO_TAGS:` 等）
2. ox-html 将 Org 导出为**完整 HTML**
3. **无 `#+ZOTERO_ITEM_KEY`** → `zot.py add` 创建条目 → 写回 key → 上传附件 + note
4. **已有 `#+ZOTERO_ITEM_KEY`** → 清理旧附件/Note → 重新上传 → 同步 tags
5. 上传 HTML 附件（文件名取自 `#+ZOTERO_ATTACH_NAME:` 或 `#+TITLE:`）
6. 写入 body-only HTML 作为 child note
7. 同步 tags：`#+ZOTERO_TAGS:` 为空则清空所有标签

### 错误处理

- 每次调用 zot.py 前会输出**可复现的命令行**（`🔧 cd ... && python3 zot.py ...`）
- 附件上传失败时**保留临时文件**，输出手动重试命令
- 所有后端输出通过 `*Messages*` buffer 可见

## CSS 样式 & HTML 增强

ox-zotero **不做任何 HTML 修改**——它从 ox-html 派生，透明传输 ox-html 的完整输出。

如需 CSS 自动内联、`.markdown-body` 容器、GitHub 风格排版等 HTML 层增强，请使用配套项目 **[ox-html-enhanced](https://github.com/zzeitt/ox-html-enhanced)**：

```elisp
;; ox-html-enhanced 通过 advice 全局增强 ox-html
;; 加载后 ox-zotero 导出自动获得增强后的 HTML
(require 'ox-html-enhanced)
(require 'ox-zotero)
```

ox-html-enhanced 负责：
- CSS 文件自动内联（`<style>` 标签，离线可用）
- `.markdown-body` 容器自动应用
- 其他 HTML 输出增强

### Agent 配置指引

如果你是 AI agent，帮用户配置时：

1. 先配置 ox-html-enhanced（CSS 内联、容器类等）
2. 再配置 ox-zotero（Zotero 集成）
3. 所有 CSS 内联，不依赖 CDN 或 `<link>` 标签

## 架构

单文件，由 ox-html 派生，不做任何模板覆盖或 HTML 过滤——ox-html 生成什么 HTML，ox-zotero 就原样传输到 Zotero：

```
ox-zotero.el
  ├── defcustom 选项（5 个）
  ├── Subprocess Bridge（call-process-region 封装）
  ├── Collection 解析
  ├── 元数据提取 & zot.py 参数构建
  ├── Item 创建、附件上传、Note 写入
  ├── HTML 工具（org-zot--extract-body 提取 body 给 note）
  ├── Item Key 写回
  ├── 导出入口（z b / z f / z n / z k）
  └── Backend Definition（纯选项 + 菜单，无覆盖，无 filter）
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
