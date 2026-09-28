;;; pps-mode-test.el --- Tests for PPS Mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Pinnacle Point Development
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Code:

(require 'ert)
(require 'pps-mode)

(defconst pps-test--simple
  "(pps
     :version 1
     :meta (:title \"Test\")
     :active-sheet \"Data\"
     :sheets
     [(:sheet :name \"Data\"
       :columns [(:column :name \"Name\" :type :text)
                 (:column :name \"Value\" :type :number)]
       :rows [[\"alpha\" 2] [\"beta\" 3]])])")

(defmacro pps-test--with-buffer (source &rest body)
  "Open SOURCE in a temporary PPS buffer and evaluate BODY."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,source)
     (pps-mode)
     ,@body))

(ert-deftest pps-test-parse-basic-workbook ()
  (let* ((workbook (pps--parse pps-test--simple))
         (sheet (car (pps--workbook-sheets workbook))))
    (should (= (pps--workbook-version workbook) 1))
    (should (equal (plist-get (pps--workbook-meta workbook) :title) "Test"))
    (should (equal (pps--sheet-name sheet) "Data"))
    (should (= (length (pps--sheet-columns sheet)) 2))
    (should (equal (aref (car (pps--sheet-rows sheet)) 0) "alpha"))))

(ert-deftest pps-test-round-trip-is-stable ()
  (let* ((pps--workbook (pps--parse pps-test--simple))
         (first (pps--serialize))
         (pps--workbook (pps--parse first))
         (second (pps--serialize)))
    (should (equal first second))
    (should (string-suffix-p "\n" first))))

(ert-deftest pps-test-safe-reader-rejects-extra-form ()
  (should-error (pps--parse (concat pps-test--simple "\n(delete-file \"x\")"))
                :type 'error))

(ert-deftest pps-test-safe-reader-rejects-reader-evaluation ()
  (should-error
   (pps--parse
    "(pps :version 1 :sheets #.(progn (error \"executed\") []))")
   :type 'error))

(ert-deftest pps-test-safe-reader-rejects-circular-labels ()
  (should-error
   (pps--parse
    "(pps :version 1 :sheets #1=[#1#])")
   :type 'error))

(ert-deftest pps-test-rejects-unknown-keys-and-ragged-rows ()
  (should-error
   (pps--parse
    "(pps :version 1 :surprise t :sheets [])"))
  (should-error
   (pps--parse
    "(pps :version 1 :sheets [(:sheet :name \"S\" :columns [(:column :name \"A\" :type :auto)] :rows [[1 2]])])")))

(ert-deftest pps-test-formula-arithmetic-range-and-cross-sheet ()
  (pps-test--with-buffer
      "(pps :version 1 :active-sheet \"Main\" :sheets
        [(:sheet :name \"Main\"
          :columns [(:column :name \"A\" :type :number)
                    (:column :name \"B\" :type :number)
                    (:column :name \"C\" :type :number)]
          :rows [[2 3 (:formula (+ A1 B1))]
                 [4 5 (:formula (sum (range A1 B2)))]] )
         (:sheet :name \"Rates\"
          :columns [(:column :name \"Rate\" :type :number)]
          :rows [[10]])])"
    (let ((sheet (pps--active-sheet)))
      (should (= (pps--cell-value sheet 0 2 nil) 5))
      (should (= (pps--cell-value sheet 1 2 nil) 14))
      (pps--set-cell-internal
       sheet 0 2
       (pps--formula-create
        :expr (pps--safe-read-one "(+ (cell \"Rates\" A1) B1)")))
      (setq pps--formula-cache (make-hash-table :test #'equal))
      (should (= (pps--cell-value sheet 0 2 nil) 13)))))

(ert-deftest pps-test-formula-cycle-and-division-errors ()
  (pps-test--with-buffer
      "(pps :version 1 :sheets
        [(:sheet :name \"S\"
          :columns [(:column :name \"A\" :type :auto)
                    (:column :name \"B\" :type :auto)]
          :rows [[(:formula B1) (:formula A1)]
                 [(:formula (/ 1 0)) :blank]])])"
    (let ((sheet (pps--active-sheet)))
      (should (equal (pps--error-code (pps--cell-value sheet 0 0 nil))
                     "#CYCLE!"))
      (should (equal (pps--error-code (pps--cell-value sheet 1 0 nil))
                     "#DIV/0!")))))

(ert-deftest pps-test-formula-spreadsheet-division-and-booleans ()
  (pps-test--with-buffer
      "(pps :version 1 :sheets
        [(:sheet :name \"S\"
          :columns [(:column :name \"A\" :type :auto)
                    (:column :name \"B\" :type :auto)]
          :rows [[(:formula (/ 5 2)) (:formula (= 1 2))]])])"
    (let ((sheet (pps--active-sheet)))
      (should (= (pps--cell-value sheet 0 0 nil) 2.5))
      (should (eq (pps--cell-value sheet 0 1 nil) pps--false))
      (should (equal (pps--cell-display sheet 0 1) "FALSE")))))

(ert-deftest pps-test-render-has-retro-grid-and-properties ()
  (pps-test--with-buffer pps-test--simple
    (should (string-match-p "PINNACLE POINT SPREADSHEET" (buffer-string)))
    (should (string-match-p "A Name" (buffer-string)))
    (should (gethash '(0 . 0) pps--cell-positions))
    (should (eq (get-text-property
                 (car (gethash '(0 . 0) pps--cell-positions)) 'pps-row)
                0))))

(ert-deftest pps-test-edit-undo-redo ()
  (pps-test--with-buffer pps-test--simple
    (pps-set-cell 0 1 9)
    (should (= (aref (car (pps--sheet-rows (pps--active-sheet))) 1) 9))
    (should (buffer-modified-p))
    (pps-undo)
    (should (= (aref (car (pps--sheet-rows (pps--active-sheet))) 1) 2))
    (pps-redo)
    (should (= (aref (car (pps--sheet-rows (pps--active-sheet))) 1) 9))))

(ert-deftest pps-test-row-and-column-structure ()
  (pps-test--with-buffer pps-test--simple
    (pps-insert-row-above 2)
    (should (= (length (pps--sheet-rows (pps--active-sheet))) 4))
    (let ((read-string-function (lambda (&rest _) "Extra")))
      (cl-letf (((symbol-function 'read-string) read-string-function)
                ((symbol-function 'completing-read)
                 (lambda (&rest _) ":text")))
        (pps-insert-column-before)))
    (should (= (length (pps--sheet-columns (pps--active-sheet))) 3))
    (should (cl-every (lambda (row) (= (length row) 3))
                      (pps--sheet-rows (pps--active-sheet))))))

(ert-deftest pps-test-structural-edits-adjust-formulas ()
  (pps-test--with-buffer
      "(pps :version 1 :sheets
        [(:sheet :name \"S\"
          :columns [(:column :name \"A\" :type :auto)
                    (:column :name \"B\" :type :auto)]
          :rows [[1 :blank]
                 [2 (:formula (+ A1 $A$1))]
                 [3 (:formula A1)]])])"
    (pps-insert-row-above 1)
    (let* ((sheet (pps--active-sheet))
           (formula (aref (nth 2 (pps--sheet-rows sheet)) 1)))
      (should (equal (mapcar #'symbol-name
                             (cdr (pps--formula-expr formula)))
                     '("A2" "$A$2"))))
    (setq pps--row 1 pps--mark-cell nil)
    (pps-delete-rows)
    (let* ((sheet (pps--active-sheet))
           (formula (aref (nth 1 (pps--sheet-rows sheet)) 1))
           (first-reference (cadr (pps--formula-expr formula))))
      (should (equal (symbol-name (car first-reference))
                     "ref-error"))
      (setq pps--formula-cache (make-hash-table :test #'equal))
      (should (equal (pps--error-code (pps--cell-value sheet 1 1 nil))
                     "#REF!"))
      (let* ((pps--workbook pps--workbook)
             (round-trip (pps--parse (pps--serialize))))
        (should (pps--workbook-p round-trip))))))

(ert-deftest pps-test-cross-sheet-structural-reference-adjustment ()
  (pps-test--with-buffer
      "(pps :version 1 :active-sheet \"Data\" :sheets
        [(:sheet :name \"Data\"
          :columns [(:column :name \"A\" :type :auto)] :rows [[10]])
         (:sheet :name \"Calc\"
          :columns [(:column :name \"A\" :type :auto)]
          :rows [[(:formula (cell \"Data\" A1))]])])"
    (pps-insert-row-above 1)
    (let* ((calc (pps--sheet-by-name "Calc"))
           (formula (aref (car (pps--sheet-rows calc)) 0))
           (reference (nth 2 (pps--formula-expr formula))))
      (should (equal (symbol-name reference) "A2")))))

(ert-deftest pps-test-delimited-parser-rfc4180-cases ()
  (should
   (equal (pps--parse-delimited
           "name,note,empty\r\nAlice,\"one, two\",\r\nBob,\"line 1\nline 2\",x\r\n"
           ",")
          '(("name" "note" "empty")
            ("Alice" "one, two" "")
            ("Bob" "line 1\nline 2" "x")))))

(ert-deftest pps-test-delimited-round-trip ()
  (let* ((matrix '(("a" "b,c" "d\"e") ("line\nwrap" "" "z")))
         (encoded (pps--matrix-to-delimited matrix ",")))
    (should (equal (pps--parse-delimited encoded ",") matrix))))

(ert-deftest pps-test-copy-translates-relative-formulas ()
  (let* ((expression (pps--safe-read-one "(+ A1 $B1 C$2 $D$3)"))
         (translated (pps--translate-formula-expression expression 2 1)))
    (should (equal (mapcar #'symbol-name (cdr translated))
                   '("B3" "$B3" "D$2" "$D$3")))))

(ert-deftest pps-test-filter-and-search-model ()
  (pps-test--with-buffer pps-test--simple
    (setq pps--filter "beta")
    (pps--render)
    (should (equal pps--visible-indices '(1)))
    (should (= pps--row 1))))

(ert-deftest pps-test-paging-limits-rendered-rows ()
  (pps-test--with-buffer pps-test--simple
    (let* ((sheet (pps--active-sheet))
           (pps-page-size 5))
      (setf (pps--sheet-rows sheet)
            (cl-loop for index below 30 collect (vector (format "r%d" index) index)))
      (pps--render)
      (should (= (hash-table-count pps--cell-positions) 10)))))

(ert-deftest pps-test-save-writes-model-not-rendered-grid ()
  (let ((file (make-temp-file "pps-save-" nil ".pps")) buffer)
    (unwind-protect
        (progn
          (with-temp-file file (insert pps-test--simple))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (pps-set-cell 0 0 "changed")
            (save-buffer)
            (should-not (buffer-modified-p)))
          (let ((disk (with-temp-buffer
                        (insert-file-contents file)
                        (buffer-string))))
            (should (string-prefix-p ";; Pinnacle Point Spreadsheet" disk))
            (should-not (string-match-p "PINNACLE POINT SPREADSHEET  ::" disk))
            (should (pps--workbook-p (pps--parse disk)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest pps-test-auto-save-writes-valid-pps ()
  (let ((file (make-temp-file "pps-autosave-source-" nil ".pps"))
        buffer auto-file)
    (unwind-protect
        (progn
          (with-temp-file file (insert pps-test--simple))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (pps-set-cell 0 0 "auto-saved")
            (auto-save-mode 1)
            (setq auto-file buffer-auto-save-file-name)
            (do-auto-save t t))
          (should (file-exists-p auto-file))
          (let ((text (with-temp-buffer
                        (insert-file-contents auto-file)
                        (buffer-string))))
            (should (string-prefix-p ";; Pinnacle Point Spreadsheet" text))
            (should (pps--workbook-p (pps--parse text)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (when (and auto-file (file-exists-p auto-file)) (delete-file auto-file))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest pps-test-import-never-promotes-leading-equals ()
  (should (equal (pps--import-cell "=shell-command()" t)
                 "=shell-command()")))

(provide 'pps-mode-test)

;;; pps-mode-test.el ends here
