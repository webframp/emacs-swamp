;;; test-swamp-present.el --- ERT tests for swamp-present.el -*- lexical-binding: t; -*-
;;
;; Run with:
;;   emacs --batch -l ert -L . \
;;         -l swamp-present.el \
;;         -l test-swamp-present.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; The process tests run a fake swamp executable, a shell script that
;; prints canned output, so the real argument handling and JSON parsing are
;; exercised without swamp installed.
;;
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'swamp-present)

(defmacro swamp-present-test--with-fake-swamp (stdout exit &rest body)
  "Run BODY with `swamp-executable' printing STDOUT and exiting with EXIT.
The script records its arguments, one per line, in the file bound to
`args-file'."
  (declare (indent 2))
  `(let* ((dir (make-temp-file "swamp-present-test-" t))
          (args-file (expand-file-name "args" dir))
          (out-file (expand-file-name "out" dir))
          (script (expand-file-name "swamp" dir))
          (swamp-executable script)
          (swamp-repo-dir nil))
     (unwind-protect
         (progn
           (let ((coding-system-for-write 'binary))
             (write-region ,stdout nil out-file nil 'silent))
           (with-temp-file script
             (insert "#!/bin/sh\n"
                     (format "printf '%%s\\n' \"$@\" > %s\n"
                             (shell-quote-argument args-file))
                     (format "cat %s\n" (shell-quote-argument out-file))
                     (format "exit %d\n" ,exit)))
           (set-file-modes script #o755)
           ,@body)
       (delete-directory dir t))))

(defun swamp-present-test--args (file)
  "Return the arguments recorded in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (split-string (buffer-string) "\n" t)))

(defun swamp-present-test--wait ()
  "Wait for every swamp-present process to finish."
  (while (seq-some (lambda (p) (string-prefix-p "swamp-present" (process-name p)))
                   (process-list))
    (accept-process-output nil 0.05)))

;;; ---------------------------------------------------------------------------
;;; Loading
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-present-commands-defined ()
  "The public commands and the transient are defined."
  (dolist (sym '(swamp-present-build swamp-present-preview
                 swamp-present-outline swamp-present-pdf
                 swamp-present-dispatch))
    (should (commandp sym))))

(ert-deftest swamp-present-in-swamp-dispatch ()
  "Loading swamp-present adds it to `swamp-dispatch' under \"p\"."
  (should (transient-get-suffix 'swamp-dispatch "p")))

;;; ---------------------------------------------------------------------------
;;; Arguments and records
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

(ert-deftest swamp-present-name-local-variable-is-checked ()
  "Only data-name-safe deck names are accepted as file-local values."
  (let ((safe (get 'swamp-present-name 'safe-local-variable)))
    (should (funcall safe "talk-2"))
    (should-not (funcall safe "Talk 2"))
    (should-not (funcall safe 42))))

(ert-deftest swamp-present-deck-from-org-keyword ()
  "An Org buffer's #+SWAMP_DECK: keyword wins over the default."
  (with-temp-buffer
    (insert "#+TITLE: x\n#+swamp_deck: conference\n* One\n")
    (org-mode)
    (should (equal (swamp-present--deck) "conference")))
  (with-temp-buffer
    (insert "* One\n")
    (org-mode)
    (let ((swamp-present-deck "talks"))
      (should (equal (swamp-present--deck) "talks")))))

(ert-deftest swamp-present-record-is-the-artifact-with-attributes ()
  "The method's resource is the data artifact that carries attributes."
  (let ((result '((dataArtifacts . (((name . "deck-t-html"))
                                    ((name . "deck-t")
                                     (attributes . ((name . "t")))))))))
    (should (equal (swamp-present--record result) '((name . "t"))))))

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

(ert-deftest swamp-present-run-passes-result-on-success ()
  "A succeeded run hands the parsed JSON to the callback."
  (swamp-present-test--with-fake-swamp
      "{\"status\":\"succeeded\",\"dataArtifacts\":[]}" 0
    (let ((swamp-repo-dir "/repo") got)
      (swamp-present--run '("model" "method" "run" "d" "build" "--json")
                          (lambda (r) (setq got r)))
      (swamp-present-test--wait)
      (should (equal (alist-get 'status got) "succeeded"))
      (should (equal (swamp-present-test--args args-file)
                     '("model" "method" "run" "d" "build" "--json"
                       "--repo-dir" "/repo"))))))

(ert-deftest swamp-present-run-reports-failure ()
  "A failed run shows swamp's error and never calls the callback."
  (swamp-present-test--with-fake-swamp
      "{\"error\":\"Source not found: x.org\"}" 1
    (let (called messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (swamp-present--run '("model" "method" "run" "d" "build" "--json")
                            (lambda (_) (setq called t)))
        (swamp-present-test--wait))
      (should-not called)
      (should (equal messages '("swamp: Source not found: x.org"))))))

(ert-deftest swamp-present-fetch-strips-the-trailing-newline ()
  "Fetched content is exactly the stored bytes."
  (swamp-present-test--with-fake-swamp "<html>deck</html>\n" 0
    (should (equal (swamp-present--fetch "talks" "deck-t-html")
                   "<html>deck</html>"))
    (should (equal (swamp-present-test--args args-file)
                   '("data" "query" "model(\"talks\") && name == \"deck-t-html\""
                     "--select" "content")))))

(ert-deftest swamp-present-fetch-rejects-empty-content ()
  "An empty result is an error, not an empty file."
  (swamp-present-test--with-fake-swamp "\n" 0
    (should-error (swamp-present--fetch "talks" "deck-t-pdf")
                  :type 'user-error)))

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
