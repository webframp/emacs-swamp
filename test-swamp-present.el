;;; test-swamp-present.el --- ERT tests for swamp-present.el -*- lexical-binding: t; -*-
;;
;; Run with:
;;   emacs --batch -l ert -L . \
;;         -l swamp-present.el \
;;         -l test-swamp-present.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; The process tests run a fake swamp executable: a shell script that
;; answers each invocation according to its arguments and records them, so
;; argument handling, JSON parsing and the callback chains run for real
;; without swamp installed.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'swamp-present)

(defvar swamp-present-test--dir nil
  "Scratch directory of the running fake-swamp test.")

(defun swamp-present-test--calls ()
  "Return the argument lists the fake swamp was called with, in order."
  (let ((file (expand-file-name "calls" swamp-present-test--dir)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (mapcar (lambda (line) (split-string line "\x1f" t))
                (split-string (buffer-string) "\n" t))))))

(defmacro swamp-present-test--with-fake-swamp (responses &rest body)
  "Run BODY with `swamp-executable' answering from RESPONSES.
RESPONSES is a list of (GLOB STDOUT EXIT [STDERR]); the first GLOB that
matches the space-joined arguments, as in a shell `case', is used.
Output files go to a scratch directory, bound in
`swamp-present-test--dir'."
  (declare (indent 1))
  `(let* ((swamp-present-test--dir (make-temp-file "swamp-present-test-" t))
          (script (expand-file-name "swamp" swamp-present-test--dir))
          (swamp-executable script)
          (swamp-repo-dir nil)
          (swamp-present-output-directory
           (expand-file-name "out" swamp-present-test--dir)))
     (unwind-protect
         (let ((i 0) (cases ""))
           (dolist (r ,responses)
             (let ((out (expand-file-name (format "out%d" i) swamp-present-test--dir))
                   (err (expand-file-name (format "err%d" i) swamp-present-test--dir)))
               (let ((coding-system-for-write 'binary))
                 (write-region (nth 1 r) nil out nil 'silent)
                 (write-region (or (nth 3 r) "") nil err nil 'silent))
               (setq cases
                     (concat cases
                             (format "  %s) cat %s; cat %s >&2; exit %d;;\n"
                                     (nth 0 r) (shell-quote-argument out)
                                     (shell-quote-argument err) (nth 2 r))))
               (setq i (1+ i))))
           (with-temp-file script
             (insert "#!/bin/sh\n"
                     (format "printf '%%s\\037' \"$@\" >> %s\necho >> %s\n"
                             (shell-quote-argument
                              (expand-file-name "calls" swamp-present-test--dir))
                             (shell-quote-argument
                              (expand-file-name "calls" swamp-present-test--dir)))
                     "case \"$*\" in\n" cases
                     "  *) echo unexpected >&2; exit 99;;\nesac\n"))
           (set-file-modes script #o755)
           ,@body)
       (delete-directory swamp-present-test--dir t))))

(defun swamp-present-test--wait ()
  "Wait for every swamp-present process to finish."
  (while (seq-some (lambda (p) (string-prefix-p "swamp-present" (process-name p)))
                   (process-list))
    (accept-process-output nil 0.05)))

(defmacro swamp-present-test--capturing-messages (&rest body)
  "Run BODY, returning the messages it showed, oldest first."
  `(let (messages)
     (cl-letf (((symbol-function 'message)
                (lambda (fmt &rest args)
                  (when fmt (push (apply #'format fmt args) messages)))))
       ,@body)
     (nreverse messages)))

(defmacro swamp-present-test--in-deck (&rest body)
  "Run BODY in an Org buffer visiting a scratch talk.org."
  `(let ((file (expand-file-name "talk.org" swamp-present-test--dir)))
     (with-temp-file file (insert "#+TITLE: T\n* One\n"))
     (with-current-buffer (find-file-noselect file)
       (unwind-protect (progn ,@body)
         (set-buffer-modified-p nil)
         (kill-buffer)))))

(defun swamp-present-test--build-json (name &optional self-contained unchanged)
  "Return build JSON for deck NAME."
  (format "{\"status\":\"succeeded\",\"dataArtifacts\":[{\"name\":\"html-%s\"},{\"name\":\"deck-%s\",\"attributes\":{\"name\":\"%s\",\"slideCount\":4,\"warnings\":[],\"unchanged\":%s,\"reveal\":{\"selfContained\":%s}}}]}"
          name name name (if unchanged "true" "false")
          (if self-contained "true" "false")))

;;; ---------------------------------------------------------------------------
;;; Loading
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-present-commands-defined ()
  "The public commands and the transient are defined."
  (dolist (sym '(swamp-present-build swamp-present-preview
                 swamp-present-outline swamp-present-pdf
                 swamp-present-cancel swamp-present-dispatch))
    (should (commandp sym))))

(ert-deftest swamp-present-in-swamp-dispatch ()
  "Loading swamp-present adds it to `swamp-dispatch' under \"p\"."
  (should (transient-get-suffix 'swamp-dispatch "p")))

;;; ---------------------------------------------------------------------------
;;; Names and arguments
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-present-method-args-compose-inputs ()
  "Method arguments carry the source, the buffer's name and extra inputs."
  (with-temp-buffer
    (should (equal (swamp-present--method-args "talks" "build" "/t/a.org")
                   '("model" "method" "run" "talks" "build"
                     "--input" "source=/t/a.org" "--json")))
    (setq-local swamp-present-name "a-web")
    (should (equal (swamp-present--method-args
                    "talks" "build" "/t/a.org" "selfContained=true")
                   '("model" "method" "run" "talks" "build"
                     "--input" "source=/t/a.org"
                     "--input" "name=a-web"
                     "--input" "selfContained=true" "--json")))))

(ert-deftest swamp-present-local-values-are-checked ()
  "File-local values must be names swamp and the extension accept."
  (let ((name (get 'swamp-present-name 'safe-local-variable))
        (deck (get 'swamp-present-deck 'safe-local-variable)))
    (should (funcall name "talk-2"))
    (should (funcall name (make-string 63 ?a)))
    (should-not (funcall name (make-string 64 ?a)))
    (should-not (funcall name "Talk 2"))
    (should-not (funcall name 42))
    (should (funcall deck "talks.v2"))
    (should-not (funcall deck "--repo-dir=/x"))
    (should-not (funcall deck "a b"))))

(ert-deftest swamp-present-deck-from-org-keyword ()
  "An Org buffer's #+SWAMP_DECK: keyword wins, and must be a valid name."
  (with-temp-buffer
    (insert "#+TITLE: x\n#+swamp_deck: conference\n* One\n")
    (org-mode)
    (should (equal (swamp-present--deck) "conference")))
  (with-temp-buffer
    (insert "#+SWAMP_DECK: --help\n* One\n")
    (org-mode)
    (should-error (swamp-present--deck) :type 'user-error))
  (with-temp-buffer
    (insert "* One\n")
    (org-mode)
    (let ((swamp-present-deck "talks"))
      (should (equal (swamp-present--deck) "talks")))))

(ert-deftest swamp-present-record-is-the-artifact-with-attributes ()
  "The method's resource is the data artifact that carries attributes."
  (let ((result '((dataArtifacts . (((name . "html-t"))
                                    ((name . "deck-t")
                                     (attributes . ((name . "t")))))))))
    (should (equal (swamp-present--record result) '((name . "t"))))))

(ert-deftest swamp-present-report-build-reads-json-booleans ()
  "JSON false parses as :false, which must not read as true."
  (let ((record (json-parse-string
                 "{\"name\":\"t\",\"slideCount\":3,\"warnings\":[],\"unchanged\":false,\"reveal\":{\"selfContained\":false}}"
                 :object-type 'alist :array-type 'list)))
    (should (equal (swamp-present-test--capturing-messages
                    (swamp-present--report-build "talks" record))
                   '("Built t: 3 slides"))))
  (let ((record (json-parse-string
                 "{\"name\":\"t\",\"slideCount\":3,\"warnings\":[\"img/x.png: file not found\"],\"unchanged\":true,\"reveal\":{\"selfContained\":true}}"
                 :object-type 'alist :array-type 'list)))
    (should (equal (swamp-present-test--capturing-messages
                    (swamp-present--report-build "talks" record))
                   '("Unchanged t: 3 slides, self-contained, 1 warnings (see *swamp-present*)")))))

(ert-deftest swamp-present-outline-rows ()
  "Outline rows show index, title, notes and image count."
  (let ((rows (swamp-present--outline-rows
               '((slides . (((index . "1") (title . "Intro")
                             (notesWords . 3) (images . ("a.png")))
                            ((index . "1.2") (title . "")
                             (notesWords . 0) (images . ()))))))))
    (should (equal (mapcar (lambda (r) (substring-no-properties
                                        (aref (cadr r) 2)))
                           rows)
                   '("3" "none")))
    (should (equal (aref (cadr (car rows)) 3) "1"))
    (should (equal (aref (cadr (cadr rows)) 1) "(untitled)"))))

;;; ---------------------------------------------------------------------------
;;; Running swamp
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-present-run-puts-repo-dir-after-the-command ()
  "A succeeded run hands the parsed JSON on; --repo-dir comes last."
  (swamp-present-test--with-fake-swamp
      '(("*" "{\"status\":\"succeeded\",\"dataArtifacts\":[]}" 0))
    (let ((swamp-repo-dir "/repo") got)
      (swamp-present--run '("model" "method" "run" "d" "build" "--json")
                          (lambda (r) (setq got r)))
      (swamp-present-test--wait)
      (should (equal (alist-get 'status got) "succeeded"))
      (should (equal (swamp-present-test--calls)
                     '(("model" "method" "run" "d" "build" "--json"
                        "--repo-dir" "/repo")))))))

(ert-deftest swamp-present-run-reports-failure-from-stdout-or-stderr ()
  "swamp's JSON error is shown whether it arrives on stdout or stderr."
  (swamp-present-test--with-fake-swamp
      '(("*build*" "{\"error\":\"Source not found: x.org\"}" 1)
        ("*outline*" "" 1 "{\"error\":\"Model not found: nope\"}"))
    (let (called)
      (should (equal
               (swamp-present-test--capturing-messages
                (swamp-present--run '("model" "method" "run" "d" "build")
                                    (lambda (_) (setq called t)))
                (swamp-present-test--wait)
                (swamp-present--run '("model" "method" "run" "d" "outline")
                                    (lambda (_) (setq called t)))
                (swamp-present-test--wait))
               '("swamp: Source not found: x.org"
                 "swamp: Model not found: nope")))
      (should-not called))))

(ert-deftest swamp-present-run-times-out ()
  "A command that outlives `swamp-present-timeout' is stopped and reported."
  (swamp-present-test--with-fake-swamp
      '(("*" "" 0))
    (with-temp-file swamp-executable (insert "#!/bin/sh\nsleep 30\n"))
    (let ((swamp-present-timeout 1) called)
      (should (equal (swamp-present-test--capturing-messages
                      (swamp-present--run '("model" "method" "run" "d" "build")
                                          (lambda (_) (setq called t)))
                      (swamp-present-test--wait))
                     '("swamp: build timed out after 1s")))
      (should-not called))))

(ert-deftest swamp-present-cancel-stops-commands ()
  "`swamp-present-cancel' stops what is running."
  (swamp-present-test--with-fake-swamp
      '(("*" "" 0))
    (with-temp-file swamp-executable (insert "#!/bin/sh\nsleep 30\n"))
    (let (called)
      (swamp-present--run '("model" "method" "run" "d" "build")
                          (lambda (_) (setq called t)))
      (should (equal (swamp-present-test--capturing-messages
                      (swamp-present-cancel)
                      (swamp-present-test--wait))
                     '("swamp: build cancelled" "Stopped 1 swamp command")))
      (swamp-present-test--wait)
      (should-not called))))

(ert-deftest swamp-present-fetch-returns-exact-content ()
  "Fetched content is the stored bytes, without swamp's trailing newline."
  (swamp-present-test--with-fake-swamp
      '(("*" "<html>d\303\251ck</html>\n\n" 0))
    (let (got)
      (swamp-present--fetch "talks" "html-t" (lambda (c) (setq got c)))
      (swamp-present-test--wait)
      (should (equal got "<html>d\303\251ck</html>\n"))
      (should-not (multibyte-string-p got))
      (should (equal (swamp-present-test--calls)
                     '(("data" "query"
                        "model(\"talks\") && name == \"html-t\""
                        "--select" "content")))))))

(ert-deftest swamp-present-fetch-reports-empty-content ()
  "An empty result is reported, not written as an empty file."
  (swamp-present-test--with-fake-swamp '(("*" "\n" 0))
    (let (called)
      (should (equal (swamp-present-test--capturing-messages
                      (swamp-present--fetch "talks" "pdf-t"
                                            (lambda (_) (setq called t)))
                      (swamp-present-test--wait))
                     '("swamp: talks has no pdf-t yet")))
      (should-not called))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-present-build-refuses-non-deck-buffers ()
  "Building needs an Org or Markdown file."
  (with-temp-buffer
    (should-error (swamp-present-build) :type 'user-error))
  (let ((file (make-temp-file "swamp-present-" nil ".txt")))
    (unwind-protect
        (with-current-buffer (find-file-noselect file)
          (unwind-protect
              (should-error (swamp-present-build) :type 'user-error)
            (kill-buffer)))
      (delete-file file))))

(ert-deftest swamp-present-preview-writes-and-opens-the-deck ()
  "Preview builds, fetches the deck's HTML and opens the written file."
  (swamp-present-test--with-fake-swamp
      `(("*build*" ,(swamp-present-test--build-json "talk") 0)
        ("*html-talk*" "<html>deck</html>\n" 0))
    (let (opened)
      (cl-letf (((symbol-function 'browse-url-of-file)
                 (lambda (f) (setq opened f))))
        (swamp-present-test--in-deck
         (swamp-present-preview)
         (swamp-present-test--wait)))
      (should (equal opened
                     (expand-file-name "swamp-present-talks-talk.html"
                                       swamp-present-output-directory)))
      (should (equal (with-temp-buffer (insert-file-contents opened)
                                       (buffer-string))
                     "<html>deck</html>"))
      (should (= (file-modes swamp-present-output-directory) #o700)))))

(ert-deftest swamp-present-pdf-passes-self-contained-and-prints-by-name ()
  "PDF builds as asked, then prints the recorded deck name, not the source."
  (swamp-present-test--with-fake-swamp
      `(("*build*" ,(swamp-present-test--build-json "talk-web" t) 0)
        ("*export_pdf*" "{\"status\":\"succeeded\",\"dataArtifacts\":[{\"name\":\"print-talk-web\",\"attributes\":{\"pdf\":{\"pages\":5},\"unchanged\":false}}]}" 0)
        ("*pdf-talk-web*" ,(concat (base64-encode-string "%PDF-1.7\n\377") "\n") 0))
    (swamp-present-test--in-deck
     (setq-local swamp-present-name "talk-web")
     (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
       (swamp-present-pdf '(4))
       (swamp-present-test--wait)
       (swamp-present-test--wait)))
    (let ((calls (swamp-present-test--calls)))
      (should (member "selfContained=true" (nth 0 calls)))
      (should (equal (nth 1 calls)
                     '("model" "method" "run" "talks" "export_pdf"
                       "--input" "name=talk-web" "--json")))
      (should (equal (nth 1 (nth 2 calls))
                     "query")))
    (let ((pdf (expand-file-name "swamp-present-talks-talk-web.pdf"
                                 swamp-present-output-directory)))
      (should (equal (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (let ((coding-system-for-read 'binary))
                         (insert-file-contents pdf))
                       (buffer-string))
                     "%PDF-1.7\n\377")))))

(ert-deftest swamp-present-write-reverts-a-visiting-buffer ()
  "Rewriting an open preview refreshes its buffer without asking."
  (let ((file (make-temp-file "swamp-present-" nil ".txt")))
    (unwind-protect
        (let ((buf (progn (with-temp-file file (insert "old"))
                          (find-file-noselect file))))
          (unwind-protect
              (progn
                (should (eq (swamp-present--write file "new") buf))
                (should (equal (with-current-buffer buf (buffer-string)) "new")))
            (kill-buffer buf)))
      (delete-file file))))

(ert-deftest swamp-present-write-keeps-bytes ()
  "Binary content round-trips through the preview file unchanged."
  (let ((file (make-temp-file "swamp-present-" nil ".pdf"))
        (bytes (unibyte-string 37 80 68 70 0 255 10 13)))
    (unwind-protect
        (progn
          (swamp-present--write file bytes)
          (should (equal (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (let ((coding-system-for-read 'binary))
                             (insert-file-contents file))
                           (buffer-string))
                         bytes)))
      (delete-file file))))

(provide 'test-swamp-present)
;;; test-swamp-present.el ends here
