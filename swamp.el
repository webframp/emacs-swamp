;;; swamp.el --- Transient interface for the swamp CLI -*- lexical-binding: t; -*-
;;
;; Author: Sean Escriva <sean.escriva@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.5.0"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is NOT part of GNU Emacs.
;;
;;; Commentary:
;;
;; A transient-based interface for the swamp AI-native automation CLI.
;;
;; All commands use --json output rendered via Emacs-native
;; tabulated-list-mode and special-mode buffers.
;;
;; Entry point: M-x swamp-dispatch
;;
;;; Code:

(require 'transient)
(require 'json)

;;; ---------------------------------------------------------------------------
;;; Customization
;;; ---------------------------------------------------------------------------

(defgroup swamp nil
  "Interface for the swamp CLI."
  :group 'tools
  :prefix "swamp-")

(defcustom swamp-executable "swamp"
  "Path to the swamp executable."
  :type 'string
  :group 'swamp)

(defcustom swamp-repo-dir nil
  "Repository directory passed to swamp via --repo-dir.
When nil, swamp uses the current directory."
  :type '(choice (const nil) directory)
  :group 'swamp)

;;; ---------------------------------------------------------------------------
;;; Faces
;;; ---------------------------------------------------------------------------

(defface swamp-status-succeeded
  '((t :inherit success))
  "Face for succeeded status values."
  :group 'swamp)

(defface swamp-status-failed
  '((t :inherit error))
  "Face for failed status values."
  :group 'swamp)

(defface swamp-status-running
  '((t :inherit warning))
  "Face for running/in-progress status values."
  :group 'swamp)

;;; ---------------------------------------------------------------------------
;;; State
;;; ---------------------------------------------------------------------------

(defvar swamp--last-result-buffer nil
  "Most recently displayed swamp result buffer.")

;;; ---------------------------------------------------------------------------
;;; Low-level helpers
;;; ---------------------------------------------------------------------------

(defun swamp--base-args ()
  "Return the base argument list (--repo-dir if configured)."
  (if swamp-repo-dir
      (list "--repo-dir" (expand-file-name swamp-repo-dir))
    nil))

(defun swamp--run-json (args)
  "Run swamp with ARGS and --json, return parsed JSON or nil on error.
ARGS is a list of strings.  The exit code determines success; JSON parse
errors are swallowed and return nil."
  (with-temp-buffer
    (let* ((full-args (append (swamp--base-args) args (list "--json")))
           (exit (apply #'call-process swamp-executable nil t nil full-args)))
      (when (= exit 0)
        (goto-char (point-min))
        (condition-case nil
            (json-parse-buffer :object-type 'alist :array-type 'list)
          (error nil))))))

(defun swamp--run-json-stream (args)
  "Run swamp with ARGS and --json, return a list of all parsed JSON objects.
Some swamp commands emit multiple newline-delimited JSON objects.
Returns a list (possibly empty) of parsed objects; never signals on parse errors."
  (with-temp-buffer
    (let ((full-args (append (swamp--base-args) args (list "--json"))))
      (apply #'call-process swamp-executable nil t nil full-args))
    (goto-char (point-min))
    (let (objects)
      (while (not (eobp))
        (condition-case nil
            (let ((obj (json-parse-buffer :object-type 'alist :array-type 'list)))
              (push obj objects))
          (error
           (forward-line 1))))
      (nreverse objects))))

(defun swamp--completing-read-model (&optional prompt)
  "Prompt for a model name using completion from the live model list.
Uses PROMPT if provided."
  (let* ((data (swamp--run-json '("model" "search")))
         (results (alist-get 'results data))
         (names (mapcar (lambda (r) (alist-get 'name r)) results)))
    (completing-read (or prompt "Model: ") names nil t)))

(defun swamp--completing-read-workflow (&optional prompt)
  "Prompt for a workflow name using completion from the live workflow list.
Uses PROMPT if provided."
  (let* ((data (swamp--run-json '("workflow" "search")))
         (results (alist-get 'results data))
         (names (mapcar (lambda (r) (alist-get 'name r)) results)))
    (completing-read (or prompt "Workflow: ") names nil t)))

;;; ---------------------------------------------------------------------------
;;; Rendering helpers
;;; ---------------------------------------------------------------------------

(defun swamp--status-face (status)
  "Return the face for STATUS string."
  (pcase (downcase (or status ""))
    ("succeeded" 'swamp-status-succeeded)
    ("failed"    'swamp-status-failed)
    ("running"   'swamp-status-running)
    (_           'default)))

(defun swamp--propertize-status (status)
  "Return STATUS propertized with the appropriate face."
  (propertize (or status "") 'face (swamp--status-face status)))

(defun swamp--display-table (buf-name columns rows &optional keymap)
  "Display a tabulated-list buffer named BUF-NAME.
COLUMNS is a vector of column specs as accepted by `tabulated-list-format':
  each element is (NAME WIDTH SORT).
ROWS is a list of (ID [FIELD...]) entries.
Optional KEYMAP is merged over `tabulated-list-mode-map'.
Stores the buffer in `swamp--last-result-buffer' and pops to it."
  (let ((buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      (tabulated-list-mode)
      (setq tabulated-list-format columns)
      (setq tabulated-list-entries rows)
      (when keymap
        (use-local-map (make-composed-keymap keymap tabulated-list-mode-map)))
      (tabulated-list-init-header)
      (tabulated-list-print))
    (setq swamp--last-result-buffer buf)
    (pop-to-buffer buf)))

(defun swamp--display-detail (buf-name title fields)
  "Display a special-mode detail buffer named BUF-NAME.
TITLE is inserted as a header line.
FIELDS is a list of (LABEL VALUE) pairs; VALUE may be a string or nil.
Stores the buffer in `swamp--last-result-buffer' and pops to it."
  (let ((buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert (propertize title 'face 'bold) "\n\n")
        (dolist (field fields)
          (let ((label (car field))
                (value (cadr field)))
            (when value
              (insert (propertize (format "%-20s" label) 'face 'font-lock-keyword-face))
              (insert (format "%s\n" value))))))
      (goto-char (point-min)))
    (setq swamp--last-result-buffer buf)
    (pop-to-buffer buf)))

;;; ---------------------------------------------------------------------------
;;; Model commands
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun swamp-model-search ()
  "Search swamp models and display results in a tabulated-list buffer."
  (interactive)
  (let* ((query (read-string "Search models (empty for all): "))
         (args (if (string-empty-p query) '("model" "search") (list "model" "search" query)))
         (data (swamp--run-json args))
         (results (alist-get 'results data)))
    (unless results
      (user-error "No model results returned"))
    (let* ((keymap (make-sparse-keymap))
           (rows (mapcar (lambda (r)
                           (list (alist-get 'id r "")
                                 (vector (or (alist-get 'name r) "")
                                         (or (alist-get 'type r) ""))))
                         results)))
      (define-key keymap (kbd "RET")
                  (lambda ()
                    (interactive)
                    (let ((name (aref (tabulated-list-get-entry) 0)))
                      (swamp-model-get name))))
      (swamp--display-table
       "*swamp-models*"
       [("Name" 30 t) ("Type" 50 t)]
       rows
       keymap))))

;;;###autoload
(defun swamp-model-get (&optional name)
  "Show details for a model.
If NAME is nil, prompt with completion."
  (interactive)
  (let* ((name (or name (swamp--completing-read-model "Get model: ")))
         (data (swamp--run-json (list "model" "get" name))))
    (unless data
      (user-error "Could not retrieve model: %s" name))
    (let ((err (alist-get 'error data)))
      (when err (user-error "%s" err)))
    (swamp--display-detail
     (format "*swamp-model:%s*" name)
     (format "Model: %s" name)
     (list
      (list "Name"         (alist-get 'name data))
      (list "Type"         (alist-get 'type data))
      (list "Type Version" (format "%s" (or (alist-get 'typeVersion data) "")))
      (list "Version"      (format "%s" (or (alist-get 'version data) "")))
      (list "Methods"      (mapconcat
                            (lambda (m) (alist-get 'name m))
                            (or (alist-get 'methods data) '())
                            ", "))))))

;;;###autoload
(defun swamp-model-method-run ()
  "Run a method on a model, prompting for model and method name."
  (interactive)
  (let* ((name   (swamp--completing-read-model "Run method on model: "))
         (method (read-string (format "Method [%s]: " name)))
         (data   (swamp--run-json (list "model" "method" "run" name method))))
    (unless data
      (user-error "Method run returned no data for %s/%s" name method))
    (let ((err (alist-get 'error data)))
      (when err (user-error "%s" err)))
    (let ((status (alist-get 'status data "")))
      (swamp--display-detail
       (format "*swamp-run:%s/%s*" name method)
       (format "Method run: %s / %s" name method)
       (list
        (list "Model"     (alist-get 'modelName data))
        (list "Method"    (alist-get 'methodName data))
        (list "Status"    (swamp--propertize-status status))
        (list "Duration"  (let ((ms (alist-get 'duration data)))
                            (when ms (format "%dms" ms))))
        (list "Log file"  (alist-get 'logFile data))
        (list "Artifacts" (mapconcat #'identity
                                     (or (alist-get 'dataArtifacts data) '())
                                     "\n                     ")))))))

;;;###autoload
(defun swamp-model-output-get ()
  "Get the latest output for a model selected with completion."
  (interactive)
  (let* ((name (swamp--completing-read-model "Output for model: "))
         (data (swamp--run-json (list "model" "output" "get" name))))
    (when (or (null data) (alist-get 'error data))
      (user-error "%s" (or (and data (alist-get 'error data))
                           (format "No output for model: %s" name))))
    (swamp--display-detail
     (format "*swamp-output:%s*" name)
     (format "Output: %s" name)
     (list
      (list "Name"         (alist-get 'name data))
      (list "Data type"    (alist-get 'dataType data))
      (list "Content type" (alist-get 'contentType data))
      (list "Size"         (let ((sz (alist-get 'size data)))
                             (when sz (format "%d bytes" sz))))
      (list "Created at"   (alist-get 'createdAt data))))))

;;;###autoload
(defun swamp-model-validate ()
  "Validate a model definition selected with completion."
  (interactive)
  (let* ((name (swamp--completing-read-model "Validate model: "))
         (data (swamp--run-json (list "model" "validate" name))))
    (unless data
      (user-error "Could not validate model: %s" name))
    (let ((err (alist-get 'error data)))
      (when err (user-error "%s" err)))
    (let* ((passed      (alist-get 'passed data))
           (validations (alist-get 'validations data))
           (warnings    (alist-get 'warnings data))
           (val-lines   (mapconcat
                         (lambda (v)
                           (let ((ok (alist-get 'passed v)))
                             (format "  %s %s"
                                     (if ok
                                         (propertize "PASS" 'face 'swamp-status-succeeded)
                                       (propertize "FAIL" 'face 'swamp-status-failed))
                                     (alist-get 'name v))))
                         (or validations '())
                         "\n"))
           (warn-lines  (mapconcat #'identity (or warnings '()) "\n")))
      (swamp--display-detail
       (format "*swamp-validate:%s*" name)
       (format "Validate: %s" name)
       (list
        (list "Model"       (alist-get 'modelName data))
        (list "Result"      (if passed
                                (propertize "PASSED" 'face 'swamp-status-succeeded)
                              (propertize "FAILED" 'face 'swamp-status-failed)))
        (list "Validations" (if (string-empty-p val-lines) "none" val-lines))
        (list "Warnings"    (if (string-empty-p warn-lines) "none" warn-lines)))))))

;;; ---------------------------------------------------------------------------
;;; Workflow commands
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun swamp-workflow-search ()
  "Search swamp workflows and display results in a tabulated-list buffer."
  (interactive)
  (let* ((query (read-string "Search workflows (empty for all): "))
         (args  (if (string-empty-p query) '("workflow" "search") (list "workflow" "search" query)))
         (data  (swamp--run-json args))
         (results (alist-get 'results data)))
    (unless results
      (user-error "No workflow results returned"))
    (let* ((keymap (make-sparse-keymap))
           (rows (mapcar (lambda (r)
                           (list (alist-get 'id r "")
                                 (vector (or (alist-get 'name r) "")
                                         (format "%d" (or (alist-get 'jobCount r) 0))
                                         (or (alist-get 'description r) ""))))
                         results)))
      (define-key keymap (kbd "RET")
                  (lambda ()
                    (interactive)
                    (let ((name (aref (tabulated-list-get-entry) 0)))
                      (swamp-workflow-get name))))
      (swamp--display-table
       "*swamp-workflows*"
       [("Name" 35 t) ("Jobs" 6 t) ("Description" 60 nil)]
       rows
       keymap))))

;;;###autoload
(defun swamp-workflow-run ()
  "Run a workflow selected with completion."
  (interactive)
  (let* ((name    (swamp--completing-read-workflow "Run workflow: "))
         (objects (swamp--run-json-stream (list "workflow" "run" name)))
         ;; The final object with a "status" field is the run summary
         (summary (cl-find-if (lambda (o) (alist-get 'status o)) (reverse objects))))
    (unless summary
      (user-error "Workflow run for %s returned no summary" name))
    (let ((err (alist-get 'error summary)))
      (when err (user-error "%s" err)))
    (let* ((run-id  (alist-get 'id summary ""))
           (status  (alist-get 'status summary ""))
           (jobs    (alist-get 'jobs summary))
           (step-lines
            (mapconcat
             (lambda (job)
               (let ((jname   (alist-get 'name job ""))
                     (jstatus (alist-get 'status job ""))
                     (steps   (alist-get 'steps job)))
                 (concat
                  (format "  Job: %s  [%s]\n"
                          jname
                          (swamp--propertize-status jstatus))
                  (mapconcat
                   (lambda (step)
                     (format "    Step: %-30s [%s]  %s"
                             (alist-get 'name step "")
                             (swamp--propertize-status (alist-get 'status step ""))
                             (let ((ms (alist-get 'durationMs step)))
                               (if ms (format "%dms" ms) ""))))
                   (or steps '())
                   "\n"))))
             (or jobs '())
             "\n")))
      (swamp--display-detail
       (format "*swamp-workflow-run:%s*" name)
       (format "Workflow run: %s" name)
       (list
        (list "Workflow" name)
        (list "Run ID"   run-id)
        (list "Status"   (swamp--propertize-status status))
        (list "Jobs"     (if (string-empty-p step-lines) "none" step-lines)))))))

;;;###autoload
(defun swamp-workflow-history ()
  "Show run history for a workflow selected with completion."
  (interactive)
  (let* ((name    (swamp--completing-read-workflow "History for workflow: "))
         (data    (swamp--run-json (list "workflow" "history" "list" name)))
         (results (alist-get 'results data)))
    (unless results
      (user-error "No history for workflow: %s" name))
    (let ((rows (mapcar (lambda (r)
                          (let ((status (alist-get 'status r "")))
                            (list (alist-get 'runId r "")
                                  (vector (or (alist-get 'runId r) "")
                                          (swamp--propertize-status status)
                                          (or (alist-get 'startedAt r) "")
                                          (let ((ms (alist-get 'duration r)))
                                            (if ms (format "%dms" ms) ""))))))
                        results)))
      (swamp--display-table
       (format "*swamp-history:%s*" name)
       [("Run ID" 40 nil) ("Status" 12 t) ("Started at" 30 t) ("Duration" 12 t)]
       rows
       nil))))

;;;###autoload
(defun swamp-workflow-get (&optional name)
  "Show details for a workflow.
If NAME is nil, prompt with completion."
  (interactive)
  (let* ((name (or name (swamp--completing-read-workflow "Get workflow: ")))
         (data (swamp--run-json (list "workflow" "get" name))))
    (unless data
      (user-error "Could not retrieve workflow: %s" name))
    (let ((err (alist-get 'error data)))
      (when err (user-error "%s" err)))
    (let* ((jobs      (alist-get 'jobs data))
           (job-names (mapconcat (lambda (j) (alist-get 'name j ""))
                                 (or jobs '())
                                 ", ")))
      (swamp--display-detail
       (format "*swamp-workflow:%s*" name)
       (format "Workflow: %s" name)
       (list
        (list "Name"        (alist-get 'name data))
        (list "Version"     (format "%s" (or (alist-get 'version data) "")))
        (list "Jobs"        job-names)
        (list "Description" (alist-get 'description data))
        (list "Path"        (alist-get 'path data)))))))

;;; ---------------------------------------------------------------------------
;;; Extension commands
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun swamp-extension-search ()
  "Search the swamp extension registry and display results."
  (interactive)
  (let* ((query (read-string "Search extensions: "))
         (data  (swamp--run-json (list "extension" "search" query)))
         (exts  (alist-get 'extensions data)))
    (unless exts
      (user-error "No extensions found for query: %s" query))
    (let ((rows (mapcar (lambda (e)
                          (list (alist-get 'name e "")
                                (vector (or (alist-get 'name e) "")
                                        (or (alist-get 'latestVersion e) "")
                                        (or (alist-get 'description e) ""))))
                        exts)))
      (swamp--display-table
       "*swamp-extensions*"
       [("Name" 35 t) ("Version" 18 t) ("Description" 60 nil)]
       rows
       nil))))

;;;###autoload
(defun swamp-extension-pull ()
  "Pull an extension from the registry by package name.
Shows installed name@version on success; signals an error on failure."
  (interactive)
  (let* ((pkg     (read-string "Extension package (e.g. @swamp/aws/ec2): "))
         (objects (swamp--run-json-stream (list "extension" "pull" pkg)))
         ;; An error object has an "error" key
         (err-obj (cl-find-if (lambda (o) (alist-get 'error o)) objects))
         ;; The success summary has both "name" and "extractedFiles"
         (success (cl-find-if (lambda (o)
                                (and (alist-get 'name o)
                                     (alist-get 'extractedFiles o)))
                              objects)))
    (cond
     (err-obj
      (error "swamp extension pull failed: %s" (alist-get 'error err-obj)))
     (success
      (message "Installed %s@%s"
               (alist-get 'name success)
               (alist-get 'version success "")))
     (t
      (error "swamp extension pull: unexpected output for %s" pkg)))))

;;; ---------------------------------------------------------------------------
;;; Data command
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun swamp-data-query ()
  "Run a CEL data query against swamp artifacts and display results."
  (interactive)
  (let* ((expr    (read-string "CEL predicate: "))
         (data    (swamp--run-json (list "data" "query" expr)))
         (results (alist-get 'results data)))
    (unless results
      (user-error "No data results for predicate: %s" expr))
    (let ((rows (mapcar (lambda (r)
                          (list (alist-get 'id r "")
                                (vector (or (alist-get 'name r) "")
                                        (or (alist-get 'modelType r) "")
                                        (or (alist-get 'dataType r) "")
                                        (or (alist-get 'createdAt r) ""))))
                        results)))
      (swamp--display-table
       "*swamp-data*"
       [("Name" 35 t) ("Model type" 30 t) ("Data type" 15 t) ("Created at" 30 t)]
       rows
       nil))))

;;; ---------------------------------------------------------------------------
;;; Summarize command
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun swamp-summarize ()
  "Show a high-level summary of recent repo activity."
  (interactive)
  (let* ((data      (swamp--run-json '("summarize")))
         (since     (alist-get 'since data ""))
         (workflows (alist-get 'workflows data))
         (methods   (alist-get 'methodExecutions data)))
    (unless data
      (user-error "swamp summarize returned no data"))
    (let* ((wf-rows (mapcar (lambda (w)
                              (list (alist-get 'workflowName w "")
                                    (vector (or (alist-get 'workflowName w) "")
                                            (format "%d" (or (alist-get 'succeeded w) 0))
                                            (format "%d" (or (alist-get 'failed w) 0))
                                            (format "%d" (or (alist-get 'total w) 0)))))
                            (or workflows '())))
           (me-rows (mapcar (lambda (m)
                              (list (alist-get 'modelName m "")
                                    (vector (or (alist-get 'modelName m) "")
                                            (or (alist-get 'methodName m) "")
                                            (format "%d" (or (alist-get 'count m) 0))
                                            "")))
                            (or methods '())))
           (all-rows (append wf-rows me-rows)))
      (if (null all-rows)
          (message "No activity since %s" since)
        (swamp--display-table
         "*swamp-summary*"
         [("Name" 40 t) ("Succeeded" 12 t) ("Failed" 8 t) ("Total" 8 t)]
         all-rows
         nil)
        (with-current-buffer "*swamp-summary*"
          (let ((inhibit-read-only t))
            (goto-char (point-min))
            (insert (format "Activity since: %s\n\n" since))
            (goto-char (point-min))))))))

;;; ---------------------------------------------------------------------------
;;; Misc
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun swamp-jump-to-last-result ()
  "Jump to the most recently displayed swamp result buffer."
  (interactive)
  (if (and swamp--last-result-buffer
           (buffer-live-p swamp--last-result-buffer))
      (pop-to-buffer swamp--last-result-buffer)
    (user-error "No swamp result buffer to jump to")))

;;; ---------------------------------------------------------------------------
;;; Transient menus
;;; ---------------------------------------------------------------------------

;;;###autoload (autoload 'swamp-model-dispatch "swamp" nil t)
(transient-define-prefix swamp-model-dispatch ()
  "Swamp model commands."
  [["Search & Get"
    ("s" "search"     swamp-model-search)
    ("g" "get"        swamp-model-get)
    ("o" "output get" swamp-model-output-get)]
   ["Run & Validate"
    ("r" "method run" swamp-model-method-run)
    ("v" "validate"   swamp-model-validate)]])

;;;###autoload (autoload 'swamp-workflow-dispatch "swamp" nil t)
(transient-define-prefix swamp-workflow-dispatch ()
  "Swamp workflow commands."
  [["Search & Get"
    ("s" "search"  swamp-workflow-search)
    ("g" "get"     swamp-workflow-get)]
   ["Run & History"
    ("r" "run"     swamp-workflow-run)
    ("h" "history" swamp-workflow-history)]])

;;;###autoload (autoload 'swamp-extension-dispatch "swamp" nil t)
(transient-define-prefix swamp-extension-dispatch ()
  "Swamp extension commands."
  [["Registry"
    ("s" "search" swamp-extension-search)]
   ["Install"
    ("p" "pull"   swamp-extension-pull)]])

;;;###autoload (autoload 'swamp-dispatch "swamp" nil t)
(transient-define-prefix swamp-dispatch ()
  "Swamp AI-native automation."
  [["Models"
    ("m" "Model"      swamp-model-dispatch)
    ("d" "data query" swamp-data-query)]
   ["Workflows"
    ("w" "Workflow"    swamp-workflow-dispatch)
    ("e" "Extension"   swamp-extension-dispatch)
    ("S" "summarize"   swamp-summarize)
    ("b" "last result" swamp-jump-to-last-result)]])

(provide 'swamp)
;;; swamp.el ends here
