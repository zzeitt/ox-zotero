;;; ox-zotero.el --- Zotero Back-End for Org Export Engine  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zeit

;; Author: zhongtao
;; Keywords: outlines, hypermedia

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; This is an org export backend that exports Org-mode articles to a
;; Zotero library.  It uses `zot.py' CLI as the backend bridge.
;;
;; Prerequisites:
;;   - zot.py configured with ZOTERO_API_KEY, ZOTERO_LIBRARY_ID, etc.
;;   - Org file with metadata: #+TITLE:, #+ZOTERO_TAGS:, etc.
;;
;; Exporting:
;;   - M-x org-export-dispatch, then press `z' prefix.
;;   - z b: Preview in buffer
;;   - z z: Create or update item + attachment + note
;;   - z a: Create or update attachment only (skip note)
;;   - z o: Open item in Zotero
;;   - z k: Show item key
;;
;; Options (in-buffer keywords):
;;   - #+ZOTERO_ITEM_TYPE: Zotero item type (default: blogPost)
;;   - #+ZOTERO_COLLECTION: Collection name or key
;;   - #+ZOTERO_TAGS: Comma-separated tags (e.g. #AI-ML🤖, #编程💻)
;;   - #+ZOTERO_URL: Source URL
;;   - #+ZOTERO_EXTRA: Extra JSON for additional fields
;;   - #+ZOTERO_ITEM_KEY: Existing item key (written back on first export)
;;   - #+ZOTERO_SYNCED_TAGS: Tag-sync snapshot (auto-written back)
;;   - #+ZOTERO_ATTACH_NAME: Custom attachment filename (default: <title>.html)
;;
;; Change Log:
;;   - 2026-07-24: Initial commit.
;;   - 2026-07-28: Removed redundant element transcoders (headline, link,
;;                 src-block, special-block) — all org→html conversion is
;;                 now handled by the parent ox-html backend.  Fixed
;;                 org-zot--extract-metadata to use the passed-in info plist.
;;                 Replaced addnote with attach: HTML is now uploaded as a
;;                 file attachment (via zot.py attach) instead of a child note.
;;   - 2026-07-29: Dual upload — both HTML attachment and child note are
;;                 created on export. Semantic filenames derived from #+TITLE.
;;                 Enhanced logging with reproducible zot.py command lines.
;;                 Fixed /dev/null → os.devnull for Windows compatibility.
;;                 Removed template/inner-template/filter overrides — ox-zotero
;;                 now transparently passes through ox-html's full output
;;                 (including #+HTML_HEAD: CSS). Attachment gets full standalone
;;                 HTML; note gets body-only content via org-zot--extract-body.
;;   - 2026-07-30: Removed CSS auto-inlining and HTML container transforms —
;;                 these now belong to ox-html-enhanced. ox-zotero is purely
;;                 a Zotero integration backend with no HTML modification.
;;                 Merged create/update into single `z z' command with
;;                 auto-detect. Added `z o' to open item in Zotero desktop.
;;   - 2026-09-04: Export through the `org-zot-html' backend (instead of bare
;;                 `html') so ox-html-enhanced can scope its static-math
;;                 (dvipng+base64) forcing to Zotero only; plain html and
;;                 ox-conf (Confluence) exports are no longer turned into
;;                 formula images.
;;   - 2026-11-06: Added `z a' (attachment only).  Skips note creation and
;;                 preserves existing child notes, avoiding the note-side
;;                 compression/upload work that makes `z z' slow.
;;   - 2026-11-06: Added batch LaTeX pre-rendering (`org-zot-batch-latex').
;;                 Cache misses are collected during a throw-away export
;;                 pass, then rendered in one multi-page latex run + one
;;                 dvipng call per chunk instead of one process pair per
;;                 formula.  ~235 formulas: 720s -> ~20s; output is
;;                 byte-identical to `org-create-formula-image'.

;;; Code:

(require 'ox)
(require 'ox-html)
(require 'json)
(require 'cl-lib)

;;; ======================================================================
;;;                         Custom Variables
;;; ======================================================================

(defcustom org-zot-python-command "python3"
  "Command to run Python interpreter for zot.py."
  :type 'string
  :group 'org-export-zotero)

(defcustom org-zot-script-path
  (expand-file-name "~/.claude/skills/zot-tool/scripts/zot.py")
  "Path to zot.py script."
  :type 'string
  :group 'org-export-zotero)

(defcustom org-zot-default-item-type "blogPost"
  "Default Zotero item type for new items.
See https://www.zotero.org/support/dev/web_api/v3/types_and_fields"
  :type 'string
  :group 'org-export-zotero)

(defcustom org-zot-default-collection-key ""
  "Default Zotero collection key.
If empty string, will prompt or fallback to Misc collection."
  :type 'string
  :group 'org-export-zotero)

(defcustom org-zot-tag-prefix ""
  "Optional prefix added to each tag when syncing to Zotero.
Set to \"#\" if you prefer Zotero tags to appear as #tag-name.
The prefix is applied at sync time — Org file tags are stored without it."
  :type 'string
  :group 'org-export-zotero)

(defcustom org-zot-debug nil
  "When non-nil, emit diagnostic messages during export.
Includes md5 fingerprints and content previews for tracing
stale HTML issues in the export pipeline."
  :type 'boolean
  :group 'org-export-zotero)

(defcustom org-zot-batch-latex t
  "When non-nil, batch-render missing LaTeX formula images before export.
Org's per-formula `org-create-formula-image' starts a fresh latex and
dvipng process for every cache miss, which is very slow on Windows
(several seconds per formula).  Batch rendering puts all missing
formulas in one multi-page LaTeX document, compiles it once, and
converts every page with one dvipng call.  Output is byte-identical to
per-formula rendering (both use the same preamble/dpi), but for a few
hundred formulas it drops a ~12 minute export to ~20 seconds.

Only applies to the dvipng renderer.  If batch rendering fails, the
export transparently falls back to the normal per-formula path."
  :type 'boolean
  :group 'org-export-zotero)

;;; ======================================================================
;;;                   Subprocess Bridge (zot.py)
;;; ======================================================================

(defun org-zot--command-string (args)
  "Return a shell-reproducible command string for zot.py with ARGS."
  (concat "cd " (shell-quote-argument (file-name-directory org-zot-script-path))
          " && " org-zot-python-command
          " " (shell-quote-argument org-zot-script-path)
          " " (mapconcat #'shell-quote-argument args " ")))

(defun org-zot--call-zot (args &optional stdin-str)
  "Call zot.py with ARGS (list of strings).  Optionally pipe STDIN-STR.
Returns a cons cell: (exit-code . output-string)."
  (let* ((default-directory (file-name-directory org-zot-script-path))
         (has-stdin (and stdin-str (not (string-empty-p stdin-str))))
         (cmd-str (org-zot--command-string args)))
    ;; Log the reproducible command
    (message "🔧 %s" cmd-str)
    (with-temp-buffer
      (when has-stdin
        (insert stdin-str))
      ;; Pin UTF-8 for both argv and stdin.  Without this, Windows
      ;; `call-process-region' encodes command-line arguments in the
      ;; console code page, so Chinese filenames (e.g. attachment names
      ;; derived from #+TITLE) reach zot.py as spaces and lookups fail.
      (let* ((coding-system-for-write 'utf-8-unix)
             (exit-code
              (apply #'call-process-region
                     (point-min) (point-max)
                     org-zot-python-command
                     has-stdin
                     (current-buffer)
                     nil
                     org-zot-script-path
                     args)))
        (let ((output (buffer-string)))
          (if (= 0 exit-code)
              (let ((trimmed (string-trim output)))
                (if (string-empty-p trimmed)
                    (message "✅ zot.py OK")
                  ;; Surface zot.py's stdout even on exit 0: zot.py often
                  ;; prints ❌/⚠️ then returns None WITHOUT a non-zero exit
                  ;; (e.g. stale/deleted item key, missing WebDAV), which
                  ;; would otherwise be masked as a misleading "OK".
                  (message "zot.py: %s" trimmed)))
            (message "❌ zot.py exit=%d\n  CMD: %s\n  STDOUT:\n%s\n  STDERR: (see above or run CMD manually)"
                     exit-code cmd-str output))
          (cons exit-code output))))))

(defun org-zot--call-zot-ok (args &optional stdin-str)
  "Like `org-zot--call-zot' but returns output on success, nil on failure.
A call counts as failure when zot.py exits non-zero OR prints \"❌\" on
stdout — zot.py reports many errors (stale item key, WebDAV failure, ...)
by printing \"❌ ...\" yet still exiting 0.  Relying on the exit code
alone would mistake those for success and, in tag sync, advance the
#+ZOTERO_SYNCED_TAGS snapshot even though the tags never landed."
  (let* ((result (org-zot--call-zot args stdin-str))
         (exit-code (car result))
         (output (cdr result)))
    (if (and (= 0 exit-code)
             (not (string-match-p "❌" output)))
        output
      (message "⚠️ zot.py failed (exit=%d%s) — reproduce with:\n  %s"
               exit-code
               (if (string-match-p "❌" output) ", ❌ on stdout" "")
               (org-zot--command-string args))
      nil)))

;;; ======================================================================
;;;                   Collection Resolution
;;; ======================================================================

(defun org-zot--find-collection (name-or-key)
  "Resolve NAME-OR-KEY to a Zotero collection key.
If it looks like an 8-character key, return it directly.
Otherwise, search collections by name."
  (if (and (= (length name-or-key) 8)
           (string-match-p "^[A-Z0-9]+$" name-or-key))
      ;; Looks like a Zotero key — use directly
      name-or-key
    ;; Search by name in `zot coll list' output
    (let ((output (org-zot--call-zot-ok '("coll" "list"))))
      (when output
        (with-temp-buffer
          (insert output)
          (goto-char (point-min))
          ;; Look for "  • <name>" followed by "    Key: <key>"
          (when (search-forward (format "  • %s" name-or-key) nil t)
            (when (re-search-forward "Key: \\([A-Z0-9]+\\)"
                                     (line-end-position) t)
              (match-string 1))))))))

;;; ======================================================================
;;;                   Metadata Extraction
;;; ======================================================================

(defun org-zot--extract-metadata (info)
  "Extract Zotero item fields from the export communication channel INFO.
Returns a plist with keys: :title :item-type :url :coll-key :tags :synced-tags :extra."
  (let* ((item-type (or (plist-get info :zotero-item-type)
                        org-zot-default-item-type))
         (title (car (plist-get info :title)))
         (zotero-url (plist-get info :zotero-url))
         (zotero-tags-raw (plist-get info :zotero-tags))
         (zotero-extra (plist-get info :zotero-extra))
         (zotero-coll (plist-get info :zotero-collection))
         (zotero-key (plist-get info :zotero-item-key))
         ;; Tags: prefer Org native :filetags, fallback to #+ZOTERO_TAGS:
         (org-filetags (plist-get info :filetags))
         (tags (cond
                ;; Org native filetags: already a list, e.g. ("tag1" "tag2")
                (org-filetags org-filetags)
                ;; Fallback: #+ZOTERO_TAGS: "tag1, tag2" → ("tag1" "tag2")
                ((and zotero-tags-raw (not (string-empty-p zotero-tags-raw)))
                 (mapcar #'string-trim (split-string zotero-tags-raw ",")))
                (t nil)))
         ;; Last-synced snapshot of Org tags (#+ZOTERO_SYNCED_TAGS:)
         (synced-tags (let ((raw (plist-get info :zotero-synced-tags)))
                        (and raw (not (string-empty-p raw))
                             (mapcar #'string-trim (split-string raw ",")))))
         ;; Default URL to file:// if none specified
         (url (or zotero-url
                  (when buffer-file-name
                    (concat "file:///" buffer-file-name))))
         ;; Resolve collection
         (coll-key (if zotero-coll
                       (org-zot--find-collection zotero-coll)
                     org-zot-default-collection-key)))
    (list :title title
          :item-type item-type
          :url (or url "")
          :coll-key (or coll-key "")
          :tags tags
          :synced-tags synced-tags
          :extra zotero-extra
          :item-key zotero-key)))

(defun org-zot--build-add-args (metadata)
  "Build command-line arguments for `zot.py add' from METADATA plist.
Returns a list of strings suitable for `org-zot--call-zot'."
  (let* ((item-type (plist-get metadata :item-type))
         (title (plist-get metadata :title))
         (url (plist-get metadata :url))
         (coll-key (plist-get metadata :coll-key))
         (extra (plist-get metadata :extra))
         (tags (plist-get metadata :tags))
         (extra-json nil))
    (org-zot--check-tags tags)
    ;; Build extra JSON
    (let ((extra-alist nil))
      (when tags
        (let ((prefixed (org-zot--prefix-tags tags)))
          (push (cons 'tags
                      (vconcat
                       (mapcar (lambda (tag)
                                 `((tag . ,tag) (type . 1)))
                               prefixed)))
                extra-alist)))
      (when extra
        (condition-case nil
            (let ((parsed (json-parse-string extra)))
              (dolist (key (json-object-keys parsed))
                (push (cons (intern key) (json-object-get parsed key))
                      extra-alist)))
          (error (message "⚠️ Invalid JSON in #+ZOTERO_EXTRA, ignoring"))))
      (setq extra-json (if extra-alist
                           (json-encode extra-alist)
                         nil)))
    ;; Build args list
    (append (list "item" "add" item-type title url coll-key)
            (when extra-json
              (list extra-json)))))

;;; ======================================================================
;;;                   Item & Attachment Helpers
;;; ======================================================================

(defun org-zot--create-item (metadata)
  "Create a new Zotero item using METADATA plist.
Returns the new item key on success, nil on failure."
  (let ((args (org-zot--build-add-args metadata))
        (title (plist-get metadata :title)))
    (unless title
      (error "No #+TITLE: found — cannot create Zotero item"))
    (let ((output (org-zot--call-zot-ok args)))
      (when output
        ;; Parse item key from output: "✅ Created item: ABCDEFGH"
        (if (string-match "✅ Created item: \\([A-Z0-9]+\\)" output)
            (match-string 1 output)
          (progn
            (message "⚠️ Could not parse item key from output:\n%s" output)
            nil))))))

(defun org-zot--sanitize-filename (title)
  "Convert TITLE to a safe filename, keeping semantic meaning.
Replaces whitespace and special chars with hyphens, strips leading/trailing
cruft, and limits length to 80 chars.  Returns a name like \"My-Post.html\"."
  (let* ((name (replace-regexp-in-string "[/\\:*?\"<>|]" "" title))
         (name (replace-regexp-in-string "[[:space:]]+" "-" name))
         (name (replace-regexp-in-string "-+" "-" name))
         (name (replace-regexp-in-string "\\`-+\\|-+\\'" "" name))
         (name (if (> (length name) 80)
                   (concat (substring name 0 80) "")
                 name)))
    (concat name ".html")))

(defun org-zot--attach-file (item-key html-content &optional archive-filename)
  "Upload HTML-CONTENT as a file attachment to Zotero item ITEM-KEY.
If ARCHIVE-FILENAME is given, it is used as the attachment filename
in Zotero (e.g. \"My-Post.html\").  Otherwise falls back to a random name.
On success, cleans up the temp file.  On failure, keeps the temp
file so you can retry manually.
Returns t on success, nil on failure."
  (let* ((fname (or archive-filename "ox-zotero-export.html"))
         (tmpdir (make-temp-file "ox-zotero-" t))
         (tmpfile (expand-file-name fname tmpdir))
         (success nil))
    (make-directory (file-name-directory tmpfile) t)
    ;; HTML may contain non-ASCII text; pin UTF-8 so batch exports never
    ;; block on `select-safe-coding-system'.
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file tmpfile
        (insert html-content)))
    (message "📝 HTML saved to: %s" tmpfile)
    (unwind-protect
        (let ((args (if archive-filename
                        (list "attachment" "add" item-key tmpfile archive-filename)
                      (list "attachment" "add" item-key tmpfile))))
          (let ((output (org-zot--call-zot-ok args)))
            (if (and output (string-match "✅ Attachment saved" output))
                (setq success t)
              (progn
                (message "⚠️ Attachment upload failed\n  Temp file: %s\n  Retry: %s"
                         tmpfile
                         (org-zot--command-string args))
                nil))))
      ;; Clean up temp directory on success
      (if success
          (progn
            (delete-directory tmpdir t)
            (message "🧹 Cleaned up: %s" tmpdir))
        (message "💾 Temp file kept for debugging: %s" tmpfile)))
    success))

(defun org-zot--add-note (item-key html-content)
  "Add HTML-CONTENT as a child note to Zotero item ITEM-KEY.
Uses `zot.py note set' with the HTML piped via stdin.
Returns t on success, nil on failure."
  (message "📝 Adding note to item: %s" item-key)
  (let ((output (org-zot--call-zot-ok (list "note" "set" item-key) html-content)))
    (if output
        (progn
          (let ((msg (string-trim output)))
            (unless (string-empty-p msg)
              (message "ℹ️ zot.py: %s" msg)))
          (message "✅ Note added to item: %s" item-key)
          t)
      (progn
        (message "⚠️ Note upload failed for item: %s" item-key)
        nil))))

(defun org-zot--prefix-tags (tags)
  "Apply `org-zot-tag-prefix' to each tag in TAGS.
Returns a new list with the prefix prepended to each tag.
When `org-zot-tag-prefix' is empty, returns TAGS unchanged."
  (if (or (null org-zot-tag-prefix)
          (string-empty-p org-zot-tag-prefix))
      tags
    (mapcar (lambda (tag) (concat org-zot-tag-prefix tag)) tags)))

(defun org-zot--set-difference (a b)
  "Return elements of A not present in B (comparison by string equality)."
  (let ((result nil))
    (dolist (x a)
      (unless (member x b)
        (push x result)))
    (nreverse result)))

(defun org-zot--write-synced-tags (tags)
  "Write TAGS as #+ZOTERO_SYNCED_TAGS in the current buffer.
TAGS is a list of unprefixed tag strings — the last-synced snapshot."
  (let ((line (if tags
                  (concat "#+ZOTERO_SYNCED_TAGS: "
                          (mapconcat #'identity tags ", "))
                "#+ZOTERO_SYNCED_TAGS:")))
    (save-excursion
      (goto-char (point-min))
      (if (re-search-forward "^#\\+ZOTERO_SYNCED_TAGS:" nil t)
          (let ((beg (line-beginning-position))
                (end (line-end-position)))
            (delete-region beg end)
            (insert line))
        (goto-char (point-min))
        (when (re-search-forward "^#\\+\\(TITLE\\|AUTHOR\\|DATE\\|ZOTERO\\)" nil t)
          (forward-line 1))
        (insert (concat line "\n"))))))

(defun org-zot--has-tag-source-p ()
  "Return non-nil when the current buffer has a non-empty tag source.
Looks for `#+FILETAGS:' or `#+ZOTERO_TAGS:' with an actual value."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^#\\+\\(?:FILETAGS\\|ZOTERO_TAGS\\):[ \t]*\\S-" nil t)))

(defun org-zot--check-tags (tags)
  "Warn about TAGS that are malformed for Zotero or for the snapshot.
Returns TAGS unchanged; only emits diagnostics.  Catches the common
`#+FILETAGS: a b' mistake (space-separated parses as ONE tag) and tags
that already carry `org-zot-tag-prefix'."
  (dolist (tag tags)
    (cond
     ((string-match-p "[ \t]" tag)
      (message "⚠️  Tag %S contains whitespace — if from #+FILETAGS, use colon syntax `#+FILETAGS: :tag1:tag2:' (space-separated parses as one tag)." tag))
     ((string-match-p "," tag)
      (message "⚠️  Tag %S contains a comma — it will corrupt the #+ZOTERO_SYNCED_TAGS snapshot; rename it." tag))
     ((and (not (null org-zot-tag-prefix))
           (not (string-empty-p org-zot-tag-prefix))
           (string-prefix-p org-zot-tag-prefix tag))
      (message "⚠️  Tag %S already starts with prefix %S — store Org tags WITHOUT the prefix; it is added at sync time." tag org-zot-tag-prefix))))
  tags)

(defun org-zot--sync-tags (item-key tags synced-tags)
  "Push tags newly added in Org to Zotero item ITEM-KEY.

TAGS is the current Org tag list (from #+FILETAGS: or #+ZOTERO_TAGS:).
SYNCED-TAGS is the last-synced snapshot (#+ZOTERO_SYNCED_TAGS:).

Zotero is authoritative: only tags that appeared in Org since the last
sync are pushed, via idempotent `zot tag add'.  Tags removed in Org are
NOT removed from Zotero (delete there instead), and tags removed in
Zotero are never resurrected.  System tags like /unread stay untouched.

The snapshot only advances on success, so a failed `zot tag add' never
records a false \"synced\" state that would block a later retry."
  (let* ((new-tags (org-zot--set-difference tags synced-tags))
         (prefixed (org-zot--prefix-tags new-tags)))
    (cond
     ;; No tags at all in this file → tell the user how to opt in.  When
     ;; a source line exists but is empty, clear the snapshot; when the
     ;; file has no tag source whatsoever, leave it alone entirely.
     ((null tags)
      (if (org-zot--has-tag-source-p)
          (progn
            (org-zot--write-synced-tags nil)
            (message "🏷️  No tags in #+FILETAGS/#+ZOTERO_TAGS — cleared snapshot."))
        (message "ℹ️  No #+FILETAGS or #+ZOTERO_TAGS in this file — nothing to sync.\n   Add e.g. `#+FILETAGS: :tag1:tag2:' to manage Zotero tags.")))
     ;; New tags → push them, and only advance the snapshot on success.
     (prefixed
      (let ((tag-str (mapconcat #'identity prefixed ", ")))
        (message "🏷️  Adding new tags: %s" tag-str)
        (if (org-zot--call-zot-ok
             (append (list "tag" "add" item-key) prefixed))
            (progn
              (org-zot--write-synced-tags tags)
              (message "✅ Tags synced: %s" tag-str))
          (message "⚠️ Tag sync failed for item: %s — snapshot NOT updated" item-key))))
     (t
      (org-zot--write-synced-tags tags)
      (message "🏷️  No new tags to sync")))))

(defun org-zot--parse-children (output)
  "Parse children from `zot.py attachment list' OUTPUT.
Returns a plist (:attachments ((key . name) ...) :notes ((key . preview) ...)).
Parses line-by-line: each 🔑 line contains either a MIME type (attachment)
or a quoted string (note).  v2.0.0+ format with linkMode field is handled."
  (let ((attachments nil)
        (notes nil))
    (dolist (line (split-string output "\n"))
      (when (string-match
             "🔑\\s-+\\([A-Z0-9]\\{8\\}\\)\\s-*|\\s-*\\(.+\\)" line)
        (let ((key (match-string 1 line))
              (rest (string-trim (match-string 2 line))))
          (cond
           ;; Note: starts with a double-quote
           ((string-prefix-p "\"" rest)
            (push (cons key (string-trim rest "\"" "\"")) notes))
           ;; Attachment: contains a MIME type (has a slash)
           ((string-match-p "/" rest)
            ;; v2.0.0 format: "text/html | linkMode=xxx | filename.html"
            ;; Extract filename from last pipe segment
            (let ((name (if (string-match "|\\s-*\\([^|]+\\)\\'" rest)
                            (string-trim (match-string 1 rest))
                          ;; Fallback: take first field (content-type)
                          (car (split-string rest "|" t "\\s-*")))))
              (push (cons key name) attachments)))))))
    (list :attachments (nreverse attachments)
          :notes (nreverse notes))))

(defun org-zot--update-attachment (item-key html-content attach-name
                                            &optional keep-notes)
  "Upload or re-upload HTML-CONTENT as a file attachment to ITEM-KEY.
Uses `zot attachment update' if an existing attachment child exists,
otherwise falls back to `zot attachment add'.  Old notes are removed
before `zot note set' creates a fresh one.

When KEEP-NOTES is non-nil, existing child notes are left untouched and
no note is expected to be recreated — used by the attachment-only export
(`z a'), which must never delete notes it is not going to regenerate.

Returns t on success, nil on failure.  Signals `user-error' when the
item cannot be listed at all (e.g. stale/deleted #+ZOTERO_ITEM_KEY)."
  (let* ((output (org-zot--call-zot-ok (list "attachment" "list" item-key)))
         ;; `org-zot--call-zot-ok' returns nil only on real failure (non-zero
         ;; exit or ❌ on stdout) — most commonly a stale #+ZOTERO_ITEM_KEY
         ;; whose item was deleted (HTTP 404 "Item does not exist").  That is
         ;; NOT the same as "no children": treating it as an empty parent would
         ;; mask the 404 and attempt `attachment add' against a dead item,
         ;; failing a second time with a confusing error.  Abort here instead,
         ;; with recovery guidance, before any temp file is written.
         (children (if output (org-zot--parse-children output)
                     (user-error
                      (concat "Zotero item %s is not found or not accessible "
                              "(see zot.py error above).  If it was deleted, remove "
                              "#+ZOTERO_ITEM_KEY and run `z z' again to create a "
                              "new item — or replace it with the correct key.")
                      item-key)))
         (att-entries (plist-get children :attachments))
         (note-entries (plist-get children :notes)))
    (message "🔍 Parsed children: %d attachment(s), %d note(s)"
             (length att-entries) (length note-entries))
    (let* ((tmpdir (make-temp-file "ox-zotero-" t))
         (fname (or attach-name "ox-zotero-export.html"))
         (tmpfile (expand-file-name fname tmpdir))
         (success nil))
    ;; Write HTML to temp file.  Pin UTF-8: the HTML contains non-ASCII
    ;; text and batch exports cannot answer a coding-system prompt.
    (make-directory (file-name-directory tmpfile) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file tmpfile
        (insert html-content)))
    (message "📝 HTML saved to: %s" tmpfile)
    (when org-zot-debug
      (message "🔬 DIAG-update: html-content md5=%s len=%d"
               (md5 html-content) (length html-content)))
    ;; Remove old notes (note set will create a fresh one), unless the
    ;; caller is an attachment-only export that will not recreate them.
    (unless keep-notes
      (dolist (entry note-entries)
        (org-zot--call-zot-ok (list "attachment" "remove" (car entry)))
        (message "🗑️  Detached old note: %s (%s)" (car entry) (cdr entry))))
    (when keep-notes
      (message "📝 Keeping %d existing note(s) untouched" (length note-entries)))
    (unwind-protect
        (cond
         ;; Existing attachment → reattach to first, detach extras
         (att-entries
          (let ((first-key (car (car att-entries)))
                (first-name (cdr (car att-entries)))
                (extra (cdr att-entries)))
            (message "🔄 Reattaching to child: %s (%s)" first-key first-name)
            (setq success
                  (if (org-zot--call-zot-ok
                       (list "attachment" "update" first-key tmpfile fname))
                      t
                    nil))
            (dolist (entry extra)
              (org-zot--call-zot-ok (list "attachment" "remove" (car entry)))
              (message "🗑️  Detached extra attachment: %s (%s)"
                       (car entry) (cdr entry)))))
         ;; No existing attachment → create new
         (t
          (message "📎 Creating new attachment for item: %s" item-key)
          (setq success
                (if (let ((output (org-zot--call-zot-ok
                                   (list "attachment" "add" item-key tmpfile fname))))
                      (and output
                           (string-match "✅ Attachment saved" output)))
                    t
                  nil))))
      ;; Cleanup
      (if success
          (progn
            (delete-directory tmpdir t)
            (message "🧹 Cleaned up: %s" tmpdir))
        (message "💾 Temp file kept for debugging: %s" tmpfile)))
    success)))

;;; ======================================================================
;;;                   In-Buffer Keyword Write-back
;;; ======================================================================

(defun org-zot--write-item-key (item-key)
  "Write ITEM-KEY as #+ZOTERO_ITEM_KEY in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "^#\\+ZOTERO_ITEM_KEY:" nil t)
        ;; Update existing line
        (let ((beg (line-beginning-position))
              (end (line-end-position)))
          (delete-region beg end)
          (insert (format "#+ZOTERO_ITEM_KEY: %s" item-key)))
      ;; Insert after first keyword block
      (goto-char (point-min))
      (when (re-search-forward "^#\\+\\(TITLE\\|AUTHOR\\|DATE\\|ZOTERO\\)" nil t)
        (forward-line 1))
      (insert (format "#+ZOTERO_ITEM_KEY: %s\n" item-key)))))

;;; ======================================================================
;;;                         HTML Utilities
;;; ======================================================================

(defun org-zot--extract-body (full-html)
  "Extract body content from FULL-HTML.
Returns everything between <body> and </body> tags.
Used for Zotero note content, which should be body-only HTML.
Returns FULL-HTML unchanged if no <body> tag found."
  (let ((start (string-match "<body[^>]*>" full-html)))
    (if start
        (let ((body-start (match-end 0)))
          (if (string-match "</body>" full-html body-start)
              (substring full-html body-start (match-beginning 0))
            full-html))
      full-html)))

;;; ======================================================================
;;;                Batch LaTeX Image Pre-rendering
;;; ======================================================================

(defvar org-zot--collect-latex nil
  "When non-nil, record `org-create-formula-image' calls instead of running.
Bound dynamically around a throw-away export pass to collect the exact
formulas and cache paths that would be rendered one by one.")

(defvar org-zot--pending-latex nil
  "List of (STRING TOFILE OPTIONS) collected during a prewarm pass.")

(defun org-zot--capture-formula-image
    (orig string tofile options buffer &optional processing-type)
  "Around-advice for `org-create-formula-image'.
While `org-zot--collect-latex' is non-nil, this is an export (not a
preview), and the renderer is dvipng, record the call instead of
rendering.  Everything else goes through ORIG unchanged."
  (if (and org-zot--collect-latex
           (null buffer)
           (eq (or processing-type org-preview-latex-default-process)
               'dvipng))
      (progn
        (push (list string tofile options) org-zot--pending-latex)
        nil)
    (funcall orig string tofile options buffer processing-type)))

(advice-add 'org-create-formula-image :around
            #'org-zot--capture-formula-image)

(defun org-zot--latex-preamble ()
  "Return the LaTeX preamble `org-create-formula-image' would use."
  (or (plist-get (alist-get 'dvipng org-preview-latex-process-alist)
                 :latex-header)
      (org-latex-make-preamble
       (org-export-get-environment (org-export-get-backend 'latex))
       org-format-latex-header 'snippet)))

(defun org-zot--latex-color-rgb (color)
  "Return COLOR formatted for \\definecolor, or nil when unusable."
  (cond
   ((null color) nil)
   ((eq color 'default) nil)          ; needs face lookup -> fall back
   ((and (stringp color) (string= color "Transparent")) nil)
   ((stringp color) (org-latex-color-format color))
   (t nil)))

(defun org-zot--batch-render-latex-chunk (entries)
  "Render ENTRIES in one multi-page LaTeX document.
Each entry is (STRING TOFILE OPTIONS).  Compiles once with latex, then
converts every page with one dvipng invocation and copies the pages to
their TOFILE cache paths.  Return non-nil on success."
  (let* ((tmpdir (make-temp-file "ox-zot-latex-" t))
         (texfile (expand-file-name "batch.tex" tmpdir))
         (dvifile (expand-file-name "batch.dvi" tmpdir))
         (pagepat (expand-file-name "page%d.png" tmpdir))
         (options (nth 2 (car entries)))
         (fg (or (plist-get options :html-foreground) "Black"))
         (bg (or (plist-get options :html-background) "Transparent"))
         (fg-rgb (org-zot--latex-color-rgb fg))
         (bg-rgb (org-zot--latex-color-rgb bg))
         (transparent (and (stringp bg) (string= bg "Transparent")))
         (dpi (* (or (plist-get options :html-scale) 1.0) 140.0))
         (ok nil))
    (if (or (null fg-rgb)
            (and (not transparent) (null bg-rgb)))
        nil                             ; unsupported colors -> fallback
      (unwind-protect
          (condition-case err
              (progn
                ;; Formulas may contain non-ASCII (e.g. Chinese) text;
                ;; without this, write-region may prompt for a coding
                ;; system, which fails in batch (EOF on stdin).
                (let ((coding-system-for-write 'utf-8-unix))
                  (with-temp-file texfile
                    (insert (org-zot--latex-preamble))
                    (insert "\n\\begin{document}\n")
                    (insert (format "\\definecolor{fg}{rgb}{%s}%%\n" fg-rgb))
                    (when bg-rgb
                      (insert (format "\\definecolor{bg}{rgb}{%s}%%\n"
                                      bg-rgb))
                      (insert "\n\\pagecolor{bg}%\n"))
                    (cl-loop for (string _tofile _opts) in entries
                             for i from 0
                             do (insert "\n{\\color{fg}\n")
                             (let ((s (copy-sequence string)))
                               (if (string-suffix-p "\n" s)
                                   (aset s (1- (length s)) ?%)
                                 (setq s (concat s "%")))
                               (insert s))
                             (insert "\n}\n")
                             (unless (= i (1- (length entries)))
                               (insert "\\newpage\n")))
                    (insert "\n\\end{document}\n")))
                ;; LaTeX exits non-zero on non-fatal errors while still
                ;; producing a usable DVI (this is common with snippets),
                ;; so judge success by the output, not the status.
                (let ((status (call-process
                               "latex" nil nil nil
                               "-interaction" "nonstopmode"
                               "-output-directory" tmpdir texfile)))
                  (unless (file-exists-p dvifile)
                    (error "latex produced no DVI (status %S)" status)))
                (let ((args (append (list "-D" (format "%s" dpi) "-T" "tight")
                                    (when transparent
                                      (list "-bg" "Transparent"))
                                    (list "-o" pagepat dvifile))))
                  (apply #'call-process "dvipng" nil nil nil args)
                  (unless (directory-files tmpdir nil "\\`page[0-9]+\\.png\\'")
                    (error "dvipng produced no pages")))
                (let ((pages
                       (sort
                        (delq nil
                              (mapcar
                               (lambda (f)
                                 (when (string-match
                                        "\\`page\\([0-9]+\\)\\.png\\'" f)
                                   (cons (string-to-number
                                          (match-string 1 f))
                                         f)))
                               (directory-files tmpdir)))
                        (lambda (a b) (< (car a) (car b))))))
                  (unless (= (length pages) (length entries))
                    (error "page count mismatch: %d rendered, %d expected"
                           (length pages) (length entries)))
                  (cl-loop for (_string tofile _opts) in entries
                           for (_num . page) in pages
                           do (let ((dir (file-name-directory tofile)))
                                (when dir (make-directory dir t))
                                (copy-file (expand-file-name page tmpdir)
                                           tofile t)))
                  (setq ok t)))
            (error
             (let ((log (expand-file-name "batch.log" tmpdir)))
               (message "⚠️ Batch LaTeX chunk failed (%s)%s"
                        (error-message-string err)
                        (if (file-exists-p log)
                            (with-temp-buffer
                              (insert-file-contents log)
                              (goto-char (point-min))
                              (let (lines)
                                (while (re-search-forward "^!.*$" nil t)
                                  (push (match-string-no-properties 0) lines))
                                (if lines
                                    (concat "\n"
                                            (mapconcat #'identity
                                                       (last (nreverse lines) 5)
                                                       "\n"))
                                  "")))
                          "")))))
        (delete-directory tmpdir t))
      ok)))

(defun org-zot--prewarm-latex (entries &optional chunk-size)
  "Render ENTRIES, batching CHUNK-SIZE formulas per LaTeX run.
Falls back to per-formula rendering for any chunk that fails.
Returns the number of images processed."
  (let ((chunk-size (or chunk-size 60))
        (total 0))
    (while entries
      (let* ((n (min chunk-size (length entries)))
             (chunk (cl-subseq entries 0 n)))
        (setq entries (nthcdr n entries))
        (if (org-zot--batch-render-latex-chunk chunk)
            (message "⚡ Batch-rendered %d LaTeX image(s)" n)
          (message "⚠️ Falling back to %d individual LaTeX render(s)..." n)
          (dolist (entry chunk)
            (org-create-formula-image
             (nth 0 entry) (nth 1 entry) (nth 2 entry) nil 'dvipng)))
        (setq total (+ total n))))
    total))

(defun org-zot--export-as (subtreep visible-only ext-plist)
  "Export with `org-zot-html', batching missing LaTeX images first.
The first pass records cache misses instead of rendering them; if any
are found, they are batch-rendered and the export is repeated.  A warm
cache costs nothing extra (one export pass, no formula calls)."
  (if (not org-zot-batch-latex)
      (org-export-as 'org-zot-html subtreep visible-only nil ext-plist)
    (let* ((org-zot--collect-latex t)
           (org-zot--pending-latex nil)
           (html (org-export-as 'org-zot-html subtreep visible-only nil
                                ext-plist)))
      (if (null org-zot--pending-latex)
          html
        (let ((seen (make-hash-table :test #'equal))
              (unique nil))
          (dolist (entry (nreverse org-zot--pending-latex))
            (unless (gethash (nth 1 entry) seen)
              (puthash (nth 1 entry) t seen)
              (push entry unique)))
          (setq unique (nreverse unique))
          (message "⚡ %d missing LaTeX image(s); batch-rendering..."
                   (length unique))
          (let ((org-zot--collect-latex nil))
            (org-zot--prewarm-latex unique)
            (message "✅ LaTeX prewarm done; re-exporting HTML...")
            (org-export-as 'org-zot-html subtreep visible-only nil
                           ext-plist)))))))

;;; ======================================================================
;;;                     Export Entry Points
;;; ======================================================================

(defun org-zot-export-to-buffer
    (&optional async subtreep visible-only body-only ext-plist)
  "Export current org buffer as HTML and display in a preview buffer.
The HTML shown is what would be sent as a Zotero note."
  (interactive)
  (org-export-to-buffer 'org-zot-html "*Zotero HTML Export*"
    async subtreep visible-only body-only ext-plist
    (lambda () (html-mode))))

(defun org-zot--export-to-zotero-core (skip-note subtreep visible-only ext-plist)
  "Export org article to Zotero — shared orchestration for `z z' and `z a'.
When SKIP-NOTE is non-nil, only the file attachment is written: existing
child notes are left untouched and no `zot note set' call is made.  That
skips zot.py's note-side image compression/size fitting, which re-encodes
every embedded formula PNG against the note size budget.  The HTML export
itself still runs (the attachment needs the same standalone HTML), and
item creation, key write-back, and tag sync run in both modes."
  (let* ((info-plist (org-combine-plists
                      ext-plist
                      (org-export--get-inbuffer-options 'org-zot-html)))
         (metadata (org-zot--extract-metadata info-plist))
         (item-key (plist-get metadata :item-key))
         (coll-key (plist-get metadata :coll-key))
         (title    (plist-get metadata :title))
         (attach-name (or (plist-get info-plist :zotero-attach-name)
                          (org-zot--sanitize-filename title))))

    (unless title
      (user-error "No #+TITLE: found in buffer"))
    (unless (and coll-key (not (string-empty-p coll-key)))
      (user-error "No collection specified. Set #+ZOTERO_COLLECTION or org-zot-default-collection-key"))

    (let* ((full-html (org-zot--export-as subtreep visible-only ext-plist))
           (body-html (unless skip-note (org-zot--extract-body full-html))))
      (unless (and full-html (not (string-empty-p (string-trim full-html))))
        (user-error "Export produced empty output"))
      (when org-zot-debug
        (message "🔬 DIAG-export: skip-note=%s body md5=%s len=%s first-150=%s"
                 skip-note
                 (if body-html (md5 body-html) "n/a")
                 (if body-html (length body-html) "n/a")
                 (if body-html
                     (substring body-html 0 (min 150 (length body-html)))
                   "n/a")))
      (if item-key
          ;; Update: replace attachment in-place; note only when not skipped
          (progn
            (message "%s item: %s"
                     (if skip-note "Updating attachment only on" "Uploading to")
                     item-key)
            (if (org-zot--update-attachment item-key full-html attach-name skip-note)
                (progn
                  (unless skip-note
                    (message "Updated: %s" item-key)
                    (org-zot--add-note item-key body-html))
                  (org-zot--sync-tags item-key (plist-get metadata :tags)
                                      (plist-get metadata :synced-tags))
                  (when skip-note
                    (message "✅ Attachment updated — note skipped: %s" item-key)))
              (user-error "Failed to upload attachment")))
        ;; Create: new item, write back key, upload
        (message "Creating Zotero item...")
        (let ((new-key (org-zot--create-item metadata)))
          (if new-key
              (progn
                (message "Uploading HTML attachment...")
                (if (org-zot--attach-file new-key full-html attach-name)
                    (progn
                      (org-zot--write-item-key new-key)
                      (let ((md-tags (plist-get metadata :tags)))
                        (if md-tags
                            (org-zot--write-synced-tags md-tags)
                          (unless (org-zot--has-tag-source-p)
                            (message "ℹ️  Item created without tags — add e.g. `#+FILETAGS: :tag1:tag2:' to tag it."))))
                      (if skip-note
                          (message "✅ Exported attachment only (no note)! Item: %s  Collection: %s"
                                   new-key coll-key)
                        (org-zot--add-note new-key body-html)
                        (message "Exported to Zotero! Item: %s  Collection: %s"
                                 new-key coll-key)))
                  (user-error "Item created (%s) but attachment upload failed" new-key)))
            (user-error "Failed to create Zotero item")))))))

(defun org-zot-export-to-zotero
    (&optional async subtreep visible-only body-only ext-plist)
  "Export org article to Zotero — create or update item + attachment + note.
If no #+ZOTERO_ITEM_KEY exists, creates a new item and writes the key
back to the buffer.  If the key already exists, cleans up old
attachments/notes and re-uploads."
  (interactive)
  (org-zot--export-to-zotero-core nil subtreep visible-only ext-plist))

(defun org-zot-export-to-zotero-attachment-only
    (&optional async subtreep visible-only body-only ext-plist)
  "Export org article to Zotero — attachment only, no note.
Same item creation/update and tag sync as `org-zot-export-to-zotero',
but never creates, updates, or deletes the child note.  Use this when
the note's per-formula LaTeX PNG handling is too slow and only the HTML
attachment is needed.  Bound to `z a' in the Zotero export menu."
  (interactive)
  (org-zot--export-to-zotero-core t subtreep visible-only ext-plist))

(defun org-zot-open-in-zotero
    (&optional async subtreep visible-only body-only ext-plist)
  "Open the current buffer's Zotero item in the Zotero desktop app.
Requires #+ZOTERO_ITEM_KEY to be set."
  (interactive)
  (let* ((info-plist (org-export--get-inbuffer-options 'org-zot-html))
         (item-key (plist-get info-plist :zotero-item-key)))
    (unless item-key
      (user-error "No #+ZOTERO_ITEM_KEY found in buffer"))
    (let ((uri (format "zotero://select/items/%s" item-key)))
      (message "Opening: %s" uri)
      (browse-url uri))))

(defun org-zot-show-item-key
    (&optional async subtreep visible-only body-only ext-plist)
  "Show Zotero item key for the current buffer."
  (interactive)
  (let ((item-key (plist-get (org-export--get-inbuffer-options 'org-zot-html)
                             :zotero-item-key)))
    (if item-key
        (message "🔑 Zotero item key: %s" item-key)
      (message "No #+ZOTERO_ITEM_KEY set in this buffer."))))

;;; ======================================================================
;;;                         Backend Definition
;;; ======================================================================

(org-export-define-derived-backend 'org-zot-html 'html
  :options-alist
  '((:zotero-item-type "ZOTERO_ITEM_TYPE" nil org-zot-default-item-type)
    (:zotero-collection "ZOTERO_COLLECTION" nil nil)
    (:zotero-tags "ZOTERO_TAGS" nil nil)
    (:zotero-synced-tags "ZOTERO_SYNCED_TAGS" nil nil)
    (:zotero-url "ZOTERO_URL" nil nil)
    (:zotero-extra "ZOTERO_EXTRA" nil nil)
    (:zotero-item-key "ZOTERO_ITEM_KEY" nil nil)
    (:zotero-attach-name "ZOTERO_ATTACH_NAME" nil nil))

  :menu-entry
  '(?z "Export to Zotero"
       ((?b "Preview in buffer" org-zot-export-to-buffer)
        (?z "Create or update (item + attachment + note)" org-zot-export-to-zotero)
        (?a "Attachment only (skip note)" org-zot-export-to-zotero-attachment-only)
        (?o "Open in Zotero" org-zot-open-in-zotero)
        (?k "Show item key" org-zot-show-item-key))))

(provide 'ox-zotero)
;;; ox-zotero.el ends here
