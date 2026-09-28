;;; pps-mode.el --- Pinnacle Point Spreadsheet editor  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Pinnacle Point Development

;; Author: Pinnacle Point Development
;; Maintainer: Pinnacle Point Development
;; URL: https://github.com/Pinnacle-Point-Development/pps-mode
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: data, files, tools
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; PPS Mode is the reference editor for Pinnacle Point Spreadsheet
;; (.pps) files.  It presents a compact keyboard-driven grid while the
;; file on disk remains a safe, versioned, human-readable S-expression.
;;
;; Open a .pps file normally.  Type \[pps-help] for the command summary,
;; \[pps-edit-cell] to edit a cell, and \[save-buffer] to save it.
;; Formulas are Lisp-shaped data such as =(+ B1 C1) and are interpreted
;; by a small allowlist; they are never passed to `eval'.

;;; Code:

(require 'cl-lib)
(require 'easymenu)
(require 'pp)
(require 'seq)
(require 'subr-x)

(defgroup pps nil
  "Browse and edit Pinnacle Point Spreadsheet files."
  :group 'data
  :prefix "pps-")

(defcustom pps-default-column-width 12
  "Default display width of a column whose file does not set a width."
  :type 'integer)

(defcustom pps-min-column-width 4
  "Smallest permitted display width for a column."
  :type 'integer)

(defcustom pps-max-column-width 48
  "Largest automatically chosen display width for a column."
  :type 'integer)

(defcustom pps-width-scan-limit 1000
  "Maximum number of rows inspected when choosing automatic widths."
  :type 'integer)

(defcustom pps-page-size 500
  "Maximum number of filtered rows rendered at once.
The model still contains all rows.  Paging keeps large sheets responsive."
  :type 'integer)

(defcustom pps-max-file-bytes (* 32 1024 1024)
  "Largest PPS file the mode will parse, in bytes."
  :type 'integer)

(defcustom pps-max-rows 1000000
  "Maximum number of rows allowed in one sheet."
  :type 'integer)

(defcustom pps-max-columns 16384
  "Maximum number of columns allowed in one sheet."
  :type 'integer)

(defcustom pps-max-formula-range-cells 100000
  "Maximum number of cells one formula range may expand."
  :type 'integer)

(defcustom pps-retro-display t
  "When non-nil, use the black and yellow PPS display faces."
  :type 'boolean)

(defcustom pps-use-unicode-borders nil
  "When non-nil, draw the grid with Unicode box characters."
  :type 'boolean)

(defcustom pps-history-limit 100
  "Maximum number of workbook changes retained for undo."
  :type 'integer)

(defface pps-default-face
  '((t :inherit fixed-pitch :foreground "yellow" :background "black"))
  "Default PPS grid face."
  :group 'pps)

(defface pps-banner-face
  '((t :inherit pps-default-face :weight bold))
  "Face for the spreadsheet banner."
  :group 'pps)

(defface pps-header-face
  '((t :foreground "black" :background "yellow" :weight bold))
  "Face for column headers."
  :group 'pps)

(defface pps-current-cell-face
  '((t :foreground "black" :background "yellow" :weight bold))
  "Face for the active cell."
  :group 'pps)

(defface pps-selection-face
  '((t :inherit pps-default-face :inverse-video t))
  "Face for cells in the active rectangular selection."
  :group 'pps)

(defface pps-error-face
  '((t :foreground "red" :background "black" :weight bold))
  "Face for formula errors."
  :group 'pps)

(cl-defstruct (pps--workbook (:constructor pps--workbook-create))
  version meta sheets active-sheet)

(cl-defstruct (pps--sheet (:constructor pps--sheet-create))
  name columns rows)

(cl-defstruct (pps--column (:constructor pps--column-create))
  name type width format)

(cl-defstruct (pps--formula (:constructor pps--formula-create)) expr)
(cl-defstruct (pps--date (:constructor pps--date-create)) value datetime-p)
(cl-defstruct (pps--error (:constructor pps--error-create)) code detail)
(cl-defstruct (pps--state (:constructor pps--state-create))
  workbook row column)

(defconst pps--false (make-symbol "pps-false"))
(defconst pps--cell-types
  '(:auto :text :integer :number :boolean :date :datetime))
(defconst pps--meta-keys
  '(:title :author :description :created :modified :license))
(defconst pps--formula-functions
  '(+ - * / sum average min max count counta
      = /= < <= > >= if and or not concat
      round floor ceiling truncate abs mod expt sqrt
      len upper lower cell range ref-error))

(defvar-local pps--workbook nil)
(defvar-local pps--row 0)
(defvar-local pps--column 0)
(defvar-local pps--mark-cell nil)
(defvar-local pps--filter nil)
(defvar-local pps--filter-column nil)
(defvar-local pps--undo-stack nil)
(defvar-local pps--redo-stack nil)
(defvar-local pps--clipboard nil)
(defvar-local pps--cell-positions nil)
(defvar-local pps--formula-cache nil)
(defvar-local pps--face-cookie nil)
(defvar-local pps--loading nil)
(defvar-local pps--selection-overlay nil)
(defvar-local pps--visible-indices nil)
(defvar-local pps--saved-text nil)

(defun pps--symbol-name= (object name)
  "Return non-nil when OBJECT is a symbol named NAME."
  (and (symbolp object) (string= (symbol-name object) name)))

(defun pps--key-name (key)
  "Return the keyword-style name of KEY, or nil."
  (and (symbolp key) (symbol-name key)))

(defun pps--proper-plist-p (object)
  "Return non-nil when OBJECT is a proper, even-length property list."
  (and (proper-list-p object) (zerop (% (length object) 2))))

(defun pps--plist-get-name (plist name &optional absent)
  "Get from PLIST the property whose symbol name is NAME.
Return ABSENT if it is not present."
  (let ((tail plist)
        (result absent)
        found)
    (while tail
      (when (string= (or (pps--key-name (car tail)) "") name)
        (setq result (cadr tail)
              found t
              tail nil))
      (when tail
        (setq tail (cddr tail))))
    (if found result absent)))

(defun pps--validate-plist-keys (plist allowed context)
  "Validate PLIST keys against ALLOWED in CONTEXT."
  (unless (pps--proper-plist-p plist)
    (error "%s must be a proper property list" context))
  (let ((seen nil))
    (cl-loop for (key _value) on plist by #'cddr
             for name = (pps--key-name key)
             unless (and name (member name allowed))
             do (error "Unknown %s property: %S" context key)
             when (member name seen)
             do (error "Duplicate %s property: %s" context name)
             do (push name seen))))

(defun pps--safe-read-one (source &optional context)
  "Read exactly one data form from SOURCE without reader evaluation.
CONTEXT is used in diagnostics.  Symbols are interned in a private table."
  (let ((read-circle nil)
        (read-symbol-shorthands nil)
        (obarray (make-vector 4096 0))
        value end)
    (condition-case err
        (pcase-let ((result (read-from-string source)))
          (setq value (car result)
                end (cdr result)))
      (error
       (error "Invalid %s: %s" (or context "PPS data")
              (error-message-string err))))
    (condition-case nil
        (let ((extra (read-from-string source end)))
          (error "%s contains more than one form: %S"
                 (or context "PPS data") (car extra)))
      (end-of-file nil))
    value))

(defun pps--date-string-p (value datetime-p)
  "Return non-nil if VALUE has the required ISO date shape.
When DATETIME-P is non-nil, require an RFC 3339 style date-time."
  (and (stringp value)
       (if datetime-p
           (string-match-p
            "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\(?:\\.[0-9]+\\)?\\(?:Z\\|[+-][0-9]\\{2\\}:[0-9]\\{2\\}\\)\\'"
            value)
         (string-match-p
          "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" value))))

(defun pps--cell-reference-p (symbol)
  "Return non-nil when SYMBOL names an A1-style cell reference."
  (and (symbolp symbol)
       (string-match-p "\\`\\$?[A-Za-z]+\\$?[1-9][0-9]*\\'"
                       (symbol-name symbol))))

(defun pps--validate-formula (form &optional depth)
  "Validate formula FORM recursively and return it.
DEPTH is an internal recursion guard."
  (setq depth (or depth 0))
  (when (> depth 64)
    (error "Formula nesting exceeds 64 levels"))
  (cond
   ((or (numberp form) (stringp form)) form)
   ((symbolp form)
    (unless (or (pps--cell-reference-p form)
                (member (downcase (symbol-name form))
                        '("true" "false" "blank")))
      (error "Unknown formula symbol: %s" (symbol-name form)))
    form)
   ((consp form)
    (unless (proper-list-p form)
      (error "Formula lists must be proper lists"))
    (let ((operator (car form)))
      (unless (and (symbolp operator)
                   (memq (intern-soft (downcase (symbol-name operator)))
                         pps--formula-functions))
        (error "Formula function is not allowed: %S" operator))
      (dolist (argument (cdr form))
        (pps--validate-formula argument (1+ depth))))
    form)
   (t (error "Unsupported formula value: %S" form))))

(defun pps--decode-cell (cell)
  "Validate and convert an on-disk CELL to its internal form."
  (cond
   ((pps--symbol-name= cell ":blank") nil)
   ((pps--symbol-name= cell ":true") t)
   ((pps--symbol-name= cell ":false") pps--false)
   ((or (stringp cell) (numberp cell)) cell)
   ((and (proper-list-p cell) (= (length cell) 2)
         (pps--symbol-name= (car cell) ":formula"))
    (pps--formula-create :expr (pps--validate-formula (cadr cell))))
   ((and (proper-list-p cell) (= (length cell) 2)
         (pps--symbol-name= (car cell) ":date")
         (pps--date-string-p (cadr cell) nil))
    (pps--date-create :value (cadr cell) :datetime-p nil))
   ((and (proper-list-p cell) (= (length cell) 2)
         (pps--symbol-name= (car cell) ":datetime")
         (pps--date-string-p (cadr cell) t))
    (pps--date-create :value (cadr cell) :datetime-p t))
   (t (error "Invalid PPS cell: %S" cell))))

(defun pps--decode-meta (meta)
  "Validate and normalize workbook META."
  (when (pps--symbol-name= meta "nil")
    (setq meta nil))
  (pps--validate-plist-keys
   meta (mapcar #'symbol-name pps--meta-keys) "metadata")
  (let (result)
    (cl-loop for (key value) on meta by #'cddr
             for normalized = (intern (symbol-name key))
             unless (or (stringp value) (numberp value)
                        (pps--symbol-name= value ":true")
                        (pps--symbol-name= value ":false")
                        (pps--symbol-name= value ":blank"))
             do (error "Metadata %s has an unsupported value" key)
             do (setq result
                      (plist-put result normalized
                                 (cond
                                  ((pps--symbol-name= value ":true") t)
                                  ((pps--symbol-name= value ":false") pps--false)
                                  ((pps--symbol-name= value ":blank") nil)
                                  (t value)))))
    result))

(defun pps--decode-column (form index)
  "Decode column FORM at zero-based INDEX."
  (unless (and (consp form) (pps--symbol-name= (car form) ":column"))
    (error "Column %d must begin with :column" (1+ index)))
  (let ((plist (cdr form)))
    (pps--validate-plist-keys
     plist '(":name" ":type" ":width" ":format") "column")
    (let* ((name (pps--plist-get-name plist ":name" nil))
           (type-object (pps--plist-get-name plist ":type" nil))
           (type (and type-object (intern (symbol-name type-object))))
           (width (pps--plist-get-name plist ":width" nil))
           (format (pps--plist-get-name plist ":format" nil)))
      (unless (and (stringp name) (not (string-empty-p name)))
        (error "Column %d needs a nonempty :name" (1+ index)))
      (unless (memq type pps--cell-types)
        (error "Column %s has invalid type %S" name type-object))
      (when (and width
                 (not (and (integerp width)
                           (<= pps-min-column-width width 200))))
        (error "Column %s has invalid width %S" name width))
      (when (and format (not (stringp format)))
        (error "Column %s has a non-string format" name))
      (when (and format
                 (or (> (length format) 64)
                     (string-match-p "[[:cntrl:]]" format)))
        (error "Column %s has an unsafe format string" name))
      (pps--column-create :name name :type type :width width :format format))))

(defun pps--decode-sheet (form index)
  "Decode sheet FORM at zero-based INDEX."
  (unless (and (consp form) (pps--symbol-name= (car form) ":sheet"))
    (error "Sheet %d must begin with :sheet" (1+ index)))
  (let ((plist (cdr form)))
    (pps--validate-plist-keys plist '(":name" ":columns" ":rows") "sheet")
    (let* ((name (pps--plist-get-name plist ":name" nil))
           (column-forms (pps--plist-get-name plist ":columns" nil))
           (row-forms (pps--plist-get-name plist ":rows" nil)))
      (unless (and (stringp name) (not (string-empty-p name)))
        (error "Sheet %d needs a nonempty :name" (1+ index)))
      (unless (and (vectorp column-forms) (> (length column-forms) 0)
                   (<= (length column-forms) pps-max-columns))
        (error "Sheet %s needs 1..%d columns" name pps-max-columns))
      (unless (and (vectorp row-forms) (<= (length row-forms) pps-max-rows))
        (error "Sheet %s rows must be a vector of at most %d entries"
               name pps-max-rows))
      (let* ((columns (cl-loop for item across column-forms
                               for column-index from 0
                               collect (pps--decode-column item column-index)))
             (column-count (length columns))
             rows)
        (cl-loop for row across row-forms
                 for row-index from 0
                 do (unless (and (vectorp row) (= (length row) column-count))
                      (error "Row %d of %s has %d cells; expected %d"
                             (1+ row-index) name
                             (if (vectorp row) (length row) -1) column-count))
                 do (push (vconcat (mapcar #'pps--decode-cell
                                           (append row nil))) rows))
        (pps--sheet-create :name name :columns columns :rows (nreverse rows))))))

(defun pps--parse (source)
  "Parse and validate PPS SOURCE into a workbook."
  (when (string-prefix-p "\ufeff" source)
    (setq source (substring source 1)))
  (when (string-match-p "\0" source)
    (error "PPS files may not contain NUL bytes"))
  (when (> (string-bytes source) pps-max-file-bytes)
    (error "PPS file exceeds pps-max-file-bytes (%d)" pps-max-file-bytes))
  (let ((document (pps--safe-read-one source "PPS file")))
    (unless (and (consp document) (pps--symbol-name= (car document) "pps"))
      (error "PPS file must begin with (pps ...)"))
    (let ((plist (cdr document)))
      (pps--validate-plist-keys
       plist '(":version" ":meta" ":active-sheet" ":sheets") "workbook")
      (let* ((version (pps--plist-get-name plist ":version" nil))
             (meta (pps--decode-meta
                    (pps--plist-get-name plist ":meta" nil)))
             (active-name (pps--plist-get-name plist ":active-sheet" nil))
             (sheet-forms (pps--plist-get-name plist ":sheets" nil)))
        (unless (equal version 1)
          (error "Unsupported PPS version: %S" version))
        (unless (and (vectorp sheet-forms) (> (length sheet-forms) 0))
          (error "Workbook needs at least one sheet"))
        (let ((sheets (cl-loop for item across sheet-forms
                               for index from 0
                               collect (pps--decode-sheet item index))))
          (when (/= (length sheets)
                    (length (delete-dups (mapcar #'pps--sheet-name
                                                 (copy-sequence sheets)))))
            (error "Sheet names must be unique"))
          (let ((active (if active-name
                            (cl-position active-name sheets
                                         :key #'pps--sheet-name :test #'string=)
                          0)))
            (unless active
              (error "Active sheet does not exist: %S" active-name))
            (pps--workbook-create :version 1 :meta meta :sheets sheets
                                  :active-sheet active)))))))

(defun pps--encode-cell (cell)
  "Convert internal CELL to its canonical PPS representation."
  (cond
   ((null cell) :blank)
   ((eq cell t) :true)
   ((eq cell pps--false) :false)
   ((or (stringp cell) (numberp cell)) cell)
   ((pps--formula-p cell)
    (list :formula (pps--formula-expr cell)))
   ((pps--date-p cell)
    (list (if (pps--date-datetime-p cell) :datetime :date)
          (pps--date-value cell)))
   (t (error "Cannot serialize PPS cell: %S" cell))))

(defun pps--encode-column (column)
  "Convert COLUMN to its canonical PPS representation."
  (let ((result (list :column
                      :name (pps--column-name column)
                      :type (pps--column-type column))))
    (when (pps--column-width column)
      (setq result (append result (list :width (pps--column-width column)))))
    (when (pps--column-format column)
      (setq result (append result (list :format (pps--column-format column)))))
    result))

(defun pps--encode-sheet (sheet)
  "Convert SHEET to its canonical PPS representation."
  (list
   :sheet
   :name (pps--sheet-name sheet)
   :columns (vconcat (mapcar #'pps--encode-column
                             (pps--sheet-columns sheet)))
   :rows (vconcat
          (mapcar
           (lambda (row)
             (vconcat (mapcar #'pps--encode-cell (append row nil))))
           (pps--sheet-rows sheet)))))

(defun pps--encode-meta (meta)
  "Convert internal META values to their canonical representation."
  (let (result)
    (cl-loop for (key value) on meta by #'cddr
             do (setq result
                      (append result
                              (list key
                                    (cond ((eq value t) :true)
                                          ((eq value pps--false) :false)
                                          ((null value) :blank)
                                          (t value))))))
    result))

(defun pps--document-form (&optional workbook)
  "Return the canonical data form for WORKBOOK."
  (setq workbook (or workbook pps--workbook))
  (let ((active (nth (pps--workbook-active-sheet workbook)
                     (pps--workbook-sheets workbook))))
    (list 'pps
          :version 1
          :meta (pps--encode-meta (pps--workbook-meta workbook))
          :active-sheet (pps--sheet-name active)
          :sheets (vconcat (mapcar #'pps--encode-sheet
                                   (pps--workbook-sheets workbook))))))

(defun pps--serialize (&optional workbook)
  "Serialize WORKBOOK to canonical UTF-8 PPS text."
  (let ((print-circle nil)
        (print-gensym nil)
        (print-length nil)
        (print-level nil)
        (pp-escape-newlines t))
    (concat ";; Pinnacle Point Spreadsheet — PPS 1\n"
            ";; https://github.com/Pinnacle-Point-Development/pps-mode\n"
            (pp-to-string (pps--document-form workbook)))))

(defun pps--default-workbook ()
  "Create a new blank workbook."
  (let ((columns
         (cl-loop for index below 8
                  collect
                  (pps--column-create
                   :name (pps--column-label index) :type :auto)))
        (rows
         (cl-loop repeat 20 collect (make-vector 8 nil))))
    (pps--workbook-create
     :version 1
     :meta (list :title "Untitled")
     :active-sheet 0
     :sheets (list (pps--sheet-create :name "Sheet1"
                                      :columns columns :rows rows)))))

(defun pps--active-sheet ()
  "Return the current sheet."
  (nth (pps--workbook-active-sheet pps--workbook)
       (pps--workbook-sheets pps--workbook)))

(defun pps--column-label (index)
  "Convert zero-based column INDEX to letters."
  (let ((number (1+ index))
        result)
    (while (> number 0)
      (setq number (1- number)
            result (cons (+ ?A (% number 26)) result)
            number (/ number 26)))
    (apply #'string result)))

(defun pps--column-index (letters)
  "Convert column LETTERS to a zero-based index."
  (let ((result 0))
    (dolist (character (string-to-list (upcase letters)))
      (setq result (+ (* result 26) (1+ (- character ?A)))))
    (1- result)))

(defun pps--reference-coordinates (reference)
  "Return zero-based (ROW . COLUMN) for REFERENCE, or nil."
  (let ((name (if (symbolp reference) (symbol-name reference) reference)))
    (when (and (stringp name)
               (string-match
                "\\`\\$?\\([A-Za-z]+\\)\\$?\\([1-9][0-9]*\\)\\'" name))
      (cons (1- (string-to-number (match-string 2 name)))
            (pps--column-index (match-string 1 name))))))

(defun pps--sheet-by-name (name)
  "Return the sheet named NAME, or nil."
  (seq-find (lambda (sheet) (string= (pps--sheet-name sheet) name))
            (pps--workbook-sheets pps--workbook)))

(defun pps--cell-raw (sheet row column)
  "Return SHEET cell at ROW and COLUMN, or a reference error."
  (let ((rows (pps--sheet-rows sheet))
        (columns (pps--sheet-columns sheet)))
    (if (or (< row 0) (< column 0)
            (>= row (length rows)) (>= column (length columns)))
        (pps--error-create :code "#REF!" :detail "Cell is outside the sheet")
      (aref (nth row rows) column))))

(defun pps--error (code &optional detail)
  "Create a formula error with CODE and DETAIL."
  (pps--error-create :code code :detail detail))

(defun pps--cell-value (sheet row column &optional stack)
  "Return calculated value of SHEET cell ROW, COLUMN.
STACK tracks formula dependencies for cycle detection."
  (let* ((key (list (pps--sheet-name sheet) row column))
         (missing (make-symbol "missing"))
         (cached (gethash key pps--formula-cache missing)))
    (cond
     ((not (eq cached missing)) cached)
     ((member key stack)
      (pps--error "#CYCLE!" "Circular formula reference"))
     (t
      (let ((raw (pps--cell-raw sheet row column)) value)
        (setq value
              (if (pps--formula-p raw)
                  (condition-case err
                      (pps--eval-formula (pps--formula-expr raw) sheet
                                         (cons key stack))
                    (arith-error
                     (pps--error "#DIV/0!" (error-message-string err)))
                    (error
                     (pps--error "#VALUE!" (error-message-string err))))
                raw))
        (puthash key value pps--formula-cache)
        value)))))

(defun pps--eval-reference (reference sheet stack)
  "Evaluate cell REFERENCE in SHEET using STACK."
  (let ((coordinates (pps--reference-coordinates reference)))
    (if coordinates
        (pps--cell-value sheet (car coordinates) (cdr coordinates) stack)
      (pps--error "#REF!" (format "Invalid reference: %S" reference)))))

(defun pps--eval-range (arguments sheet stack)
  "Evaluate range ARGUMENTS in SHEET using STACK."
  (let (range-sheet start end)
    (cond
     ((= (length arguments) 2)
      (setq range-sheet sheet
            start (nth 0 arguments)
            end (nth 1 arguments)))
     ((and (= (length arguments) 3) (stringp (car arguments)))
      (setq range-sheet (pps--sheet-by-name (car arguments))
            start (nth 1 arguments)
            end (nth 2 arguments)))
     (t (setq range-sheet nil)))
    (if (not range-sheet)
        (pps--error "#REF!" "Range sheet does not exist")
      (let ((first (pps--reference-coordinates start))
            (last (pps--reference-coordinates end)))
        (if (not (and first last))
            (pps--error "#REF!" "Range needs two cell references")
          (let* ((row-min (min (car first) (car last)))
                 (row-max (max (car first) (car last)))
                 (col-min (min (cdr first) (cdr last)))
                 (col-max (max (cdr first) (cdr last)))
                 (cell-count (* (1+ (- row-max row-min))
                                (1+ (- col-max col-min))))
                 values)
            (cond
             ((or (< row-min 0) (< col-min 0)
                  (>= row-max (length (pps--sheet-rows range-sheet)))
                  (>= col-max (length (pps--sheet-columns range-sheet))))
              (pps--error "#REF!" "Range extends outside the sheet"))
             ((> cell-count pps-max-formula-range-cells)
              (pps--error "#VALUE!" "Range exceeds the configured cell limit"))
             (t
              (cl-loop for row from row-min to row-max do
                       (cl-loop for column from col-min to col-max do
                                (push (pps--cell-value range-sheet row column stack)
                                      values)))
              (nreverse values)))))))))

(defun pps--flatten (values)
  "Flatten range lists in VALUES without flattening strings."
  (apply #'append
         (mapcar (lambda (value) (if (listp value) value (list value))) values)))

(defun pps--first-error (values)
  "Return the first formula error in VALUES, including ranges."
  (seq-find #'pps--error-p (pps--flatten values)))

(defun pps--number-values (values)
  "Return numeric members of VALUES after flattening ranges."
  (seq-filter #'numberp (pps--flatten values)))

(defun pps--formula-truthy-p (value)
  "Return spreadsheet truth for VALUE."
  (not (or (null value) (eq value pps--false) (pps--error-p value))))

(defun pps--formula-string (value)
  "Convert formula VALUE to text."
  (cond
   ((null value) "")
   ((eq value t) "TRUE")
   ((eq value pps--false) "FALSE")
   ((pps--date-p value) (pps--date-value value))
   ((pps--error-p value) (pps--error-code value))
   (t (format "%s" value))))

(defun pps--compare-chain (predicate values)
  "Apply comparison PREDICATE pairwise through VALUES."
  (or (< (length values) 2)
      (cl-loop for left on values
               while (cdr left)
               always (funcall predicate (car left) (cadr left)))))

(defun pps--numeric-operation (operator values)
  "Apply arithmetic OPERATOR to VALUES or return an error."
  (let ((error-value (pps--first-error values))
        (flat (pps--flatten values)))
    (cond
     (error-value error-value)
     ((not (cl-every #'numberp flat))
      (pps--error "#VALUE!" "Arithmetic requires numbers"))
     ((eq operator '+) (apply #'+ flat))
     ((eq operator '*) (apply #'* flat))
     ((eq operator '-)
      (if (= (length flat) 1) (- (car flat))
        (cl-reduce #'- (cdr flat) :initial-value (car flat))))
     ((eq operator '/)
      (if (= (length flat) 1)
          (if (zerop (car flat))
              (pps--error "#DIV/0!" "Division by zero")
            (/ 1.0 (car flat)))
        (if (seq-some #'zerop (cdr flat))
            (pps--error "#DIV/0!" "Division by zero")
          (cl-reduce #'/ (cdr flat) :initial-value (float (car flat)))))))))

(defun pps--eval-formula (form sheet stack)
  "Evaluate validated formula FORM in SHEET using dependency STACK."
  (cond
   ((or (numberp form) (stringp form)) form)
   ((symbolp form)
    (let ((name (downcase (symbol-name form))))
      (cond
       ((pps--cell-reference-p form) (pps--eval-reference form sheet stack))
       ((string= name "true") t)
       ((string= name "false") pps--false)
       ((string= name "blank") nil)
       (t (pps--error "#NAME?" name)))))
   ((consp form)
    (let* ((operator (intern (downcase (symbol-name (car form)))))
           (forms (cdr form)))
      (cond
       ((eq operator 'if)
        (if (/= (length forms) 3)
            (pps--error "#VALUE!" "if takes three arguments")
          (let ((condition (pps--eval-formula (car forms) sheet stack)))
            (if (pps--error-p condition) condition
              (pps--eval-formula (if (pps--formula-truthy-p condition)
                                     (nth 1 forms) (nth 2 forms))
                                 sheet stack)))))
       ((eq operator 'and)
        (let ((result t) error-value)
          (while (and forms result (not error-value))
            (let ((value (pps--eval-formula (pop forms) sheet stack)))
              (if (pps--error-p value) (setq error-value value)
                (setq result (pps--formula-truthy-p value)))))
          (or error-value (if result t pps--false))))
       ((eq operator 'or)
        (let ((result nil) error-value)
          (while (and forms (not result) (not error-value))
            (let ((value (pps--eval-formula (pop forms) sheet stack)))
              (if (pps--error-p value) (setq error-value value)
                (setq result (pps--formula-truthy-p value)))))
          (or error-value (if result t pps--false))))
       ((eq operator 'cell)
        (cond
         ((= (length forms) 1)
          (pps--eval-reference (car forms) sheet stack))
         ((and (= (length forms) 2) (stringp (car forms)))
          (let ((target (pps--sheet-by-name (car forms))))
            (if target (pps--eval-reference (cadr forms) target stack)
              (pps--error "#REF!" "Sheet does not exist"))))
         (t (pps--error "#VALUE!" "cell takes REF or SHEET REF"))))
       ((eq operator 'range) (pps--eval-range forms sheet stack))
       ((eq operator 'ref-error)
        (pps--error "#REF!" "Reference target was deleted"))
       (t
        (let* ((values (mapcar (lambda (item)
                                 (pps--eval-formula item sheet stack)) forms))
               (error-value (pps--first-error values))
               (flat (pps--flatten values))
               (numbers (pps--number-values values)))
          (cond
           ((memq operator '(+ - * /))
            (pps--numeric-operation operator values))
           (error-value error-value)
           ((eq operator 'sum) (apply #'+ numbers))
           ((eq operator 'average)
            (if numbers (/ (apply #'+ numbers) (float (length numbers)))
              (pps--error "#DIV/0!" "Average of no numbers")))
           ((eq operator 'min)
            (if numbers (apply #'min numbers)
              (pps--error "#VALUE!" "Minimum of no numbers")))
           ((eq operator 'max)
            (if numbers (apply #'max numbers)
              (pps--error "#VALUE!" "Maximum of no numbers")))
           ((eq operator 'count) (length numbers))
           ((eq operator 'counta) (length (seq-remove #'null flat)))
           ((eq operator '=)
            (if (pps--compare-chain #'equal flat) t pps--false))
           ((eq operator '/=)
            (if (not (pps--compare-chain #'equal flat)) t pps--false))
           ((memq operator '(< <= > >=))
            (if (not (or (cl-every #'numberp flat)
                         (cl-every #'stringp flat)))
                (pps--error "#VALUE!" "Comparison types differ")
              (let ((predicate
                     (if (numberp (car flat))
                         operator
                       (cond
                        ((eq operator '<) #'string<)
                        ((eq operator '<=)
                         (lambda (left right) (not (string< right left))))
                        ((eq operator '>)
                         (lambda (left right) (string< right left)))
                        (t
                         (lambda (left right) (not (string< left right))))))))
                (if (pps--compare-chain predicate flat) t pps--false))))
           ((eq operator 'not)
            (if (= (length flat) 1)
                (if (pps--formula-truthy-p (car flat)) pps--false t)
              (pps--error "#VALUE!" "not takes one argument")))
           ((eq operator 'concat)
            (mapconcat #'pps--formula-string flat ""))
           ((eq operator 'len)
            (if (= (length flat) 1)
                (length (pps--formula-string (car flat)))
              (pps--error "#VALUE!" "len takes one argument")))
           ((memq operator '(upper lower))
            (if (= (length flat) 1)
                (funcall (if (eq operator 'upper) #'upcase #'downcase)
                         (pps--formula-string (car flat)))
              (pps--error "#VALUE!" "Case conversion takes one argument")))
           ((eq operator 'abs)
            (if (and (= (length flat) 1) (numberp (car flat)))
                (abs (car flat))
              (pps--error "#VALUE!" "abs takes one number")))
           ((memq operator '(floor ceiling truncate sqrt))
            (if (and (= (length flat) 1) (numberp (car flat)))
                (funcall operator (car flat))
              (pps--error "#VALUE!" "Numeric function takes one number")))
           ((eq operator 'round)
            (if (and (<= 1 (length flat) 2) (cl-every #'numberp flat)
                     (or (= (length flat) 1)
                         (and (integerp (cadr flat))
                              (<= (abs (cadr flat)) 100))))
                (if (= (length flat) 1)
                    (round (car flat))
                  (let ((factor (expt 10 (cadr flat))))
                    (/ (float (round (* (car flat) factor))) factor)))
              (pps--error "#VALUE!" "round takes NUMBER and optional DIGITS")))
           ((eq operator 'mod)
            (if (and (= (length flat) 2) (cl-every #'numberp flat))
                (if (zerop (cadr flat))
                    (pps--error "#DIV/0!" "Modulo by zero")
                  (mod (car flat) (cadr flat)))
              (pps--error "#VALUE!" "mod takes two numbers")))
           ((eq operator 'expt)
            (if (and (= (length flat) 2) (cl-every #'numberp flat)
                     (<= (abs (cadr flat)) 1000))
                (expt (car flat) (cadr flat))
              (pps--error "#VALUE!" "expt takes two numbers and a bounded exponent")))
           (t (pps--error "#NAME?" (symbol-name operator)))))))))
   (t (pps--error "#VALUE!" "Unsupported formula value"))))

(defun pps--display-value (value &optional column)
  "Return display text for calculated VALUE in COLUMN."
  (let ((format-spec (and column (pps--column-format column))))
    (cond
     ((null value) "")
     ((pps--error-p value) (pps--error-code value))
     ((pps--date-p value) (pps--date-value value))
     ((eq value t)
      (if (and format-spec (string-match "\\`\\([^|]+\\)|\\([^|]+\\)\\'"
                                         format-spec))
          (match-string 1 format-spec)
        "TRUE"))
     ((eq value pps--false)
      (if (and format-spec (string-match "\\`\\([^|]+\\)|\\([^|]+\\)\\'"
                                         format-spec))
          (match-string 2 format-spec)
        "FALSE"))
     ((and (numberp value) format-spec
           (string-match-p
            "\\`%[-+ #0]*[0-9]\\{0,3\\}\\(?:\\.[0-9]\\{1,2\\}\\)?[defg]\\'"
            format-spec))
      (condition-case nil (format format-spec value)
        (error (format "%s" value))))
     ((floatp value) (format "%.12g" value))
     (t (format "%s" value)))))

(defun pps--sanitize-display (text)
  "Make TEXT safe for one grid line."
  (setq text (replace-regexp-in-string "\t" "→" text t t))
  (setq text (replace-regexp-in-string "[\n\r]+" "↵" text t t))
  (replace-regexp-in-string "[[:cntrl:]]" "�" text t t))

(defun pps--cell-display (sheet row column)
  "Return display text for SHEET cell ROW, COLUMN."
  (let* ((column-object (nth column (pps--sheet-columns sheet)))
         (value (pps--cell-value sheet row column nil)))
    (pps--sanitize-display (pps--display-value value column-object))))

(defun pps--cell-source-string (cell)
  "Return editable source text for internal CELL."
  (cond
   ((null cell) "")
   ((eq cell t) "TRUE")
   ((eq cell pps--false) "FALSE")
   ((pps--formula-p cell)
    (concat "=" (prin1-to-string (pps--formula-expr cell))))
   ((pps--date-p cell) (pps--date-value cell))
   (t (format "%s" cell))))

(defun pps--title ()
  "Return the workbook title."
  (or (plist-get (pps--workbook-meta pps--workbook) :title)
      (and buffer-file-name (file-name-base buffer-file-name))
      "Pinnacle Point Spreadsheet"))

(defun pps--selection-bounds ()
  "Return selected rectangle as (ROW-MIN ROW-MAX COL-MIN COL-MAX)."
  (let* ((anchor (or pps--mark-cell (cons pps--row pps--column)))
         (anchor-row (car anchor))
         (anchor-column (cdr anchor)))
    (list (min anchor-row pps--row) (max anchor-row pps--row)
          (min anchor-column pps--column) (max anchor-column pps--column))))

(defun pps--cell-selected-p (row column)
  "Return non-nil when ROW, COLUMN is inside the marked rectangle."
  (when pps--mark-cell
    (let ((bounds (pps--selection-bounds)))
      (and (<= (nth 0 bounds) row (nth 1 bounds))
           (<= (nth 2 bounds) column (nth 3 bounds))))))

(defun pps--row-matches-filter-p (sheet row)
  "Return non-nil when SHEET ROW passes the active filter."
  (or (null pps--filter)
      (let ((case-fold-search t)
            (columns (if (integerp pps--filter-column)
                         (list pps--filter-column)
                       (number-sequence 0
                                        (1- (length (pps--sheet-columns sheet)))))))
        (seq-some
         (lambda (column)
           (string-match-p pps--filter (pps--cell-display sheet row column)))
         columns))))

(defun pps--compute-visible-indices (sheet)
  "Return row indexes of SHEET that pass the current filter."
  (cl-loop for _row in (pps--sheet-rows sheet)
           for index from 0
           when (pps--row-matches-filter-p sheet index)
           collect index))

(defun pps--column-widths (sheet row-indices)
  "Return display widths for SHEET, scanning ROW-INDICES."
  (let ((result nil)
        (sample (seq-take row-indices pps-width-scan-limit)))
    (cl-loop for column in (pps--sheet-columns sheet)
             for index from 0
             do (let ((width
                       (or (pps--column-width column)
                           (max pps-default-column-width
                                (string-width (pps--column-name column))))))
                  (unless (pps--column-width column)
                    (dolist (row sample)
                      (setq width (max width
                                       (string-width
                                        (pps--cell-display sheet row index)))))
                    (setq width (min width pps-max-column-width)))
                  (push (max pps-min-column-width width) result)))
    (vconcat (nreverse result))))

(defun pps--fit-text (text width right-align)
  "Fit TEXT into WIDTH columns and optionally RIGHT-ALIGN it."
  (let* ((ellipsis (if pps-use-unicode-borders "…" ">"))
         (fitted (if (> (string-width text) width)
                     (truncate-string-to-width text width nil nil ellipsis)
                   text))
         (padding (max 0 (- width (string-width fitted)))))
    (if right-align
        (concat (make-string padding ?\s) fitted)
      (concat fitted (make-string padding ?\s)))))

(defun pps--grid-characters ()
  "Return (VERTICAL HORIZONTAL CROSS) for the configured grid."
  (if pps-use-unicode-borders '("│" "─" "┼") '("|" "-" "+")))

(defun pps--insert-cell (sheet row column width)
  "Insert one displayed SHEET cell at ROW, COLUMN with WIDTH."
  (let* ((raw (pps--cell-raw sheet row column))
         (value (pps--cell-value sheet row column nil))
         (text (pps--cell-display sheet row column))
         (right (or (numberp value)
                    (memq (pps--column-type
                           (nth column (pps--sheet-columns sheet)))
                          '(:integer :number))))
         (start (point))
         (face (cond
                ((pps--error-p value) 'pps-error-face)
                ((pps--cell-selected-p row column) 'pps-selection-face)
                (t 'pps-default-face))))
    (insert (propertize (pps--fit-text text width right)
                        'pps-row row
                        'pps-column column
                        'face face
                        'mouse-face 'highlight
                        'help-echo (pps--cell-source-string raw)))
    (puthash (cons row column) (cons start (point)) pps--cell-positions)))

(defun pps--banner-text (sheet visible-count total-count)
  "Return banner for SHEET with VISIBLE-COUNT and TOTAL-COUNT rows."
  (format " PINNACLE POINT SPREADSHEET  ::  %s  ::  %s  [%d/%d rows]"
          (pps--title) (pps--sheet-name sheet) visible-count total-count))

(defun pps--render ()
  "Render the active spreadsheet page."
  (let* ((modified (buffer-modified-p))
         (sheet (pps--active-sheet))
         (rows (pps--sheet-rows sheet))
         (columns (pps--sheet-columns sheet))
         (column-count (length columns))
         (inhibit-read-only t)
         (inhibit-modification-hooks t)
         (buffer-undo-list t)
         (characters (pps--grid-characters))
         (vertical (nth 0 characters))
         (horizontal (nth 1 characters))
         (cross (nth 2 characters)))
    (setq pps--loading t
          pps--formula-cache (make-hash-table :test #'equal)
          pps--cell-positions (make-hash-table :test #'equal)
          pps--visible-indices (pps--compute-visible-indices sheet))
    (when (> column-count 0)
      (setq pps--column (max 0 (min pps--column (1- column-count)))))
    (when pps--visible-indices
      (unless (memq pps--row pps--visible-indices)
        (setq pps--row (car pps--visible-indices))))
    (let* ((selected-position (or (cl-position pps--row pps--visible-indices) 0))
           (page-size (max 1 pps-page-size))
           (page-start (* (/ selected-position page-size) page-size))
           (page (seq-subseq pps--visible-indices page-start
                             (min (length pps--visible-indices)
                                  (+ page-start page-size))))
           (widths (pps--column-widths sheet pps--visible-indices))
           (row-number-width (max 3 (length (number-to-string
                                             (max 1 (length rows))))))
           (separator-parts
            (cl-loop for width across widths
                     collect (make-string width (string-to-char horizontal)))))
      (erase-buffer)
      (insert (propertize
               (pps--banner-text sheet (length pps--visible-indices)
                                 (length rows))
               'face 'pps-banner-face)
              "\n")
      (insert (propertize (make-string row-number-width ?\s)
                          'face 'pps-header-face)
              (propertize (concat " " vertical " ") 'face 'pps-header-face))
      (cl-loop for column in columns
               for index from 0
               for width across widths
               do (insert
                   (propertize
                    (pps--fit-text
                     (format "%s %s" (pps--column-label index)
                             (pps--column-name column))
                     width nil)
                    'face 'pps-header-face
                    'help-echo (format "Column %s, type %s"
                                       (pps--column-label index)
                                       (pps--column-type column))))
               unless (= index (1- column-count))
               do (insert (propertize (concat " " vertical " ")
                                      'face 'pps-header-face)))
      (insert "\n")
      (insert (make-string row-number-width (string-to-char horizontal))
              horizontal cross horizontal
              (mapconcat #'identity separator-parts
                         (concat horizontal cross horizontal))
              "\n")
      (if page
          (dolist (row page)
            (insert (propertize (format (format "%%%dd" row-number-width)
                                        (1+ row))
                                'face 'pps-default-face
                                'pps-row row)
                    " " vertical " ")
            (cl-loop for column-index from 0 below column-count
                     for width across widths
                     do (pps--insert-cell sheet row column-index width)
                     unless (= column-index (1- column-count))
                     do (insert " " vertical " "))
            (insert "\n"))
        (insert (propertize
                 (if pps--filter
                     " No rows match the filter.  Press C-c C-f to clear it.\n"
                   " Empty sheet.  Press o to insert a row.\n")
                 'face 'pps-default-face)))
      (when (and (> (length pps--visible-indices) page-size)
                 (< (+ page-start page-size) (length pps--visible-indices)))
        (insert (propertize
                 (format " … %d more matching rows; navigation loads the next page …\n"
                         (- (length pps--visible-indices)
                            (+ page-start page-size)))
                 'face 'pps-default-face))))
    (set-buffer-modified-p modified)
    (setq pps--loading nil)
    (pps--highlight-current)
    (force-mode-line-update)))

(defun pps--highlight-current ()
  "Move the current-cell overlay and point to the active cell."
  (let ((range (gethash (cons pps--row pps--column) pps--cell-positions)))
    (when range
      (unless (overlayp pps--selection-overlay)
        (setq pps--selection-overlay (make-overlay (car range) (cdr range)))
        (overlay-put pps--selection-overlay 'priority 20)
        (overlay-put pps--selection-overlay 'face 'pps-current-cell-face))
      (move-overlay pps--selection-overlay (car range) (cdr range))
      (goto-char (car range)))))

(defun pps--mode-line-status ()
  "Return PPS status text for the mode line."
  (let* ((sheet (pps--active-sheet))
         (raw (pps--cell-raw sheet pps--row pps--column))
         (address (format "%s%d" (pps--column-label pps--column)
                          (1+ pps--row))))
    (format "  [%s!%s] %s%s"
            (pps--sheet-name sheet) address
            (pps--cell-source-string raw)
            (if pps--filter "  FILTER" ""))))

(defun pps--select (row column &optional keep-page)
  "Select ROW and COLUMN, rendering if needed.
KEEP-PAGE is reserved for callers that already rendered."
  (let* ((sheet (pps--active-sheet))
         (column-max (max 0 (1- (length (pps--sheet-columns sheet)))))
         (target-row (if pps--visible-indices
                         (or (and (memq row pps--visible-indices) row)
                             (car pps--visible-indices))
                       0)))
    (setq pps--row target-row
          pps--column (max 0 (min column column-max)))
    (if (and (not keep-page)
             (gethash (cons pps--row pps--column) pps--cell-positions)
             (not pps--mark-cell))
        (pps--highlight-current)
      (pps--render))
    (force-mode-line-update)))

(defun pps--move-row (delta)
  "Move DELTA filtered rows."
  (interactive "p")
  (if (null pps--visible-indices)
      (user-error "No visible rows")
    (let* ((position (or (cl-position pps--row pps--visible-indices) 0))
           (target (max 0 (min (+ position delta)
                               (1- (length pps--visible-indices))))))
      (pps--select (nth target pps--visible-indices) pps--column))))

(defun pps-next-row (&optional count)
  "Move down COUNT rows."
  (interactive "p")
  (pps--move-row (or count 1)))

(defun pps-previous-row (&optional count)
  "Move up COUNT rows."
  (interactive "p")
  (pps--move-row (- (or count 1))))

(defun pps-next-column (&optional count)
  "Move right COUNT columns."
  (interactive "p")
  (pps--select pps--row (+ pps--column (or count 1))))

(defun pps-previous-column (&optional count)
  "Move left COUNT columns."
  (interactive "p")
  (pps--select pps--row (- pps--column (or count 1))))

(defun pps-next-cell (&optional count)
  "Move forward COUNT cells, wrapping between rows."
  (interactive "p")
  (dotimes (_ (or count 1))
    (let* ((sheet (pps--active-sheet))
           (last-column (1- (length (pps--sheet-columns sheet)))))
      (if (< pps--column last-column)
          (pps--select pps--row (1+ pps--column))
        (setq pps--column 0)
        (pps-next-row 1)))))

(defun pps-previous-cell (&optional count)
  "Move backward COUNT cells, wrapping between rows."
  (interactive "p")
  (dotimes (_ (or count 1))
    (if (> pps--column 0)
        (pps--select pps--row (1- pps--column))
      (setq pps--column (1- (length (pps--sheet-columns (pps--active-sheet)))))
      (pps-previous-row 1))))

(defun pps-first-column ()
  "Move to the first column."
  (interactive)
  (pps--select pps--row 0))

(defun pps-last-column ()
  "Move to the last column."
  (interactive)
  (pps--select pps--row
               (1- (length (pps--sheet-columns (pps--active-sheet))))))

(defun pps-first-row ()
  "Move to the first visible row."
  (interactive)
  (if pps--visible-indices (pps--select (car pps--visible-indices) pps--column)
    (user-error "No visible rows")))

(defun pps-last-row ()
  "Move to the last visible row."
  (interactive)
  (if pps--visible-indices (pps--select (car (last pps--visible-indices)) pps--column)
    (user-error "No visible rows")))

(defun pps-page-down ()
  "Move down one rendered page."
  (interactive)
  (pps--move-row pps-page-size))

(defun pps-page-up ()
  "Move up one rendered page."
  (interactive)
  (pps--move-row (- pps-page-size)))

(defun pps-toggle-mark ()
  "Start or clear a rectangular cell selection."
  (interactive)
  (setq pps--mark-cell (unless pps--mark-cell
                         (cons pps--row pps--column)))
  (pps--render)
  (message (if pps--mark-cell
               "Selection started at %s%d"
             "Selection cleared")
           (pps--column-label pps--column) (1+ pps--row)))

(defun pps-quit-selection ()
  "Clear the rectangular selection or active filter."
  (interactive)
  (cond
   (pps--mark-cell (setq pps--mark-cell nil) (pps--render))
   (pps--filter (pps-clear-filter))
   (t (keyboard-quit))))

(defun pps--post-command ()
  "Track a cell reached by ordinary point or mouse movement."
  (unless pps--loading
    (let ((row (get-text-property (point) 'pps-row))
          (column (get-text-property (point) 'pps-column)))
      (when (and (integerp row) (integerp column)
                 (not (and (= row pps--row) (= column pps--column))))
        (setq pps--row row pps--column column)
        (pps--highlight-current)
        (force-mode-line-update)))))

(defun pps-mouse-select (event)
  "Select the spreadsheet cell clicked in mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (let ((row (get-text-property (point) 'pps-row))
        (column (get-text-property (point) 'pps-column)))
    (when (and (integerp row) (integerp column))
      (pps--select row column))))

(defun pps--capture-state ()
  "Capture a deep copy of the current workbook and cursor."
  (pps--state-create :workbook (copy-tree pps--workbook t)
                     :row pps--row :column pps--column))

(defun pps--record-change ()
  "Record state before one logical workbook change."
  (push (pps--capture-state) pps--undo-stack)
  (when (> (length pps--undo-stack) pps-history-limit)
    (setcdr (nthcdr (1- pps-history-limit) pps--undo-stack) nil))
  (setq pps--redo-stack nil))

(defun pps--finish-change ()
  "Mark the workbook changed and render it."
  (setq pps--formula-cache (make-hash-table :test #'equal))
  (set-buffer-modified-p t)
  (pps--render))

(defun pps--restore-state (state)
  "Restore workbook STATE and refresh the buffer."
  (setq pps--workbook (pps--state-workbook state)
        pps--row (pps--state-row state)
        pps--column (pps--state-column state)
        pps--mark-cell nil
        pps--filter nil
        pps--filter-column nil)
  (pps--render)
  (set-buffer-modified-p
   (not (and pps--saved-text
             (string= (pps--serialize) pps--saved-text)))))

(defun pps-undo ()
  "Undo one logical spreadsheet change."
  (interactive)
  (unless pps--undo-stack
    (user-error "No spreadsheet change to undo"))
  (push (pps--capture-state) pps--redo-stack)
  (pps--restore-state (pop pps--undo-stack))
  (message "Undid spreadsheet change"))

(defun pps-redo ()
  "Redo one logical spreadsheet change."
  (interactive)
  (unless pps--redo-stack
    (user-error "No spreadsheet change to redo"))
  (push (pps--capture-state) pps--undo-stack)
  (pps--restore-state (pop pps--redo-stack))
  (message "Redid spreadsheet change"))

(defun pps--ensure-row (sheet row)
  "Ensure SHEET contains ROW, appending blank rows if needed."
  (let ((column-count (length (pps--sheet-columns sheet))))
    (while (<= (length (pps--sheet-rows sheet)) row)
      (setf (pps--sheet-rows sheet)
            (append (pps--sheet-rows sheet)
                    (list (make-vector column-count nil)))))))

(defun pps--set-cell-internal (sheet row column value)
  "Set SHEET cell ROW, COLUMN to internal VALUE."
  (pps--ensure-row sheet row)
  (aset (nth row (pps--sheet-rows sheet)) column value))

(defun pps--number-text-p (text integer-only)
  "Return non-nil when TEXT is a number, optionally INTEGER-ONLY."
  (string-match-p
   (if integer-only
       "\\`[-+]?[0-9]+\\'"
     "\\`[-+]?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)\\(?:[eE][-+]?[0-9]+\\)?\\'")
   text))

(defun pps--parse-entry (input column)
  "Convert minibuffer INPUT according to COLUMN."
  (let ((type (pps--column-type column)))
    (cond
     ((string-empty-p input) nil)
     ((string-prefix-p "'" input) (substring input 1))
     ((string-prefix-p "=" input)
      (when (= (length input) 1)
        (user-error "A formula needs an expression after ="))
      (pps--formula-create
       :expr (pps--validate-formula
              (pps--safe-read-one (substring input 1) "formula"))))
     ((eq type :text) input)
     ((eq type :integer)
      (unless (pps--number-text-p input t)
        (user-error "Column requires an integer"))
      (string-to-number input))
     ((eq type :number)
      (unless (pps--number-text-p input nil)
        (user-error "Column requires a number"))
      (string-to-number input))
     ((eq type :boolean)
      (cond
       ((member (downcase input) '("true" "yes" "on" "1")) t)
       ((member (downcase input) '("false" "no" "off" "0")) pps--false)
       (t (user-error "Column requires TRUE/FALSE, ON/OFF, YES/NO, or 1/0"))))
     ((eq type :date)
      (unless (pps--date-string-p input nil)
        (user-error "Column requires a YYYY-MM-DD date"))
      (pps--date-create :value input :datetime-p nil))
     ((eq type :datetime)
      (unless (pps--date-string-p input t)
        (user-error "Column requires an RFC 3339 date-time"))
      (pps--date-create :value input :datetime-p t))
     ((member (downcase input) '("true" "false"))
      (if (string-equal-ignore-case input "true") t pps--false))
     ((pps--number-text-p input nil) (string-to-number input))
     (t input))))

(defun pps-edit-cell ()
  "Edit the active cell in the minibuffer."
  (interactive)
  (let* ((sheet (pps--active-sheet))
         (column-object (nth pps--column (pps--sheet-columns sheet)))
         (raw (pps--cell-raw sheet pps--row pps--column))
         (initial (if (pps--error-p raw) "" (pps--cell-source-string raw)))
         (address (format "%s%d" (pps--column-label pps--column)
                          (1+ pps--row)))
         (input (read-string (format "%s = " address) initial)))
    (pps--record-change)
    (pps--set-cell-internal sheet pps--row pps--column
                            (pps--parse-entry input column-object))
    (pps--finish-change)))

(defun pps-enter-formula ()
  "Enter a Lisp-style formula in the active cell."
  (interactive)
  (let* ((sheet (pps--active-sheet))
         (raw (pps--cell-raw sheet pps--row pps--column))
         (initial (if (pps--formula-p raw)
                      (prin1-to-string (pps--formula-expr raw)) ""))
         (input (read-string "Formula (without =): " initial)))
    (pps--record-change)
    (pps--set-cell-internal
     sheet pps--row pps--column
     (pps--formula-create
      :expr (pps--validate-formula (pps--safe-read-one input "formula"))))
    (pps--finish-change)))

(defun pps-set-cell (row column value)
  "Set zero-based ROW and COLUMN to VALUE in the active sheet.
VALUE uses the internal PPS representation."
  (unless (and (integerp row) (>= row 0)
               (integerp column) (>= column 0)
               (< column (length (pps--sheet-columns (pps--active-sheet)))))
    (error "Invalid PPS cell coordinates"))
  (pps--record-change)
  (pps--set-cell-internal (pps--active-sheet) row column value)
  (setq pps--row row pps--column column)
  (pps--finish-change))

(defun pps-clear-cells ()
  "Clear the selected rectangle, or the active cell."
  (interactive)
  (let* ((sheet (pps--active-sheet))
         (bounds (pps--selection-bounds)))
    (pps--record-change)
    (cl-loop for row from (nth 0 bounds) to (nth 1 bounds) do
             (cl-loop for column from (nth 2 bounds) to (nth 3 bounds) do
                      (pps--set-cell-internal sheet row column nil)))
    (setq pps--mark-cell nil)
    (pps--finish-change)))

(defun pps-fill-selection ()
  "Fill the selected rectangle with one entered value."
  (interactive)
  (let* ((sheet (pps--active-sheet))
         (bounds (pps--selection-bounds))
         (column-object (nth pps--column (pps--sheet-columns sheet)))
         (input (read-string "Fill with: "))
         (value (pps--parse-entry input column-object)))
    (pps--record-change)
    (cl-loop for row from (nth 0 bounds) to (nth 1 bounds) do
             (cl-loop for column from (nth 2 bounds) to (nth 3 bounds) do
                      (pps--set-cell-internal sheet row column
                                              (copy-tree value t))))
    (setq pps--mark-cell nil)
    (pps--finish-change)))

(defun pps-insert-row-above (&optional count)
  "Insert COUNT blank rows above the active row."
  (interactive "p")
  (setq count (max 1 (or count 1)))
  (let* ((sheet (pps--active-sheet))
         (rows (pps--sheet-rows sheet))
         (column-count (length (pps--sheet-columns sheet)))
         (new (cl-loop repeat count collect (make-vector column-count nil))))
    (pps--record-change)
    (pps--adjust-workbook-references
     (pps--sheet-name sheet) 'row pps--row count nil)
    (setf (pps--sheet-rows sheet)
          (append (seq-take rows pps--row) new (seq-drop rows pps--row)))
    (setq pps--mark-cell nil)
    (pps--finish-change)))

(defun pps-insert-row-below (&optional count)
  "Insert COUNT blank rows below the active row."
  (interactive "p")
  (setq count (max 1 (or count 1)))
  (let* ((sheet (pps--active-sheet))
         (rows (pps--sheet-rows sheet))
         (index (1+ pps--row))
         (column-count (length (pps--sheet-columns sheet)))
         (new (cl-loop repeat count collect (make-vector column-count nil))))
    (pps--record-change)
    (pps--adjust-workbook-references
     (pps--sheet-name sheet) 'row index count nil)
    (setf (pps--sheet-rows sheet)
          (append (seq-take rows index) new (seq-drop rows index)))
    (setq pps--row index pps--mark-cell nil)
    (pps--finish-change)))

(defun pps-delete-rows ()
  "Delete rows covered by the current selection."
  (interactive)
  (let* ((sheet (pps--active-sheet))
         (rows (pps--sheet-rows sheet))
         (bounds (pps--selection-bounds))
         (first (nth 0 bounds))
         (last (nth 1 bounds)))
    (pps--record-change)
    (pps--adjust-workbook-references
     (pps--sheet-name sheet) 'row first (1+ (- last first)) t)
    (setf (pps--sheet-rows sheet)
          (append (seq-take rows first) (seq-drop rows (1+ last))))
    (when (null (pps--sheet-rows sheet))
      (setf (pps--sheet-rows sheet)
            (list (make-vector (length (pps--sheet-columns sheet)) nil))))
    (setq pps--row (min first (1- (length (pps--sheet-rows sheet))))
          pps--mark-cell nil)
    (pps--finish-change)))

(defun pps--read-column-type (&optional initial)
  "Read a column type, defaulting to INITIAL."
  (intern (completing-read "Column type: "
                           (mapcar #'symbol-name pps--cell-types)
                           nil t nil nil (symbol-name (or initial :auto)))))

(defun pps--insert-column-at (index name type)
  "Insert at INDEX a column named NAME with TYPE."
  (let* ((sheet (pps--active-sheet))
         (column (pps--column-create :name name :type type)))
    (when (string-empty-p name) (user-error "Column name may not be empty"))
    (when (>= (length (pps--sheet-columns sheet)) pps-max-columns)
      (user-error "Sheet already has pps-max-columns"))
    (pps--record-change)
    (pps--adjust-workbook-references
     (pps--sheet-name sheet) 'column index 1 nil)
    (setf (pps--sheet-columns sheet)
          (append (seq-take (pps--sheet-columns sheet) index)
                  (list column)
                  (seq-drop (pps--sheet-columns sheet) index)))
    (setf (pps--sheet-rows sheet)
          (mapcar
           (lambda (row)
             (let ((replacement (make-vector (1+ (length row)) nil)))
               (cl-loop for old from 0 below (length row)
                        for new = (if (< old index) old (1+ old))
                        do (aset replacement new (aref row old)))
               replacement))
           (pps--sheet-rows sheet)))
    (setq pps--column index pps--mark-cell nil)
    (pps--finish-change)))

(defun pps-insert-column-before ()
  "Insert a column before the active column."
  (interactive)
  (let ((name (read-string "Column name: "
                           (pps--column-label pps--column)))
        (type (pps--read-column-type :auto)))
    (pps--insert-column-at pps--column name type)))

(defun pps-insert-column-after ()
  "Insert a column after the active column."
  (interactive)
  (let* ((index (1+ pps--column))
         (name (read-string "Column name: " (pps--column-label index)))
         (type (pps--read-column-type :auto)))
    (pps--insert-column-at index name type)))

(defun pps-delete-columns ()
  "Delete columns covered by the current selection."
  (interactive)
  (let* ((sheet (pps--active-sheet))
         (bounds (pps--selection-bounds))
         (first (nth 2 bounds))
         (last (nth 3 bounds))
         (columns (pps--sheet-columns sheet)))
    (when (= (- (1+ last) first) (length columns))
      (user-error "A sheet must retain at least one column"))
    (pps--record-change)
    (pps--adjust-workbook-references
     (pps--sheet-name sheet) 'column first (1+ (- last first)) t)
    (setf (pps--sheet-columns sheet)
          (append (seq-take columns first) (seq-drop columns (1+ last))))
    (setf (pps--sheet-rows sheet)
          (mapcar
           (lambda (row)
             (vconcat (append (seq-take (append row nil) first)
                              (seq-drop (append row nil) (1+ last)))))
           (pps--sheet-rows sheet)))
    (setq pps--column (min first (1- (length (pps--sheet-columns sheet))))
          pps--mark-cell nil)
    (pps--finish-change)))

(defun pps-rename-column ()
  "Rename the active column."
  (interactive)
  (let* ((column (nth pps--column
                      (pps--sheet-columns (pps--active-sheet))))
         (name (read-string "New column name: " (pps--column-name column))))
    (when (string-empty-p name) (user-error "Column name may not be empty"))
    (pps--record-change)
    (setf (pps--column-name column) name)
    (pps--finish-change)))

(defun pps-set-column-type ()
  "Set the active column's declared type."
  (interactive)
  (let* ((column (nth pps--column
                      (pps--sheet-columns (pps--active-sheet))))
         (type (pps--read-column-type (pps--column-type column))))
    (pps--record-change)
    (setf (pps--column-type column) type)
    (pps--finish-change)))

(defun pps-set-column-width (width)
  "Set the active column display WIDTH; zero selects automatic width."
  (interactive
   (list (read-number "Width (0 for automatic): "
                      (or (pps--column-width
                           (nth pps--column
                                (pps--sheet-columns (pps--active-sheet))))
                          0))))
  (unless (or (= width 0) (<= pps-min-column-width width 200))
    (user-error "Width must be 0 or between %d and 200" pps-min-column-width))
  (pps--record-change)
  (setf (pps--column-width
         (nth pps--column (pps--sheet-columns (pps--active-sheet))))
        (unless (= width 0) width))
  (pps--finish-change))

(defun pps-recalculate ()
  "Clear formula caches and recalculate the visible grid."
  (interactive)
  (setq pps--formula-cache (make-hash-table :test #'equal))
  (pps--render)
  (message "Spreadsheet recalculated"))

(defun pps--sort-key-class (value)
  "Return a sorting class for VALUE."
  (cond ((pps--error-p value) 3)
        ((null value) 4)
        ((numberp value) 0)
        ((pps--date-p value) 1)
        (t 2)))

(defun pps--value-less-p (left right)
  "Return non-nil when spreadsheet value LEFT sorts before RIGHT."
  (let ((left-class (pps--sort-key-class left))
        (right-class (pps--sort-key-class right)))
    (if (/= left-class right-class)
        (< left-class right-class)
      (cond
       ((numberp left) (< left right))
       ((pps--date-p left)
        (string< (pps--date-value left) (pps--date-value right)))
       (t (string-lessp (pps--formula-string left)
                        (pps--formula-string right)))))))

(defun pps-sort-column (descending)
  "Sort all rows by the active column.
With DESCENDING non-nil, reverse the ordering."
  (interactive
   (list (string= (completing-read "Direction: " '("ascending" "descending")
                                   nil t nil nil "ascending")
                  "descending")))
  (let* ((sheet (pps--active-sheet))
         (column pps--column)
         (decorated
          (cl-loop for row in (pps--sheet-rows sheet)
                   for index from 0
                   collect (list (pps--cell-value sheet index column nil) row))))
    (pps--record-change)
    (setq decorated
          (cl-stable-sort
           decorated
           (lambda (left right)
             (if descending
                 (pps--value-less-p (car right) (car left))
               (pps--value-less-p (car left) (car right))))))
    (setf (pps--sheet-rows sheet) (mapcar #'cadr decorated))
    (setq pps--row 0 pps--mark-cell nil)
    (pps--finish-change)))

(defun pps-set-filter (regexp &optional current-column)
  "Show rows matching REGEXP.
When CURRENT-COLUMN is non-nil, inspect only the active column."
  (interactive
   (list (read-regexp "Show rows matching: " pps--filter)
         current-prefix-arg))
  (condition-case err
      (progn
        (string-match-p regexp "")
        (setq pps--filter (unless (string-empty-p regexp) regexp)
              pps--filter-column (and current-column pps--column))
        (pps--render))
    (invalid-regexp (user-error "%s" (error-message-string err)))))

(defun pps-clear-filter ()
  "Clear the active row filter."
  (interactive)
  (setq pps--filter nil pps--filter-column nil)
  (pps--render)
  (message "Filter cleared"))

(defun pps-find (regexp)
  "Move to the next visible cell matching REGEXP."
  (interactive (list (read-regexp "Find cell: ")))
  (let* ((sheet (pps--active-sheet))
         (column-count (length (pps--sheet-columns sheet)))
         (cells (cl-loop for row in pps--visible-indices append
                         (cl-loop for column from 0 below column-count
                                  collect (cons row column))))
         (start (or (cl-position (cons pps--row pps--column) cells
                                 :test #'equal) -1))
         (ordered (append (seq-drop cells (1+ start))
                          (seq-take cells (1+ start))))
         (case-fold-search t)
         found)
    (while (and ordered (not found))
      (let ((cell (pop ordered)))
        (when (string-match-p regexp
                              (pps--cell-display sheet (car cell) (cdr cell)))
          (setq found cell))))
    (if found (pps--select (car found) (cdr found))
      (user-error "No matching cell"))))

(defun pps-goto-cell (address)
  "Go to ADDRESS, which may be A1 or SHEET!A1."
  (interactive (list (read-string "Cell address: ")))
  (let (sheet-name reference)
    (if (string-match "\\`\\(.+\\)!\\([^!]+\\)\\'" address)
        (setq sheet-name (match-string 1 address)
              reference (match-string 2 address))
      (setq reference address))
    (when sheet-name
      (let ((position (cl-position sheet-name (pps--workbook-sheets pps--workbook)
                                   :key #'pps--sheet-name :test #'string=)))
        (unless position (user-error "No sheet named %s" sheet-name))
        (setf (pps--workbook-active-sheet pps--workbook) position)
        (setq pps--filter nil pps--filter-column nil)))
    (let ((coordinates (pps--reference-coordinates reference)))
      (unless coordinates (user-error "Invalid cell address: %s" address))
      (let ((sheet (pps--active-sheet)))
        (when (or (>= (car coordinates) (length (pps--sheet-rows sheet)))
                  (>= (cdr coordinates) (length (pps--sheet-columns sheet))))
          (user-error "Cell is outside sheet %s" (pps--sheet-name sheet))))
      (setq pps--row (car coordinates) pps--column (cdr coordinates))
      (pps--render))))

(defun pps--translate-reference (symbol row-delta column-delta)
  "Translate SYMBOL reference by ROW-DELTA and COLUMN-DELTA."
  (let ((name (symbol-name symbol)))
    (if (not (string-match
              "\\`\\(\\$?\\)\\([A-Za-z]+\\)\\(\\$?\\)\\([1-9][0-9]*\\)\\'"
              name))
        symbol
      (let* ((absolute-column (string= (match-string 1 name) "$"))
             (absolute-row (string= (match-string 3 name) "$"))
             (column (pps--column-index (match-string 2 name)))
             (row (1- (string-to-number (match-string 4 name))))
             (new-column (if absolute-column column (+ column column-delta)))
             (new-row (if absolute-row row (+ row row-delta))))
        (if (or (< new-column 0) (< new-row 0))
            symbol
          (make-symbol
           (format "%s%s%s%d"
                   (if absolute-column "$" "")
                   (pps--column-label new-column)
                   (if absolute-row "$" "")
                   (1+ new-row))))))))

(defun pps--translate-formula-expression (form row-delta column-delta)
  "Translate references in FORM by ROW-DELTA and COLUMN-DELTA."
  (cond
   ((pps--cell-reference-p form)
    (pps--translate-reference form row-delta column-delta))
   ((consp form)
    (cons (car form)
          (mapcar (lambda (item)
                    (pps--translate-formula-expression
                     item row-delta column-delta))
                  (cdr form))))
   (t form)))

(defun pps--adjust-structural-reference
    (symbol axis index count deleting)
  "Adjust reference SYMBOL for a structural edit.
AXIS is `row' or `column'.  INDEX and COUNT describe the edit.
When DELETING is non-nil, references inside the removed span become
an internal (ref-error) form."
  (let* ((name (symbol-name symbol))
         (_matched
          (string-match
           "\\`\\(\\$?\\)\\([A-Za-z]+\\)\\(\\$?\\)\\([1-9][0-9]*\\)\\'"
           name))
         (column-absolute (match-string 1 name))
         (column (pps--column-index (match-string 2 name)))
         (row-absolute (match-string 3 name))
         (row (1- (string-to-number (match-string 4 name))))
         (coordinate (if (eq axis 'row) row column))
         (last (+ index count -1)))
    (cond
     ((and deleting (<= index coordinate last))
      (list (make-symbol "ref-error")))
     (t
      (when (>= coordinate index)
        (if deleting
            (when (> coordinate last)
              (if (eq axis 'row) (setq row (- row count))
                (setq column (- column count))))
          (if (eq axis 'row) (setq row (+ row count))
            (setq column (+ column count)))))
      (make-symbol
       (format "%s%s%s%d" column-absolute (pps--column-label column)
               row-absolute (1+ row)))))))

(defun pps--adjust-formula-structure
    (form context-sheet target-sheet axis index count deleting)
  "Adjust references in FORM for a structural spreadsheet edit.
CONTEXT-SHEET names the sheet unqualified references address.
TARGET-SHEET, AXIS, INDEX, COUNT, and DELETING describe the edit."
  (cond
   ((pps--cell-reference-p form)
    (if (string= context-sheet target-sheet)
        (pps--adjust-structural-reference form axis index count deleting)
      form))
   ((consp form)
    (let* ((operator (car form))
           (name (and (symbolp operator) (downcase (symbol-name operator))))
           (arguments (cdr form)))
      (if (and (member name '("cell" "range"))
               (stringp (car arguments)))
          (cons operator
                (cons (car arguments)
                      (mapcar
                       (lambda (item)
                         (pps--adjust-formula-structure
                          item (car arguments) target-sheet axis index count
                          deleting))
                       (cdr arguments))))
        (cons operator
              (mapcar
               (lambda (item)
                 (pps--adjust-formula-structure
                  item context-sheet target-sheet axis index count deleting))
               arguments)))))
   (t form)))

(defun pps--adjust-workbook-references
    (target-sheet axis index count deleting)
  "Adjust formulas that reference TARGET-SHEET for a structural edit.
AXIS, INDEX, COUNT, and DELETING describe that edit."
  (dolist (sheet (pps--workbook-sheets pps--workbook))
    (dolist (row (pps--sheet-rows sheet))
      (cl-loop for column below (length row)
               for cell = (aref row column)
               when (pps--formula-p cell)
               do (setf (pps--formula-expr cell)
                        (pps--adjust-formula-structure
                         (pps--formula-expr cell)
                         (pps--sheet-name sheet) target-sheet axis index count
                         deleting))))))

(defun pps--copy-cell-for-offset (cell row-delta column-delta)
  "Copy CELL, translating a formula by ROW-DELTA and COLUMN-DELTA."
  (if (pps--formula-p cell)
      (pps--formula-create
       :expr (pps--translate-formula-expression
              (pps--formula-expr cell) row-delta column-delta))
    (copy-tree cell t)))

(defun pps--delimited-field (text delimiter)
  "Encode TEXT as a field separated by DELIMITER."
  (if (string-match-p (format "[\"%s\n\r]" (regexp-quote delimiter)) text)
      (concat "\"" (replace-regexp-in-string "\"" "\"\"" text t t) "\"")
    text))

(defun pps--matrix-to-delimited (matrix delimiter &optional line-ending)
  "Encode string MATRIX with DELIMITER and LINE-ENDING."
  (setq line-ending (or line-ending "\n"))
  (concat
   (mapconcat
    (lambda (row)
      (mapconcat (lambda (field) (pps--delimited-field field delimiter))
                 row delimiter))
    matrix line-ending)
   line-ending))

(defun pps--parse-delimited (text delimiter)
  "Parse RFC 4180 style TEXT using one-character DELIMITER."
  (unless (= (length delimiter) 1)
    (error "Delimiter must be one character"))
  (let ((separator (aref delimiter 0))
        (index 0)
        (length (length text))
        (quoted nil)
        (field nil)
        (row nil)
        (rows nil)
        (row-started nil))
    (while (< index length)
      (let ((character (aref text index)))
        (cond
         (quoted
          (if (= character ?\")
              (if (and (< (1+ index) length)
                       (= (aref text (1+ index)) ?\"))
                  (progn (push ?\" field) (setq index (1+ index)))
                (setq quoted nil))
            (push character field)))
         ((= character ?\")
          (if field (push character field) (setq quoted t row-started t)))
         ((= character separator)
          (push (apply #'string (nreverse field)) row)
          (setq field nil row-started t))
         ((or (= character ?\n) (= character ?\r))
          (when (and (= character ?\r) (< (1+ index) length)
                     (= (aref text (1+ index)) ?\n))
            (setq index (1+ index)))
          (push (apply #'string (nreverse field)) row)
          (push (nreverse row) rows)
          (setq field nil row nil row-started nil))
         (t (push character field) (setq row-started t))))
      (setq index (1+ index)))
    (when quoted (error "Unterminated quoted field"))
    (when (or field row row-started)
      (push (apply #'string (nreverse field)) row)
      (push (nreverse row) rows))
    (nreverse rows)))

(defun pps-copy ()
  "Copy the selected rectangle as tab-delimited text."
  (interactive)
  (let* ((sheet (pps--active-sheet))
         (bounds (pps--selection-bounds))
         (matrix
          (cl-loop for row from (nth 0 bounds) to (nth 1 bounds)
                   collect
                   (cl-loop for column from (nth 2 bounds) to (nth 3 bounds)
                            collect (copy-tree (pps--cell-raw sheet row column) t))))
         (text-matrix
          (mapcar (lambda (row) (mapcar #'pps--cell-source-string row)) matrix))
         (text (pps--matrix-to-delimited text-matrix "\t")))
    (setq pps--clipboard
          (list :text text :matrix matrix
                :origin-row (nth 0 bounds) :origin-column (nth 2 bounds)))
    (kill-new text)
    (message "Copied %d × %d cells"
             (length matrix) (if matrix (length (car matrix)) 0))))

(defun pps-cut ()
  "Copy and clear the selected rectangle."
  (interactive)
  (pps-copy)
  (pps-clear-cells))

(defun pps--ensure-columns (sheet count)
  "Ensure SHEET has at least COUNT columns."
  (when (> count pps-max-columns)
    (error "Paste would exceed pps-max-columns"))
  (let ((old-count (length (pps--sheet-columns sheet))))
    (when (> count old-count)
      (setf (pps--sheet-columns sheet)
            (append
             (pps--sheet-columns sheet)
             (cl-loop for index from old-count below count
                      collect (pps--column-create
                               :name (pps--column-label index) :type :auto))))
      (setf (pps--sheet-rows sheet)
            (mapcar
             (lambda (row)
               (let ((new (make-vector count nil)))
                 (cl-loop for index below (length row)
                          do (aset new index (aref row index)))
                 new))
             (pps--sheet-rows sheet))))))

(defun pps-paste ()
  "Paste a rectangular block at the active cell.
Text from outside PPS is parsed as tab-delimited data."
  (interactive)
  (let* ((sheet (pps--active-sheet))
         (kill-text (current-kill 0 t))
         (structured (and pps--clipboard
                          (equal kill-text (plist-get pps--clipboard :text))))
         (matrix
          (if structured
              (plist-get pps--clipboard :matrix)
            (mapcar
             (lambda (fields)
               (cl-loop for field in fields
                        for offset from 0
                        for column = (nth (min (+ pps--column offset)
                                               (1- (length (pps--sheet-columns sheet))))
                                          (pps--sheet-columns sheet))
                        collect (pps--parse-entry field column)))
             (pps--parse-delimited kill-text "\t"))))
         (height (length matrix))
         (width (if matrix (apply #'max (mapcar #'length matrix)) 0)))
    (when (or (= height 0) (= width 0)) (user-error "Clipboard has no cells"))
    (pps--record-change)
    (pps--ensure-columns sheet (+ pps--column width))
    (cl-loop for source-row in matrix
             for row-offset from 0
             do (cl-loop for cell in source-row
                         for column-offset from 0
                         do (let ((value
                                  (if structured
                                      (pps--copy-cell-for-offset
                                       cell
                                       (- (+ pps--row row-offset)
                                          (+ (plist-get pps--clipboard :origin-row)
                                             row-offset))
                                       (- (+ pps--column column-offset)
                                          (+ (plist-get pps--clipboard :origin-column)
                                             column-offset)))
                                    cell)))
                              (pps--set-cell-internal
                               sheet (+ pps--row row-offset)
                               (+ pps--column column-offset) value))))
    (setq pps--mark-cell
          (and (or (> height 1) (> width 1))
               (cons pps--row pps--column))
          pps--row (+ pps--row (1- height))
          pps--column (+ pps--column (1- width)))
    (pps--finish-change)))

(defun pps--unique-sheet-name (base)
  "Return a unique sheet name based on BASE."
  (let ((candidate base) (counter 2)
        (names (mapcar #'pps--sheet-name (pps--workbook-sheets pps--workbook))))
    (while (member candidate names)
      (setq candidate (format "%s %d" base counter)
            counter (1+ counter)))
    candidate))

(defun pps-add-sheet (name)
  "Add and switch to a blank sheet named NAME."
  (interactive (list (read-string "New sheet name: " "Sheet")))
  (when (string-empty-p name) (user-error "Sheet name may not be empty"))
  (when (pps--sheet-by-name name) (user-error "A sheet named %s already exists" name))
  (pps--record-change)
  (let* ((column-count 8)
         (sheet
          (pps--sheet-create
           :name name
           :columns (cl-loop for index below column-count
                             collect (pps--column-create
                                      :name (pps--column-label index) :type :auto))
           :rows (cl-loop repeat 20 collect (make-vector column-count nil)))))
    (setf (pps--workbook-sheets pps--workbook)
          (append (pps--workbook-sheets pps--workbook) (list sheet))
          (pps--workbook-active-sheet pps--workbook)
          (1- (length (pps--workbook-sheets pps--workbook)))))
  (setq pps--row 0 pps--column 0 pps--mark-cell nil
        pps--filter nil pps--filter-column nil)
  (pps--finish-change))

(defun pps-switch-sheet (name)
  "Switch to sheet NAME."
  (interactive
   (list (completing-read
          "Sheet: " (mapcar #'pps--sheet-name
                            (pps--workbook-sheets pps--workbook)) nil t)))
  (let ((position (cl-position name (pps--workbook-sheets pps--workbook)
                               :key #'pps--sheet-name :test #'string=)))
    (unless position (user-error "No sheet named %s" name))
    (setf (pps--workbook-active-sheet pps--workbook) position)
    (setq pps--row 0 pps--column 0 pps--mark-cell nil
          pps--filter nil pps--filter-column nil)
    (pps--render)))

(defun pps-next-sheet ()
  "Switch to the next sheet."
  (interactive)
  (let* ((count (length (pps--workbook-sheets pps--workbook)))
         (next (% (1+ (pps--workbook-active-sheet pps--workbook)) count)))
    (pps-switch-sheet (pps--sheet-name
                       (nth next (pps--workbook-sheets pps--workbook))))))

(defun pps-previous-sheet ()
  "Switch to the previous sheet."
  (interactive)
  (let* ((count (length (pps--workbook-sheets pps--workbook)))
         (previous (% (+ count -1 (pps--workbook-active-sheet pps--workbook))
                      count)))
    (pps-switch-sheet (pps--sheet-name
                       (nth previous (pps--workbook-sheets pps--workbook))))))

(defun pps--rename-sheet-in-formula (form old-name new-name)
  "Replace cross-sheet OLD-NAME with NEW-NAME in formula FORM."
  (if (not (consp form)) form
    (let ((operator (and (symbolp (car form))
                         (downcase (symbol-name (car form)))))
          (arguments (cdr form)))
      (when (and (member operator '("cell" "range"))
                 (stringp (car arguments))
                 (string= (car arguments) old-name))
        (setcar arguments new-name))
      (cons (car form)
            (mapcar (lambda (item)
                      (pps--rename-sheet-in-formula item old-name new-name))
                    arguments)))))

(defun pps-rename-sheet (name)
  "Rename the active sheet to NAME and update cross-sheet formulas."
  (interactive (list (read-string "New sheet name: "
                                  (pps--sheet-name (pps--active-sheet)))))
  (when (string-empty-p name) (user-error "Sheet name may not be empty"))
  (let* ((sheet (pps--active-sheet))
         (old-name (pps--sheet-name sheet))
         (existing (pps--sheet-by-name name)))
    (when (and existing (not (eq existing sheet)))
      (user-error "A sheet named %s already exists" name))
    (pps--record-change)
    (setf (pps--sheet-name sheet) name)
    (dolist (candidate (pps--workbook-sheets pps--workbook))
      (dolist (row (pps--sheet-rows candidate))
        (cl-loop for index below (length row)
                 for cell = (aref row index)
                 when (pps--formula-p cell)
                 do (setf (pps--formula-expr cell)
                          (pps--rename-sheet-in-formula
                           (pps--formula-expr cell) old-name name)))))
    (pps--finish-change)))

(defun pps-duplicate-sheet ()
  "Duplicate the active sheet and switch to the copy."
  (interactive)
  (let* ((original (pps--active-sheet))
         (copy (copy-tree original t))
         (name (pps--unique-sheet-name
                (concat (pps--sheet-name original) " Copy"))))
    (pps--record-change)
    (setf (pps--sheet-name copy) name
          (pps--workbook-sheets pps--workbook)
          (append (pps--workbook-sheets pps--workbook) (list copy))
          (pps--workbook-active-sheet pps--workbook)
          (1- (length (pps--workbook-sheets pps--workbook))))
    (setq pps--row 0 pps--column 0)
    (pps--finish-change)))

(defun pps-delete-sheet ()
  "Delete the active sheet; this operation is undoable."
  (interactive)
  (let ((sheets (pps--workbook-sheets pps--workbook))
        (index (pps--workbook-active-sheet pps--workbook)))
    (when (= (length sheets) 1)
      (user-error "A workbook must retain at least one sheet"))
    (pps--record-change)
    (setf (pps--workbook-sheets pps--workbook)
          (append (seq-take sheets index) (seq-drop sheets (1+ index)))
          (pps--workbook-active-sheet pps--workbook)
          (min index (- (length sheets) 2)))
    (setq pps--row 0 pps--column 0 pps--mark-cell nil)
    (pps--finish-change)))

(defun pps--import-cell (text infer-types)
  "Convert imported TEXT, optionally using INFER-TYPES.
An imported leading equals sign always remains literal text."
  (cond
   ((string-empty-p text) nil)
   ((not infer-types) text)
   ((string-equal-ignore-case text "true") t)
   ((string-equal-ignore-case text "false") pps--false)
   ((pps--number-text-p text t) (string-to-number text))
   ((pps--number-text-p text nil) (string-to-number text))
   ((pps--date-string-p text nil)
    (pps--date-create :value text :datetime-p nil))
   ((pps--date-string-p text t)
    (pps--date-create :value text :datetime-p t))
   (t text)))

(defun pps-import-delimited-file (file delimiter first-row-is-header infer-types)
  "Import FILE with DELIMITER as a new sheet.
FIRST-ROW-IS-HEADER uses its first record for column names.
INFER-TYPES recognizes numbers, booleans, and ISO dates."
  (interactive
   (let* ((file (read-file-name "Import CSV/TSV file: "))
          (default-delimiter (if (string-match-p "\\.tsv\\'" file) "\t" ",")))
     (list file
           (read-string "Delimiter: " default-delimiter)
           (y-or-n-p "Use the first row as column names? ")
           current-prefix-arg)))
  (unless (= (length delimiter) 1)
    (user-error "Delimiter must be one character"))
  (let ((contents
         (with-temp-buffer
           (let ((coding-system-for-read 'utf-8))
             (insert-file-contents file))
           (buffer-string))))
    (when (string-prefix-p "\ufeff" contents)
      (setq contents (substring contents 1)))
    (let* ((records (pps--parse-delimited contents delimiter))
           (header (and first-row-is-header (pop records)))
           (column-count
            (max 1 (apply #'max 1 (mapcar #'length
                                          (if header (cons header records)
                                            records)))))
           (names
            (cl-loop for index below column-count
                     for candidate = (and header (nth index header))
                     collect (if (and candidate (not (string-empty-p candidate)))
                                 candidate (pps--column-label index))))
           (columns (mapcar (lambda (name)
                              (pps--column-create :name name :type :auto)) names))
           (rows
            (mapcar
             (lambda (record)
               (let ((row (make-vector column-count nil)))
                 (cl-loop for field in record
                          for index from 0
                          do (aset row index (pps--import-cell field infer-types)))
                 row))
             records))
           (name (pps--unique-sheet-name (file-name-base file)))
           (sheet (pps--sheet-create :name name :columns columns
                                     :rows (or rows
                                               (list (make-vector column-count nil))))))
      (pps--record-change)
      (setf (pps--workbook-sheets pps--workbook)
            (append (pps--workbook-sheets pps--workbook) (list sheet))
            (pps--workbook-active-sheet pps--workbook)
            (1- (length (pps--workbook-sheets pps--workbook))))
      (setq pps--row 0 pps--column 0 pps--mark-cell nil
            pps--filter nil pps--filter-column nil)
      (pps--finish-change)
      (message "Imported %d rows into sheet %s" (length rows) name))))

(defun pps--export-cell (sheet row column calculated)
  "Return export text for SHEET cell ROW, COLUMN.
CALCULATED chooses formula results instead of formula source."
  (let ((raw (pps--cell-raw sheet row column)))
    (if (and calculated (pps--formula-p raw))
        (pps--formula-string (pps--cell-value sheet row column nil))
      (pps--cell-source-string raw))))

(defun pps-export-delimited-file (file delimiter calculated)
  "Export the active sheet to FILE using DELIMITER.
When CALCULATED is non-nil, export formula results."
  (interactive
   (let* ((file (read-file-name "Export active sheet: " nil nil nil
                                (concat (pps--sheet-name (pps--active-sheet))
                                        ".csv")))
          (default-delimiter (if (string-match-p "\\.tsv\\'" file) "\t" ",")))
     (list file (read-string "Delimiter: " default-delimiter)
           current-prefix-arg)))
  (unless (= (length delimiter) 1)
    (user-error "Delimiter must be one character"))
  (let* ((sheet (pps--active-sheet))
         (headers (mapcar #'pps--column-name (pps--sheet-columns sheet)))
         (matrix
          (cons headers
                (cl-loop for _row in (pps--sheet-rows sheet)
                         for row-index from 0
                         collect
                         (cl-loop for column from 0 below (length headers)
                                  collect (pps--export-cell
                                           sheet row-index column calculated)))))
         (text (pps--matrix-to-delimited matrix delimiter)))
    (with-temp-buffer
      (insert text)
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (point-min) (point-max) file nil 'silent)))
    (message "Exported sheet %s to %s" (pps--sheet-name sheet) file)))

(defun pps--value-matches-column-p (value type)
  "Return non-nil when VALUE conforms to declared column TYPE."
  (or (null value) (pps--formula-p value) (eq type :auto)
      (and (eq type :text) (stringp value))
      (and (eq type :integer) (integerp value))
      (and (eq type :number) (numberp value))
      (and (eq type :boolean) (or (eq value t) (eq value pps--false)))
      (and (eq type :date) (pps--date-p value)
           (not (pps--date-datetime-p value)))
      (and (eq type :datetime) (pps--date-p value)
           (pps--date-datetime-p value))))

(defun pps-validate ()
  "Validate types and formulas, displaying a report."
  (interactive)
  (setq pps--formula-cache (make-hash-table :test #'equal))
  (let ((workbook pps--workbook)
        (title (pps--title))
        issues)
    (dolist (sheet (pps--workbook-sheets workbook))
      (cl-loop for row in (pps--sheet-rows sheet)
               for row-index from 0
               do (cl-loop for column in (pps--sheet-columns sheet)
                           for column-index from 0
                           for raw = (aref row column-index)
                           for value = (pps--cell-value sheet row-index
                                                       column-index nil)
                           unless (pps--value-matches-column-p
                                   raw (pps--column-type column))
                           do (push
                               (format "%s!%s%d: value does not match %s"
                                       (pps--sheet-name sheet)
                                       (pps--column-label column-index)
                                       (1+ row-index)
                                       (pps--column-type column)) issues)
                           when (pps--error-p value)
                           do (push
                               (format "%s!%s%d: %s — %s"
                                       (pps--sheet-name sheet)
                                       (pps--column-label column-index)
                                       (1+ row-index)
                                       (pps--error-code value)
                                       (or (pps--error-detail value) "formula error"))
                               issues))))
    (with-current-buffer (get-buffer-create "*PPS Validation*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "PPS validation: %s\n\n" title))
        (if issues
            (dolist (issue (nreverse issues)) (insert "- " issue "\n"))
          (insert "No issues found.\n"))
        (special-mode)
        (goto-char (point-min)))
      (display-buffer (current-buffer)))))

(defun pps-selection-summary ()
  "Show count, sum, minimum, maximum, and average for the selection."
  (interactive)
  (let* ((sheet (pps--active-sheet))
         (bounds (pps--selection-bounds))
         (values
          (cl-loop for row from (nth 0 bounds) to (nth 1 bounds) append
                   (cl-loop for column from (nth 2 bounds) to (nth 3 bounds)
                            collect (pps--cell-value sheet row column nil))))
         (numbers (seq-filter #'numberp values)))
    (message "Cells: %d; numeric: %d%s"
             (length values) (length numbers)
             (if numbers
                 (format "; sum: %s; average: %s; min: %s; max: %s"
                         (apply #'+ numbers)
                         (/ (apply #'+ numbers) (float (length numbers)))
                         (apply #'min numbers) (apply #'max numbers))
               ""))))

(defun pps-describe-cell ()
  "Describe the active cell and any formula error."
  (interactive)
  (let* ((sheet (pps--active-sheet))
         (raw (pps--cell-raw sheet pps--row pps--column))
         (value (pps--cell-value sheet pps--row pps--column nil)))
    (message "%s!%s%d  source: %s  value: %s%s"
             (pps--sheet-name sheet) (pps--column-label pps--column)
             (1+ pps--row) (pps--cell-source-string raw)
             (pps--formula-string value)
             (if (pps--error-p value)
                 (format " (%s)" (or (pps--error-detail value) "error")) ""))))

(defun pps-help ()
  "Display help for PPS Mode."
  (interactive)
  (describe-mode))

(defun pps--format-decode (_begin end)
  "No-op decoder that returns END for the buffer-local PPS format."
  end)

(defun pps--format-encode (begin end original-buffer)
  "Replace BEGIN through END with serialized data from ORIGINAL-BUFFER."
  (let ((serialized
         (with-current-buffer original-buffer
           (unless (derived-mode-p 'pps-mode)
             (error "PPS encoder called outside pps-mode"))
           (pps--serialize))))
    (delete-region begin end)
    (goto-char begin)
    (insert serialized)
    (point)))

(defun pps--after-save ()
  "Remember the canonical state after a successful save."
  (setq pps--saved-text (pps--serialize)))

(defun pps-revert-buffer (&optional _ignore-auto _noconfirm)
  "Reload the current PPS file from disk."
  (unless buffer-file-name (user-error "Buffer is not visiting a file"))
  (let ((source
         (with-temp-buffer
           (let ((coding-system-for-read 'utf-8))
             (insert-file-contents buffer-file-name))
           (buffer-string))))
    (setq pps--workbook (pps--parse source)
          pps--row 0 pps--column 0 pps--mark-cell nil
          pps--filter nil pps--filter-column nil
          pps--undo-stack nil pps--redo-stack nil
          pps--saved-text nil)
    (pps--render)
    (setq pps--saved-text (pps--serialize))
    (set-buffer-modified-p nil)
    (set-visited-file-modtime)
    (message "Reverted %s" (buffer-name))))

(require 'format)

(add-to-list
 'format-alist
 '(pps "Pinnacle Point Spreadsheet"
       nil pps--format-decode pps--format-encode t nil t))

(defvar-keymap pps-mode-map
  :doc "Keymap for PPS Mode."
  :parent special-mode-map
  "<left>" #'pps-previous-column
  "<right>" #'pps-next-column
  "<up>" #'pps-previous-row
  "<down>" #'pps-next-row
  "C-b" #'pps-previous-column
  "C-f" #'pps-next-column
  "C-p" #'pps-previous-row
  "C-n" #'pps-next-row
  "h" #'pps-previous-column
  "l" #'pps-next-column
  "k" #'pps-previous-row
  "j" #'pps-next-row
  "TAB" #'pps-next-cell
  "<backtab>" #'pps-previous-cell
  "<home>" #'pps-first-column
  "<end>" #'pps-last-column
  "M-<" #'pps-first-row
  "M->" #'pps-last-row
  "<next>" #'pps-page-down
  "<prior>" #'pps-page-up
  "RET" #'pps-edit-cell
  "<f2>" #'pps-edit-cell
  "e" #'pps-edit-cell
  "=" #'pps-enter-formula
  "SPC" #'pps-toggle-mark
  "C-SPC" #'pps-toggle-mark
  "C-g" #'pps-quit-selection
  "M-w" #'pps-copy
  "C-w" #'pps-cut
  "C-y" #'pps-paste
  "DEL" #'pps-clear-cells
  "<delete>" #'pps-clear-cells
  "o" #'pps-insert-row-below
  "O" #'pps-insert-row-above
  "D" #'pps-delete-rows
  "I" #'pps-insert-column-before
  "C-c I" #'pps-insert-column-after
  "C-c D" #'pps-delete-columns
  "r" #'pps-rename-column
  "t" #'pps-set-column-type
  "w" #'pps-set-column-width
  "F" #'pps-fill-selection
  "s" #'pps-sort-column
  "/" #'pps-find
  "f" #'pps-set-filter
  "C-c C-f" #'pps-clear-filter
  "g" #'pps-goto-cell
  "u" #'pps-undo
  "U" #'pps-redo
  "C-/" #'pps-undo
  "C-?" #'pps-redo
  "[" #'pps-previous-sheet
  "]" #'pps-next-sheet
  "C-c s" #'pps-switch-sheet
  "C-c a" #'pps-add-sheet
  "C-c n" #'pps-rename-sheet
  "C-c x" #'pps-delete-sheet
  "C-c d" #'pps-duplicate-sheet
  "C-c i" #'pps-import-delimited-file
  "C-c e" #'pps-export-delimited-file
  "C-c v" #'pps-validate
  "C-c =" #'pps-recalculate
  "C-c ?" #'pps-describe-cell
  "C-c +" #'pps-selection-summary
  "?" #'pps-help
  "<mouse-1>" #'pps-mouse-select)

(easy-menu-define pps-mode-menu pps-mode-map
  "Menu for PPS Mode."
  '("Spreadsheet"
    ["Edit Cell" pps-edit-cell t]
    ["Enter Formula" pps-enter-formula t]
    ["Clear Cells" pps-clear-cells t]
    ["Fill Selection" pps-fill-selection t]
    "--"
    ["Copy" pps-copy t]
    ["Cut" pps-cut t]
    ["Paste" pps-paste t]
    ["Undo" pps-undo pps--undo-stack]
    ["Redo" pps-redo pps--redo-stack]
    "--"
    ("Rows and Columns"
     ["Insert Row Above" pps-insert-row-above t]
     ["Insert Row Below" pps-insert-row-below t]
     ["Delete Selected Rows" pps-delete-rows t]
     "--"
     ["Insert Column Before" pps-insert-column-before t]
     ["Insert Column After" pps-insert-column-after t]
     ["Delete Selected Columns" pps-delete-columns t]
     ["Rename Column" pps-rename-column t]
     ["Set Column Type" pps-set-column-type t]
     ["Set Column Width" pps-set-column-width t])
    ("Sheets"
     ["Switch Sheet" pps-switch-sheet t]
     ["Previous Sheet" pps-previous-sheet t]
     ["Next Sheet" pps-next-sheet t]
     ["Add Sheet" pps-add-sheet t]
     ["Duplicate Sheet" pps-duplicate-sheet t]
     ["Rename Sheet" pps-rename-sheet t]
     ["Delete Sheet" pps-delete-sheet t])
    "--"
    ["Find" pps-find t]
    ["Filter Rows" pps-set-filter t]
    ["Clear Filter" pps-clear-filter pps--filter]
    ["Sort Column" pps-sort-column t]
    ["Go to Cell" pps-goto-cell t]
    ["Selection Summary" pps-selection-summary t]
    "--"
    ["Recalculate" pps-recalculate t]
    ["Validate Workbook" pps-validate t]
    ["Import CSV/TSV" pps-import-delimited-file t]
    ["Export CSV/TSV" pps-export-delimited-file t]
    "--"
    ["PPS Mode Help" pps-help t]))

;;;###autoload
(define-derived-mode pps-mode special-mode "PPS"
  "Browse and edit a Pinnacle Point Spreadsheet.

\<pps-mode-map>

Navigation:
  \[pps-next-row], \[pps-previous-row], \[pps-next-column], and
  \[pps-previous-column] move one cell.  \[pps-next-cell] wraps rows.
  \[pps-goto-cell] goes to an A1 address.  \[pps-next-sheet] changes sheets.

Editing:
  \[pps-edit-cell] edits a cell and \[pps-enter-formula] enters a formula.
  \[pps-toggle-mark] starts a rectangular selection.  \[pps-copy],
  \[pps-cut], and \[pps-paste] exchange TSV rectangles with the kill ring.

Data tools:
  \[pps-find] searches, \[pps-set-filter] filters, and
  \[pps-sort-column] sorts.  \[pps-import-delimited-file] imports CSV/TSV.

Saving uses normal Emacs commands, backups, file locking, and auto-save.
The visible grid is encoded as canonical PPS data whenever Emacs writes it."
  :group 'pps
  (let* ((source (buffer-substring-no-properties (point-min) (point-max)))
         (new-workbook (string-empty-p (string-trim source))))
    (setq pps--workbook (if new-workbook
                            (pps--default-workbook)
                          (pps--parse source))
          pps--row 0 pps--column 0 pps--mark-cell nil
          pps--filter nil pps--filter-column nil
          pps--undo-stack nil pps--redo-stack nil
          pps--clipboard nil pps--saved-text nil
          pps--formula-cache (make-hash-table :test #'equal))
    (setq-local buffer-file-format '(pps))
    (setq-local buffer-file-coding-system 'utf-8-unix)
    (setq-local require-final-newline t)
    (setq-local truncate-lines t)
    (setq-local word-wrap nil)
    (setq-local cursor-type 'box)
    (setq-local revert-buffer-function #'pps-revert-buffer)
    (setq-local mode-line-process '(:eval (pps--mode-line-status)))
    (add-hook 'post-command-hook #'pps--post-command nil t)
    (add-hook 'after-save-hook #'pps--after-save nil t)
    (when (and pps--face-cookie (fboundp 'face-remap-remove-relative))
      (face-remap-remove-relative pps--face-cookie))
    (setq pps--face-cookie
          (face-remap-add-relative
           'default (if pps-retro-display 'pps-default-face 'fixed-pitch)))
    (pps--render)
    (setq pps--saved-text (pps--serialize))
    (set-buffer-modified-p new-workbook)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.pps\\'" . pps-mode))

(provide 'pps-mode)

;;; pps-mode.el ends here
