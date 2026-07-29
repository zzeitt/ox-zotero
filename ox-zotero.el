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
;;   - z b: HTML preview in buffer
;;   - z f: Export & Create item + HTML attachment + note
;;   - z n: Export & Update HTML attachment + note (requires #+ZOTERO_ITEM_KEY)
;;   - z k: Show item key
;;
;; Options (in-buffer keywords):
;;   - #+ZOTERO_ITEM_TYPE: Zotero item type (default: blogPost)
;;   - #+ZOTERO_COLLECTION: Collection name or key
;;   - #+ZOTERO_TAGS: Comma-separated tags (e.g. #AI-ML🤖, #编程💻)
;;   - #+ZOTERO_URL: Source URL
;;   - #+ZOTERO_EXTRA: Extra JSON for additional fields
;;   - #+ZOTERO_ITEM_KEY: Existing item key (for update mode)
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

;;; Code:

(require 'ox)
(require 'ox-html)
(require 'json)

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
      (let ((exit-code
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
              (message "✅ zot.py OK")
            (message "❌ zot.py exit=%d\n  CMD: %s\n  STDOUT:\n%s\n  STDERR: (see above or run CMD manually)"
                     exit-code cmd-str output))
          (cons exit-code output))))))

(defun org-zot--call-zot-ok (args &optional stdin-str)
  "Like `org-zot--call-zot' but returns output on success, nil on failure."
  (let ((result (org-zot--call-zot args stdin-str)))
    (if (= 0 (car result))
        (cdr result)
      (progn
        (message "⚠️ zot.py failed — reproduce with:\n  %s"
                 (org-zot--command-string args))
        nil))))

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
    ;; Search by name in `zot collections' output
    (let ((output (org-zot--call-zot-ok '("collections"))))
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
Returns a plist with keys: :title :item-type :url :coll-key :tags :extra."
  (let* ((item-type (or (plist-get info :zotero-item-type)
                        org-zot-default-item-type))
         (title (car (plist-get info :title)))
         (zotero-url (plist-get info :zotero-url))
         (zotero-tags-raw (plist-get info :zotero-tags))
         (zotero-extra (plist-get info :zotero-extra))
         (zotero-coll (plist-get info :zotero-collection))
         (zotero-key (plist-get info :zotero-item-key))
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
          :tags (if (and zotero-tags-raw
                         (not (string-empty-p zotero-tags-raw)))
                    (mapcar #'string-trim
                            (split-string zotero-tags-raw ","))
                  nil)
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
    ;; Build extra JSON
    (let ((extra-alist nil))
      (when tags
        (push (cons 'tags
                    (vconcat
                     (mapcar (lambda (tag)
                               `((tag . ,tag) (type . 1)))
                             tags)))
              extra-alist))
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
    (append (list "add" item-type title url coll-key)
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
    (with-temp-file tmpfile
      (insert html-content))
    (message "📝 HTML saved to: %s" tmpfile)
    (unwind-protect
        (let ((args (if archive-filename
                        (list "attach" item-key tmpfile archive-filename)
                      (list "attach" item-key tmpfile))))
          (let ((output (org-zot--call-zot-ok args)))
            (if (and output (string-match "✅ Attachment saved" output))
                (setq success t)
              (progn
                (message "⚠️ Attachment upload failed\n  Temp file: %s\n  Retry: %s %s %s %s %s"
                         tmpfile
                         org-zot-python-command
                         org-zot-script-path
                         "attach" item-key tmpfile
                         (or archive-filename ""))
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
Uses `zot.py addnote' with the HTML piped via stdin.
Returns t on success, nil on failure."
  (message "📝 Adding note to item: %s" item-key)
  (let ((output (org-zot--call-zot-ok (list "setnote" item-key) html-content)))
    (if output
        (progn
          (message "✅ Note added to item: %s" item-key)
          t)
      (progn
        (message "⚠️ Note upload failed for item: %s" item-key)
        nil))))

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

(defun org-zot-export-to-zotero
    (&optional async subtreep visible-only body-only ext-plist)
  "Export org article to Zotero: create item + HTML attachment + note.
Steps:
  1. Extract metadata from buffer (#+TITLE:, #+ZOTERO_TAGS:, etc.)
  2. Export body to HTML via org-zot-html backend
  3. Call `zot.py add' to create the item
  4. Call `zot.py attach' to upload HTML as a file attachment
  5. Call `zot.py addnote' to add the same HTML as a child note
  6. Write back #+ZOTERO_ITEM_KEY to the buffer"
  (interactive)
  (let* ((info-plist (org-combine-plists
                      ext-plist
                      (org-export--get-inbuffer-options 'org-zot-html)))
         (metadata (org-zot--extract-metadata info-plist))
         (item-key (plist-get metadata :item-key))
         (coll-key (plist-get metadata :coll-key))
         (title (plist-get metadata :title)))

    ;; Validate
    (unless title
      (user-error "No #+TITLE: found in buffer — cannot create Zotero item"))
    (unless (and coll-key (not (string-empty-p coll-key)))
      (user-error "No collection specified. Set #+ZOTERO_COLLECTION or org-zot-default-collection-key"))

    ;; Step 1: Export HTML
    (let* ((full-html (org-export-as 'org-zot-html subtreep visible-only nil ext-plist))
         (body-html (org-zot--extract-body full-html)))
      (unless (and full-html (not (string-empty-p (string-trim full-html))))
        (user-error "Export produced empty output"))

      (if item-key
          ;; Update existing item — upload attachment + note
          (progn
            (message "📎 Uploading HTML attachment to item: %s" item-key)
            (if (org-zot--attach-file item-key full-html (org-zot--sanitize-filename title))
                (progn
                  (message "✅ Attachment updated for item: %s" item-key)
                  (org-zot--add-note item-key body-html))
              (user-error "Failed to upload attachment")))
        ;; Create new item
        (message "📦 Creating Zotero item...")
        (let ((new-key (org-zot--create-item metadata)))
          (if new-key
              (progn
                (message "📎 Uploading HTML attachment...")
                (if (org-zot--attach-file new-key full-html (org-zot--sanitize-filename title))
                    (progn
                      ;; Write back item key
                      (org-zot--write-item-key new-key)
                      (org-zot--add-note new-key body-html)
                      (message "✅ Exported to Zotero! Item: %s  Collection: %s"
                               new-key coll-key))
                  (user-error "Item created (%s) but attachment upload failed" new-key)))
            (user-error "Failed to create Zotero item")))))))

(defun org-zot-export-note-to-zotero
    (&optional async subtreep visible-only body-only ext-plist)
  "Export org article and update HTML attachment + note on an existing Zotero item.
Requires #+ZOTERO_ITEM_KEY to be set in the buffer."
  (interactive)
  (let* ((info-plist (org-export--get-inbuffer-options 'org-zot-html))
         (item-key (plist-get info-plist :zotero-item-key))
         (title (car (plist-get info-plist :title))))
    (unless item-key
      (user-error "No #+ZOTERO_ITEM_KEY found. Use `z f' to create a new item first, or set it manually."))
    (let* ((full-html (org-export-as 'org-zot-html subtreep visible-only nil
                      (org-combine-plists ext-plist info-plist)))
         (body-html (org-zot--extract-body full-html)))
      (unless (and full-html (not (string-empty-p (string-trim full-html))))
        (user-error "Export produced empty output"))
      (message "📎 Uploading HTML attachment to item: %s" item-key)
      (if (org-zot--attach-file item-key full-html (org-zot--sanitize-filename title))
          (progn
            (message "✅ Attachment updated for item: %s" item-key)
            (org-zot--add-note item-key body-html))
        (user-error "Failed to upload attachment")))))

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
    (:zotero-url "ZOTERO_URL" nil nil)
    (:zotero-extra "ZOTERO_EXTRA" nil nil)
    (:zotero-item-key "ZOTERO_ITEM_KEY" nil nil))

  :menu-entry
  '(?z "Export to Zotero"
       ((?b "HTML preview in buffer" org-zot-export-to-buffer)
        (?f "Export & Create item + attachment + note" org-zot-export-to-zotero)
        (?n "Export & Update attachment + note" org-zot-export-note-to-zotero)
        (?k "Show item key" org-zot-show-item-key))))

(provide 'ox-zotero)
;;; ox-zotero.el ends here
