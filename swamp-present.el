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
;;
;; With a prefix argument, build and preview make a self-contained deck
;; that works offline.
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

(defcustom swamp-present-deck "talks"
  "Name of the @webframp/presentation/deck model instance to build with.
An Org buffer can name another with a #+SWAMP_DECK: keyword."
  :type 'string
  :safe #'stringp
  :group 'swamp-present)

(defcustom swamp-present-output-directory nil
  "Directory for previewed HTML and PDF files.
When nil, use the variable `temporary-file-directory'.  Files are named
after the deck, so each preview overwrites the last and a browser tab can
simply reload."
  :type '(choice (const :tag "Temporary directory" nil) directory)
  :group 'swamp-present)

(defvar-local swamp-present-name nil
  "Deck name for this buffer, or nil to let swamp derive it from the file.
Set it as a file-local variable when two sources share a file name.")
(put 'swamp-present-name 'safe-local-variable
     (lambda (v) (and (stringp v) (string-match-p "\\`[a-z0-9][a-z0-9-]*\\'" v))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defconst swamp-present--log-buffer "*swamp-present*"
  "Buffer that collects swamp's error output and build warnings.")

(defun swamp-present--deck ()
  "Return the deck instance for the current buffer."
  (or (and (derived-mode-p 'org-mode)
           (save-excursion
             (save-restriction
               (widen)
               (goto-char (point-min))
               (let ((case-fold-search t))
                 (when (re-search-forward
                        "^#\\+SWAMP_DECK:[ \t]*\\([^ \t\n]+\\)" nil t)
                   (match-string-no-properties 1))))))
      swamp-present-deck))

(defun swamp-present--source ()
  "Return the current buffer's file, saving it first if it has changes."
  (let ((file (buffer-file-name)))
    (unless file
      (user-error "This buffer is not visiting a file"))
    (unless (string-match-p "\\.\\(org\\|md\\|markdown\\|mdown\\|mkd\\)\\'" file)
      (user-error "Not an Org or Markdown file: %s" file))
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

(defun swamp-present--run (args on-success)
  "Run swamp with ARGS asynchronously, then call ON-SUCCESS with its result.
The result is swamp's parsed JSON.  A failure is reported in the echo area
and its error output is kept in the log buffer."
  (let ((out (generate-new-buffer " *swamp-present-out*"))
        (err (generate-new-buffer " *swamp-present-err*")))
    (make-process
     :name "swamp-present"
     :buffer out
     :stderr err
     :command (cons swamp-executable (swamp--command-args args))
     :noquery t
     :sentinel
     (lambda (proc _event)
       (unless (process-live-p proc)
         (unwind-protect
             (let* ((result (swamp-present--parse
                             (with-current-buffer out (buffer-string))))
                    (status (alist-get 'status result))
                    (stderr (with-current-buffer err (buffer-string))))
               (if (and (= (process-exit-status proc) 0)
                        (equal status "succeeded"))
                   (funcall on-success result)
                 (swamp-present--log "%s" stderr)
                 (message "swamp: %s"
                          (or (alist-get 'error result)
                              (format "%s failed (exit %d); see %s"
                                      (nth 4 args)
                                      (process-exit-status proc)
                                      swamp-present--log-buffer)))))
           (kill-buffer out)
           (when (buffer-live-p err) (kill-buffer err))))))))

(defun swamp-present--fetch (deck data-name)
  "Return the content of DECK's file DATA-NAME as a unibyte string.
swamp prints text files as they are and binary files as base64, each with
one trailing newline."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let* ((coding-system-for-read 'binary)
           (predicate (format "model(%S) && name == %S" deck data-name))
           (exit (apply #'call-process swamp-executable nil '(t nil) nil
                        (swamp--command-args
                         (list "data" "query" predicate
                               "--select" "content")))))
      (unless (= exit 0)
        (user-error "Swamp could not read %s from %s" data-name deck))
      (goto-char (point-max))
      (when (eq (char-before) ?\n) (delete-char -1))
      (when (= (buffer-size) 0)
        (user-error "Deck %s has no %s yet" deck data-name))
      (buffer-string))))

(defun swamp-present--output-file (name extension)
  "Return the preview file for deck NAME with EXTENSION."
  (expand-file-name (format "swamp-present-%s.%s" name extension)
                    (or swamp-present-output-directory
                        temporary-file-directory)))

(defun swamp-present--write (file bytes)
  "Write unibyte BYTES to FILE."
  (let ((coding-system-for-write 'binary))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert bytes)))
  file)

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
     (let* ((name (alist-get 'name record))
            (file (swamp-present--write
                   (swamp-present--output-file name "html")
                   (swamp-present--fetch deck (format "deck-%s-html" name)))))
       (browse-url-of-file file)))))

;;;###autoload
(defun swamp-present-pdf ()
  "Build the deck in the current buffer, print it to PDF and open the PDF."
  (interactive)
  (swamp-present--build
   nil
   (lambda (deck record)
     (let ((name (alist-get 'name record)))
       (message "Printing %s..." name)
       ;; Name the deck the build just wrote, not the source: export_pdf
       ;; takes one or the other.
       (swamp-present--run
        (list "model" "method" "run" deck "export_pdf"
              "--input" (concat "name=" name) "--json")
        (lambda (result)
          (let* ((pdf (swamp-present--record result))
                 (encoded (swamp-present--fetch
                           deck (format "deck-%s-pdf" name)))
                 (file (swamp-present--write
                        (swamp-present--output-file name "pdf")
                        (base64-decode-string encoded))))
            (message "%s: %d pages%s" name
                     (alist-get 'pages (alist-get 'pdf pdf))
                     (if (eq (alist-get 'unchanged pdf) t)
                         " (unchanged)" ""))
            (find-file-other-window file))))))))

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
    ("o" "outline" swamp-present-outline)]])

(transient-append-suffix 'swamp-dispatch "d"
  '("p" "present" swamp-present-dispatch))

(provide 'swamp-present)
;;; swamp-present.el ends here
