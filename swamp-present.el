;;; swamp-present.el --- Build reveal.js decks with @webframp/presentation -*- lexical-binding: t; -*-
;;
;; Author: Sean Escriva <sean.escriva@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.5.0"))
;; Keywords: tools, outlines, hypermedia
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is NOT part of GNU Emacs.
;;
;;; Commentary:
;;
;; Build, preview, outline and print the Org or Markdown deck in the
;; current buffer through the @webframp/presentation swamp extension.
;; Every build is stored as versioned swamp data; this file only runs swamp
;; commands and reads their output.
;;
;; Setup, once per swamp repository:
;;
;;   swamp extension pull @webframp/presentation
;;   swamp model create @webframp/presentation/deck talks
;;
;; Commands (also under `swamp-present-dispatch', and as "p" in
;; `swamp-dispatch'):
;;
;;   `swamp-present-build'    build the deck
;;   `swamp-present-preview'  build it and open it in a browser
;;   `swamp-present-outline'  list slides, notes coverage, missing images
;;   `swamp-present-pdf'      build it, print it to PDF and open the PDF
;;   `swamp-present-cancel'   stop running swamp commands
;;
;; With a prefix argument, build, preview and PDF make a self-contained
;; deck that works offline.
;;
;;; Code:

(require 'swamp)
(require 'transient)
(require 'json)
(require 'seq)
(require 'subr-x)

;;; ---------------------------------------------------------------------------
;;; Customization
;;; ---------------------------------------------------------------------------

(defgroup swamp-present nil
  "Build reveal.js decks with the @webframp/presentation extension."
  :group 'swamp
  :prefix "swamp-present-")

;; swamp model instance names and the extension's deck names.  Anything a
;; buffer or file-local variable supplies is checked against these before it
;; reaches swamp's command line, so it can never read as an option.
(defconst swamp-present--instance-pattern
  "\\`[A-Za-z0-9][A-Za-z0-9._-]*\\'"
  "Pattern a deck model instance name must match.")

(defconst swamp-present--name-pattern
  "\\`[a-z0-9][a-z0-9-]\\{0,62\\}\\'"
  "Pattern a deck name must match; the extension's DECK_NAME_PATTERN.")

(defun swamp-present--instance-p (value)
  "Return non-nil if VALUE is a valid deck model instance name."
  (and (stringp value) (string-match-p swamp-present--instance-pattern value)))

(defun swamp-present--name-p (value)
  "Return non-nil if VALUE is a valid deck name."
  (and (stringp value) (string-match-p swamp-present--name-pattern value)))

(defcustom swamp-present-deck "talks"
  "Name of the @webframp/presentation/deck model instance to build with.
An Org buffer can name another with a #+SWAMP_DECK: keyword."
  :type 'string
  :safe #'swamp-present--instance-p
  :group 'swamp-present)

(defcustom swamp-present-output-directory nil
  "Directory for previewed HTML and PDF files.
When nil, use \"swamp-present/\" under `user-emacs-directory', created
readable by you alone.  Files are named after the deck instance and the
deck, so each preview overwrites the last and a browser tab only needs
reloading."
  :type '(choice (const :tag "Under user-emacs-directory" nil) directory)
  :group 'swamp-present)

(defcustom swamp-present-timeout 600
  "Seconds before a swamp command started by swamp-present is stopped.
nil means never."
  :type '(choice (const :tag "Never" nil) natnum)
  :group 'swamp-present)

(defvar-local swamp-present-name nil
  "Deck name for this buffer, or nil to let swamp derive it from the file.
Set it as a file-local variable when two sources share a file name.")
(put 'swamp-present-name 'safe-local-variable #'swamp-present--name-p)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defconst swamp-present--log-buffer "*swamp-present*"
  "Buffer that collects swamp's error output and build warnings.")

(defun swamp-present--deck ()
  "Return the deck instance for the current buffer."
  (let ((deck (or (and (derived-mode-p 'org-mode)
                       (save-excursion
                         (save-restriction
                           (widen)
                           (goto-char (point-min))
                           (let ((case-fold-search t))
                             (when (re-search-forward
                                    "^#\\+SWAMP_DECK:[ \t]*\\([^ \t\n]+\\)"
                                    nil t)
                               (match-string-no-properties 1))))))
                  swamp-present-deck)))
    (unless (swamp-present--instance-p deck)
      (user-error "Not a deck model instance name: %S" deck))
    deck))

(defun swamp-present--source ()
  "Return the current buffer's file, saving it first if it has changes."
  (let ((file (buffer-file-name)))
    (unless file
      (user-error "This buffer is not visiting a file"))
    (unless (string-match-p "\\.\\(org\\|md\\|markdown\\|mdown\\|mkd\\)\\'" file)
      (user-error "Not an Org or Markdown file: %s" file))
    (when (and swamp-present-name (not (swamp-present--name-p swamp-present-name)))
      (user-error "Not a deck name: %S" swamp-present-name))
    (when (and (buffer-modified-p)
               (y-or-n-p (format "Save %s before building? "
                                 (file-name-nondirectory file))))
      (save-buffer))
    (expand-file-name file)))

(defun swamp-present--method-args (deck method source &rest inputs)
  "Return swamp arguments to run METHOD on DECK for SOURCE.
INPUTS are extra \"key=value\" strings passed with --input."
  (append (list "model" "method" "run" deck method
                "--input" (concat "source=" source))
          (when swamp-present-name
            (list "--input" (concat "name=" swamp-present-name)))
          (mapcan (lambda (i) (list "--input" i)) inputs)
          (list "--json")))

(defun swamp-present--record (result)
  "Return the attributes of the resource RESULT's method wrote.
Each method of the deck model writes exactly one resource; its files carry
no attributes."
  (alist-get 'attributes
             (seq-find (lambda (a) (alist-get 'attributes a))
                       (alist-get 'dataArtifacts result))))

(defun swamp-present--log (format-string &rest args)
  "Append FORMAT-STRING with ARGS to the log buffer."
  (with-current-buffer (get-buffer-create swamp-present--log-buffer)
    (goto-char (point-max))
    (insert (apply #'format format-string args) "\n")))

(defun swamp-present--parse (text)
  "Parse TEXT as swamp's JSON output, or return nil."
  (condition-case nil
      (json-parse-string text :object-type 'alist :array-type 'list)
    (error nil)))

(defun swamp-present--start (args binary on-exit)
  "Run swamp with ARGS asynchronously and call ON-EXIT when it ends.
ON-EXIT gets the exit status, or `timed-out' or `cancelled' for a command
that was stopped, then stdout and stderr.  With BINARY, stdout is read as
raw bytes.  The command is stopped after `swamp-present-timeout' seconds."
  (let* ((out (let ((buf (generate-new-buffer " *swamp-present-out*")))
                ;; Before the process starts, so no output is decoded early.
                (with-current-buffer buf (set-buffer-multibyte (not binary)))
                buf))
         (err (generate-new-buffer " *swamp-present-err*"))
         (proc (make-process
                :name "swamp-present"
                :buffer out
                :stderr err
                :coding (if binary 'binary 'utf-8)
                :command (cons swamp-executable (swamp--command-args args))
                :noquery t
                :sentinel #'ignore))
         (timer (when swamp-present-timeout
                  (run-at-time swamp-present-timeout nil
                               (lambda ()
                                 (when (process-live-p proc)
                                   (process-put proc 'stopped 'timed-out)
                                   (delete-process proc)))))))
    (set-process-sentinel
     proc
     (lambda (p _event)
       (unless (process-live-p p)
         (when timer (cancel-timer timer))
         (unwind-protect
             (let ((stdout (with-current-buffer out (buffer-string)))
                   (stderr (if (buffer-live-p err)
                               (with-current-buffer err (buffer-string))
                             "")))
               (funcall on-exit
                        (or (process-get p 'stopped) (process-exit-status p))
                        stdout stderr))
           (kill-buffer out)
           (when (buffer-live-p err) (kill-buffer err))))))
    proc))

(defun swamp-present--fail (what exit stderr &optional result)
  "Report that WHAT failed with EXIT, logging STDERR.
RESULT is swamp's parsed JSON, if any; swamp prints some errors, such as
an unknown model, as JSON on stderr instead."
  (unless (string-empty-p stderr)
    (swamp-present--log "%s" (string-trim-right stderr)))
  (message "swamp: %s"
           (cond ((eq exit 'timed-out)
                  (format "%s timed out after %ds" what swamp-present-timeout))
                 ((eq exit 'cancelled) (format "%s cancelled" what))
                 ((alist-get 'error result))
                 ((alist-get 'error (swamp-present--parse stderr)))
                 (t (format "%s failed (exit %d); see %s"
                            what exit swamp-present--log-buffer)))))

(defun swamp-present--run (args on-success)
  "Run the swamp method in ARGS, then call ON-SUCCESS with its result.
The result is swamp's parsed JSON.  A failure is reported in the echo area
and its error output is kept in the log buffer."
  (swamp-present--start
   args nil
   (lambda (exit stdout stderr)
     (let ((result (swamp-present--parse stdout)))
       (if (and (eq exit 0) (equal (alist-get 'status result) "succeeded"))
           (funcall on-success result)
         (swamp-present--fail (nth 4 args) exit stderr result))))))

(defun swamp-present--fetch (deck data-name on-content)
  "Read DECK's file DATA-NAME, then call ON-CONTENT with it.
The content is a unibyte string.  swamp prints text files as they are and
binary files as base64, each with one trailing newline, which is removed."
  (swamp-present--start
   (list "data" "query" (format "model(%S) && name == %S" deck data-name)
         "--select" "content")
   t
   (lambda (exit stdout stderr)
     (let ((content (string-remove-suffix "\n" stdout)))
       (cond ((not (eq exit 0))
              (swamp-present--fail (format "reading %s" data-name) exit stderr))
             ((string-empty-p content)
              (message "swamp: %s has no %s yet" deck data-name))
             (t (funcall on-content content)))))))

(defun swamp-present--output-file (deck name extension)
  "Return the preview file for deck NAME of instance DECK with EXTENSION."
  (let ((dir (file-name-as-directory
              (or swamp-present-output-directory
                  (locate-user-emacs-file "swamp-present/")))))
    (unless (file-directory-p dir)
      (with-file-modes #o700 (make-directory dir t)))
    (expand-file-name (format "swamp-present-%s-%s.%s" deck name extension)
                      dir)))

(defun swamp-present--write (file bytes)
  "Write unibyte BYTES to FILE and return the buffer visiting it, if any.
A buffer already visiting FILE is reverted, so it shows the new content
without asking."
  (let ((coding-system-for-write 'binary))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert bytes)))
  (let ((buf (find-buffer-visiting file)))
    (when buf
      (with-current-buffer buf (revert-buffer t t t)))
    buf))

(defun swamp-present--report-build (deck record)
  "Echo the outcome of a build RECORD of DECK and log its warnings."
  (let ((warnings (alist-get 'warnings record)))
    (dolist (w warnings)
      (swamp-present--log "%s/%s: %s" deck (alist-get 'name record) w))
    (message "%s %s: %d slides%s%s"
             (if (eq (alist-get 'unchanged record) t) "Unchanged" "Built")
             (alist-get 'name record)
             (alist-get 'slideCount record)
             (if (eq (alist-get 'selfContained (alist-get 'reveal record)) t)
                 ", self-contained" "")
             (if warnings
                 (format ", %d warnings (see %s)" (length warnings)
                         swamp-present--log-buffer)
               ""))))

(defun swamp-present--build (self-contained then)
  "Build the current buffer's deck, then call THEN with deck and record.
SELF-CONTAINED inlines every reveal.js file."
  (let ((deck (swamp-present--deck))
        (source (swamp-present--source)))
    (message "Building %s..." (file-name-nondirectory source))
    (swamp-present--run
     (apply #'swamp-present--method-args deck "build" source
            (when self-contained (list "selfContained=true")))
     (lambda (result)
       (let ((record (swamp-present--record result)))
         (swamp-present--report-build deck record)
         (when then (funcall then deck record)))))))

(defun swamp-present--print (deck name)
  "Print DECK's deck NAME to PDF and open it.
The deck is named, not its source: export_pdf takes one or the other, and
the name is the one the build just recorded."
  (message "Printing %s..." name)
  (swamp-present--run
   (list "model" "method" "run" deck "export_pdf"
         "--input" (concat "name=" name) "--json")
   (lambda (result)
     (let ((pdf (swamp-present--record result)))
       (swamp-present--fetch
        deck (format "pdf-%s" name)
        (lambda (encoded)
          (let* ((file (swamp-present--output-file deck name "pdf"))
                 (buf (swamp-present--write
                       file (base64-decode-string encoded))))
            (message "%s: %d pages%s" name
                     (alist-get 'pages (alist-get 'pdf pdf))
                     (if (eq (alist-get 'unchanged pdf) t) " (unchanged)" ""))
            (pop-to-buffer (or buf (find-file-noselect file))))))))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun swamp-present-build (&optional self-contained)
  "Build the deck in the current buffer.
With prefix argument SELF-CONTAINED, inline every reveal.js file so the
deck works offline."
  (interactive "P")
  (swamp-present--build self-contained nil))

;;;###autoload
(defun swamp-present-preview (&optional self-contained)
  "Build the deck in the current buffer and open it in a browser.
With prefix argument SELF-CONTAINED, build a deck that works offline."
  (interactive "P")
  (swamp-present--build
   self-contained
   (lambda (deck record)
     (let ((name (alist-get 'name record)))
       (swamp-present--fetch
        deck (format "html-%s" name)
        (lambda (html)
          (let ((file (swamp-present--output-file deck name "html")))
            (swamp-present--write file html)
            (browse-url-of-file file))))))))

;;;###autoload
(defun swamp-present-pdf (&optional self-contained)
  "Build the deck in the current buffer, print it to PDF and open the PDF.
With prefix argument SELF-CONTAINED, build and print a deck that works
offline; without it, printing loads reveal.js from the CDN."
  (interactive "P")
  (swamp-present--build
   self-contained
   (lambda (deck record)
     (swamp-present--print deck (alist-get 'name record)))))

(defun swamp-present--outline-rows (record)
  "Return tabulated-list rows for the slides in outline RECORD."
  (let ((i 0))
    (mapcar (lambda (s)
              (setq i (1+ i))
              (let ((notes (alist-get 'notesWords s)))
                (list i (vector (alist-get 'index s)
                                (let ((title (alist-get 'title s)))
                                  (if (string-empty-p title) "(untitled)" title))
                                (if (eq notes 0)
                                    (propertize "none" 'face 'warning)
                                  (number-to-string notes))
                                (number-to-string
                                 (length (alist-get 'images s)))))))
            (alist-get 'slides record))))

;;;###autoload
(defun swamp-present-outline ()
  "Show the slides of the deck in the current buffer, without building it.
Lists each slide's words of speaker notes and images, and reports images
that do not exist."
  (interactive)
  (let ((deck (swamp-present--deck))
        (source (swamp-present--source)))
    (swamp-present--run
     (swamp-present--method-args deck "outline" source)
     (lambda (result)
       (let* ((record (swamp-present--record result))
              (missing (alist-get 'missingImages record)))
         (swamp--display-table
          (format "*swamp-outline:%s*" (alist-get 'name record))
          [("#" 6 nil) ("Title" 50 t) ("Notes" 7 nil) ("Images" 6 nil)]
          (swamp-present--outline-rows record))
         (message "%d slides, %d without notes%s"
                  (alist-get 'slideCount record)
                  (length (alist-get 'slidesWithoutNotes record))
                  (if missing
                      (format "; missing images: %s"
                              (string-join missing ", "))
                    "")))))))

;;;###autoload
(defun swamp-present-cancel ()
  "Stop every swamp command swamp-present started."
  (interactive)
  (let ((n 0))
    (dolist (p (process-list))
      (when (and (string-prefix-p "swamp-present" (process-name p))
                 (process-live-p p))
        (process-put p 'stopped 'cancelled)
        (delete-process p)
        (setq n (1+ n))))
    (message "Stopped %d swamp command%s" n (if (= n 1) "" "s"))))

;;; ---------------------------------------------------------------------------
;;; Transient menu
;;; ---------------------------------------------------------------------------

;;;###autoload (autoload 'swamp-present-dispatch "swamp-present" nil t)
(transient-define-prefix swamp-present-dispatch ()
  "Build reveal.js decks with @webframp/presentation."
  [["Deck"
    ("b" "build"   swamp-present-build)
    ("p" "preview" swamp-present-preview)
    ("P" "PDF"     swamp-present-pdf)]
   ["Source"
    ("o" "outline" swamp-present-outline)
    ("k" "cancel"  swamp-present-cancel)]])

(transient-append-suffix 'swamp-dispatch "d"
  '("p" "present" swamp-present-dispatch))

(provide 'swamp-present)
;;; swamp-present.el ends here
