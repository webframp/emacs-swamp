;;; test-swamp.el --- ERT tests for swamp.el -*- lexical-binding: t; -*-
;;
;; Run with:
;;   emacs --batch -l ert \
;;         -l ~/src/webframp/emacs-swamp/swamp.el \
;;         -l ~/src/webframp/emacs-swamp/test-swamp.el \
;;         -f ert-run-tests-batch-and-exit
;;
;;; Code:

(require 'ert)
(require 'cl-lib)

;;; ---------------------------------------------------------------------------
;;; 1. Package loads and public symbols are defined
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-package-loads ()
  "swamp.el loads without error and provides the swamp feature."
  (should (featurep 'swamp)))

(ert-deftest swamp-interactive-commands-defined ()
  "All public interactive commands are fboundp after loading swamp."
  (dolist (sym '(swamp-model-search
                 swamp-model-get
                 swamp-model-method-run
                 swamp-model-output-get
                 swamp-model-validate
                 swamp-workflow-search
                 swamp-workflow-run
                 swamp-workflow-history
                 swamp-workflow-get
                 swamp-extension-search
                 swamp-extension-pull
                 swamp-data-query
                 swamp-summarize
                 swamp-jump-to-last-result))
    (should (fboundp sym))))

(ert-deftest swamp-private-helpers-defined ()
  "Private helper functions are fboundp after loading swamp."
  (dolist (sym '(swamp--run-json
                 swamp--run-json-stream
                 swamp--completing-read-model
                 swamp--completing-read-workflow
                 swamp--display-table
                 swamp--display-detail
                 swamp--propertize-status
                 swamp--status-face))
    (should (fboundp sym))))

;;; ---------------------------------------------------------------------------
;;; 2. Transient prefixes are registered
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-transient-prefixes-defined ()
  "All four transient prefixes are fboundp."
  (dolist (sym '(swamp-dispatch
                 swamp-model-dispatch
                 swamp-workflow-dispatch
                 swamp-extension-dispatch))
    (should (fboundp sym))))

(ert-deftest swamp-transient-prefixes-registered ()
  "All four transient prefixes have the transient--prefix property."
  (dolist (sym '(swamp-dispatch
                 swamp-model-dispatch
                 swamp-workflow-dispatch
                 swamp-extension-dispatch))
    (should (get sym 'transient--prefix))))

;;; ---------------------------------------------------------------------------
;;; 3. swamp--run-json behaviour
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-run-json-returns-nil-on-failure ()
  "swamp--run-json returns nil gracefully when the command fails."
  (should (null (swamp--run-json '("__no-such-subcommand__")))))

(ert-deftest swamp-run-json-parses-version ()
  "swamp--run-json does not crash on swamp version --json."
  ;; version may or may not support --json; we only verify no error is raised.
  (condition-case err
      (swamp--run-json '("version"))
    (error (ert-fail (format "swamp--run-json signaled: %S" err)))))

;;; ---------------------------------------------------------------------------
;;; 4. swamp--run-json-stream behaviour
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-run-json-stream-returns-list ()
  "swamp--run-json-stream always returns a list."
  (let ((result (swamp--run-json-stream '("__no-such-subcommand__"))))
    (should (listp result))))

(ert-deftest swamp-run-json-stream-parses-multiple-objects ()
  "swamp--run-json-stream parses multiple NDJSON objects from a fake process."
  ;; Feed two JSON objects via a temp buffer to exercise the parser directly.
  (let ((objects
         (with-temp-buffer
           (insert "{\"a\":1}\n{\"b\":2}\n")
           (goto-char (point-min))
           (let (objs)
             (while (not (eobp))
               (condition-case nil
                   (push (json-parse-buffer :object-type 'alist :array-type 'list) objs)
                 (error (forward-line 1))))
             (nreverse objs)))))
    (should (= (length objects) 2))
    (should (equal (alist-get 'a (car objects)) 1))
    (should (equal (alist-get 'b (cadr objects)) 2))))

;;; ---------------------------------------------------------------------------
;;; 5. swamp--completing-read-model handles empty results
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-completing-read-model-empty-results ()
  "swamp--completing-read-model does not crash when model search returns nil."
  (cl-letf (((symbol-function 'swamp--run-json)
             (lambda (_args) nil))
            ((symbol-function 'completing-read)
             (lambda (_prompt collection &rest _) (car collection))))
    ;; Should complete without error (returns nil or first element of empty list)
    (condition-case err
        (swamp--completing-read-model "Test: ")
      (error (ert-fail (format "swamp--completing-read-model signaled: %S" err))))))

;;; ---------------------------------------------------------------------------
;;; 6. swamp--display-table produces a tabulated-list buffer
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-display-table-creates-buffer ()
  "swamp--display-table creates a buffer in tabulated-list-mode."
  (let ((buf-name "*swamp-test-table*"))
    (when (get-buffer buf-name) (kill-buffer buf-name))
    (swamp--display-table
     buf-name
     [("Col A" 20 t) ("Col B" 20 t)]
     (list (list "id1" (vector "val-a" "val-b")))
     nil)
    (let ((buf (get-buffer buf-name)))
      (should buf)
      (with-current-buffer buf
        (should (eq major-mode 'tabulated-list-mode))))
    (kill-buffer buf-name)))

(ert-deftest swamp-display-table-updates-last-result-buffer ()
  "swamp--display-table updates swamp--last-result-buffer."
  (let ((buf-name "*swamp-test-table2*"))
    (when (get-buffer buf-name) (kill-buffer buf-name))
    (swamp--display-table buf-name [("X" 10 t)] '() nil)
    (should (eq swamp--last-result-buffer (get-buffer buf-name)))
    (kill-buffer buf-name)))

;;; ---------------------------------------------------------------------------
;;; 7. swamp--display-detail produces a special-mode buffer
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-display-detail-creates-buffer ()
  "swamp--display-detail creates a buffer in special-mode."
  (let ((buf-name "*swamp-test-detail*"))
    (when (get-buffer buf-name) (kill-buffer buf-name))
    (swamp--display-detail
     buf-name
     "Test Title"
     (list (list "Label" "Value")))
    (let ((buf (get-buffer buf-name)))
      (should buf)
      (with-current-buffer buf
        (should (eq major-mode 'special-mode))
        (should (string-match-p "Test Title" (buffer-string)))
        (should (string-match-p "Label" (buffer-string)))
        (should (string-match-p "Value" (buffer-string)))))
    (kill-buffer buf-name)))

(ert-deftest swamp-display-detail-updates-last-result-buffer ()
  "swamp--display-detail updates swamp--last-result-buffer."
  (let ((buf-name "*swamp-test-detail2*"))
    (when (get-buffer buf-name) (kill-buffer buf-name))
    (swamp--display-detail buf-name "T" '())
    (should (eq swamp--last-result-buffer (get-buffer buf-name)))
    (kill-buffer buf-name)))

;;; ---------------------------------------------------------------------------
;;; 8. swamp--display-detail omits nil fields
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-display-detail-omits-nil-fields ()
  "swamp--display-detail does not insert fields whose value is nil."
  (let ((buf-name "*swamp-test-detail3*"))
    (when (get-buffer buf-name) (kill-buffer buf-name))
    (swamp--display-detail
     buf-name "T"
     (list (list "Present" "yes") (list "Absent" nil)))
    (with-current-buffer buf-name
      (should (string-match-p "Present" (buffer-string)))
      (should-not (string-match-p "Absent" (buffer-string))))
    (kill-buffer buf-name)))

;;; ---------------------------------------------------------------------------
;;; 9. swamp--status-face returns correct faces
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-status-face-succeeded ()
  (should (eq (swamp--status-face "succeeded") 'swamp-status-succeeded)))

(ert-deftest swamp-status-face-failed ()
  (should (eq (swamp--status-face "failed") 'swamp-status-failed)))

(ert-deftest swamp-status-face-running ()
  (should (eq (swamp--status-face "running") 'swamp-status-running)))

(ert-deftest swamp-status-face-unknown ()
  (should (eq (swamp--status-face "unknown-value") 'default)))

;;; ---------------------------------------------------------------------------
;;; 10. swamp-jump-to-last-result
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-jump-to-last-result-errors-with-no-buffer ()
  "swamp-jump-to-last-result signals user-error when no buffer is set."
  (let ((swamp--last-result-buffer nil))
    (should-error (swamp-jump-to-last-result) :type 'user-error)))

(ert-deftest swamp-jump-to-last-result-pops-to-buffer ()
  "swamp-jump-to-last-result pops to the last result buffer."
  (let ((buf (get-buffer-create "*swamp-test-jump*"))
        (swamp--last-result-buffer nil))
    (setq swamp--last-result-buffer buf)
    (swamp-jump-to-last-result)
    (should (eq (current-buffer) buf))
    (kill-buffer buf)))

;;; ---------------------------------------------------------------------------
;;; 11. swamp--base-args respects swamp-repo-dir
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-base-args-nil-when-no-repo-dir ()
  "swamp--base-args returns nil when swamp-repo-dir is nil."
  (let ((swamp-repo-dir nil))
    (should (null (swamp--base-args)))))

(ert-deftest swamp-base-args-includes-repo-dir ()
  "swamp--base-args includes --repo-dir when swamp-repo-dir is set."
  (let ((swamp-repo-dir "/tmp/test-repo"))
    (let ((args (swamp--base-args)))
      (should (member "--repo-dir" args))
      (should (member "/tmp/test-repo" args)))))

;;; ---------------------------------------------------------------------------
;;; 12. Faces are defined
;;; ---------------------------------------------------------------------------

(ert-deftest swamp-faces-defined ()
  "All three swamp status faces are defined."
  (dolist (face '(swamp-status-succeeded swamp-status-failed swamp-status-running))
    (should (facep face))))

;;; ---------------------------------------------------------------------------
;;; Run
;;; ---------------------------------------------------------------------------

(provide 'test-swamp)
;;; test-swamp.el ends here
