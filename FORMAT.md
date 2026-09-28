# Pinnacle Point Spreadsheet 1

This document specifies the on-disk format understood and written by
`pps-mode.el`.  A Pinnacle Point Spreadsheet (PPS) file is UTF-8 text containing
one restricted, data-only Emacs Lisp S-expression.  Its conventional file
extension is `.pps`.

PPS is a data format.  A workbook, its formulas, and every symbol in the file
must be treated as data and must never be evaluated as Lisp.

## 1. Lexical form

A PPS 1 reader must accept:

- UTF-8 text, with or without an initial UTF-8 byte order mark;
- LF or CRLF input line endings;
- Emacs Lisp whitespace and `;` line comments; and
- exactly one top-level form, followed only by whitespace or comments.

NUL is forbidden anywhere in the decoded source.  The canonical encoding is
UTF-8 without a byte order mark, with LF line endings and a final LF.

Strings use Emacs Lisp string syntax.  This makes embedded tabs, newlines,
quotes, and backslashes unambiguous:

```elisp
"first line\nsecond line"
"a tab: \t and a quote: \""
```

Keywords and other symbols are matched by their printed names.  PPS tags and
property names are case-sensitive and lowercase.  Formula operators, formula
constants, and the letter portion of A1 references are case-insensitive.

Reader comments are not workbook data.  The reference writer discards input
comments and emits only the two standard banner comments shown in section 8.
Use metadata or cells for information that must survive a save.

## 2. Document grammar

The following grammar is descriptive.  `[...]` denotes an Emacs Lisp vector,
parentheses denote a proper list, and a trailing `?` makes a grammar item
optional.

```text
document  ::= workbook

workbook  ::= (pps
                :version 1
                meta-property?
                active-property?
                :sheets [sheet ...])

meta-property   ::= :meta metadata
active-property ::= :active-sheet string

metadata  ::= (metadata-key metadata-value ...)

sheet     ::= (:sheet
               :name string
               :columns [column ...]
               :rows [row ...])

column    ::= (:column
               :name string
               :type column-type
               width-property?
               format-property?)

width-property  ::= :width integer
format-property ::= :format string

row       ::= [cell ...]

cell      ::= :blank
            | :true
            | :false
            | string
            | number
            | (:date string)
            | (:datetime string)
            | (:formula formula)

column-type ::= :auto | :text | :integer | :number
              | :boolean | :date | :datetime

metadata-key ::= :title | :author | :description
               | :created | :modified | :license

metadata-value ::= :blank | :true | :false | string | number
```

Properties may occur in any order on input, but no property may occur more
than once.  The reference writer emits the order shown above.  Unknown
properties are errors; PPS 1 has no extension-property namespace.

`:version` and `:sheets` are required.  `:version` must be the integer `1`.
`:meta` may be omitted and then means an empty property list.  If
`:active-sheet` is omitted, the first sheet is active.  The reference writer
always emits both properties.

## 3. Workbook and sheet rules

A workbook contains at least one sheet.  A sheet has:

- a nonempty string name;
- between 1 and 16,384 columns by default; and
- between 0 and 1,000,000 rows by default.

Sheet names are unique by exact, case-sensitive string comparison.  The
`:active-sheet` value, when present, must exactly name a sheet in the workbook.

Each row must be a vector containing exactly as many cells as the sheet has
columns.  Short and long rows are invalid; omitted trailing cells are not
implied to be blank.  Use `:blank` explicitly.

Column names are nonempty strings.  They need not be unique because formulas
address cells by A1 coordinates.  A column width, when present, is an integer
from 4 through 200 under the reference implementation's default settings.
Omitting `:width` selects automatic display sizing.

Workbook metadata is deliberately small.  Metadata values have no required
interpretation beyond their keys and scalar types.  In particular, PPS 1 does
not impose a timestamp grammar on `:created` or `:modified`.  The writer does
not create or update timestamps automatically.

## 4. Cells and declared column types

The three keyword atoms have distinct meanings:

| Form | Meaning |
| --- | --- |
| `:blank` | An empty cell |
| `:true` | Boolean true |
| `:false` | Boolean false |

`nil`, `t`, and arbitrary symbols are not valid stored cells.  Text is always
an Emacs Lisp string, so strings beginning with `=` need no special escaping.
Integers and floating-point numbers are stored as Lisp numbers.

Portable producers should write finite base-10 integers and floats.  The
reference Emacs reader also recognizes other Emacs numeric spellings, but
consumers implemented in other languages are not required to accept
implementation-specific nonfinite or radix syntax.

A date is `(:date "YYYY-MM-DD")`.  A date-time is
`(:datetime "YYYY-MM-DDTHH:MM:SSZ")`, optionally with fractional seconds or a
numeric `+HH:MM` or `-HH:MM` offset.  The PPS 1 loader validates these lexical
shapes; it does not reject calendar-invalid component values such as an
out-of-range day.

Column types are declarations used by editing and validation:

| Type | Conforming nonformula value |
| --- | --- |
| `:auto` | Any valid cell |
| `:text` | String |
| `:integer` | Integer |
| `:number` | Integer or float |
| `:boolean` | `:true` or `:false` |
| `:date` | `(:date ...)` |
| `:datetime` | `(:datetime ...)` |

Blank and formula cells conform to every declared column type.  A cell whose
stored type differs from its column declaration is still a structurally valid
PPS cell: the workbook loads, and validation reports the mismatch.

The optional column `:format` is a string display hint.  The reference editor
recognizes two forms:

- `"ON|OFF"` or another pair of nonempty strings separated by one `|` gives
  the true and false display strings for boolean values.
- A single Emacs `format` conversion matching `%[flags][width][.precision]X`,
  where `X` is one of `d`, `e`, `f`, or `g`, formats numeric values.  Width is
  limited to three digits and precision to two digits.  Examples are `"%d"`,
  `"%.2f"`, and `"%08d"`.

An unrecognized or inapplicable format string is retained.  The reference
editor displays the value normally if applying a recognized numeric format
signals an error.

## 5. Formula grammar

A formula cell contains a validated Lisp-shaped abstract syntax tree:

```elisp
(:formula (+ B1 C1))
(:formula (sum (range B1 B10)))
(:formula (if (> C1 0) "OPEN" "CLOSED"))
(:formula (+ (cell "Rates" B2) $A$1))
```

Formula atoms are:

- strings and numbers;
- the case-insensitive constants `true`, `false`, and `blank`; and
- A1 references matching `$?[A-Za-z]+$?[1-9][0-9]*`.

Every formula list must be proper.  Its first element is an allowlisted
operator and its remaining elements are formula forms.  Formula vectors,
dotted lists, quoting forms, arbitrary symbols, and unlisted operators are
invalid and cause the workbook to be rejected at load time.

PPS 1 operators are:

```text
+ - * /                         arithmetic
sum average min max count counta
= /= < <= > >=                  comparison
if and or not                   logic
concat len upper lower          text
round floor ceiling truncate abs mod expt sqrt
cell range                      references
ref-error                       deleted-reference marker
```

Operator names are case-insensitive.  Formula nesting is limited to 64
validated levels by the reference implementation.

### 5.1 References and ranges

Rows and columns are one-based in formula source.  `A1` is the first data
cell; column headers are not spreadsheet rows.  A bare reference addresses
the current sheet.

`$` marks an absolute component when a formula is copied by the editor.  It
does not change lookup during evaluation:

```text
A1      relative column, relative row
$A1     absolute column, relative row
A$1     relative column, absolute row
$A$1    absolute column, absolute row
```

Cross-sheet access uses an exact, case-sensitive sheet-name string:

```elisp
(cell A1)
(cell "Rates" B2)
(range A1 C20)
(range "History" A1 C20)
```

The two endpoints of a range may be given in either order.  A rectangular
range is evaluated in row-major order.  A reference outside the sheet or a
reference to a missing sheet produces `#REF!`.  A range containing more than
100,000 cells produces `#VALUE!` under the reference limits.

`(ref-error)` is the persisted marker for a reference whose target was
deleted by a structural edit.  It always produces `#REF!`.  It is reserved
for spreadsheet editors; portable producers should emit it with no arguments.

### 5.2 Evaluation

Formula evaluation uses spreadsheet values, not Lisp evaluation.

- `+`, `-`, `*`, and `/` require numeric operands after ranges are flattened.
  `/` performs spreadsheet division, so `(/ 5 2)` is `2.5`.  Division by zero
  produces `#DIV/0!`.
- `sum`, `average`, `min`, `max`, and `count` ignore nonnumeric, nonerror
  values.  `average` with no numbers produces `#DIV/0!`; `min` and `max` with
  no numbers produce `#VALUE!`.
- `counta` counts every nonblank value.
- `=` tests an equality chain.  `/=` is the negation of that equality chain.
  The ordering operators require all operands to be numbers or all to be
  strings.  Predicates produce the PPS boolean values true and false.
- `if` takes exactly three arguments and evaluates only the selected branch.
  `and` and `or` short-circuit.  Blank and false are false; other nonerror
  values are true.
- `not`, `len`, `upper`, `lower`, `abs`, `floor`, `ceiling`, `truncate`, and
  `sqrt` take one argument.
- `round` takes a number and an optional integer digit count from -100 through
  100.  `mod` takes two numeric arguments.  `expt` takes two numeric arguments
  and limits the absolute exponent to 1,000.
- `concat` accepts any number of values.  Blank becomes an empty string,
  booleans become `TRUE` or `FALSE`, dates retain their stored text, and an
  error retains its error code.

Ranges passed into ordinary operators are flattened.  The first error among
evaluated operands propagates.  Formula evaluation detects dependency cycles
and reports `#CYCLE!`.

The runtime error codes are:

| Code | Meaning |
| --- | --- |
| `#REF!` | Invalid coordinate or missing sheet |
| `#CYCLE!` | Circular dependency |
| `#DIV/0!` | Division by zero or an arithmetic-domain error |
| `#VALUE!` | Wrong arity, wrong operand type, or another evaluation error |
| `#NAME?` | Unknown runtime name; well-formed PPS 1 input normally rejects it earlier |

Errors are calculated values and are not valid stored cell forms.

## 6. Complete example

```elisp
;; Pinnacle Point Spreadsheet — PPS 1
;; https://github.com/Pinnacle-Point-Development/pps-mode
(pps
 :version 1
 :meta (:title "Studio status"
        :author "Pinnacle Point Development"
        :license "GPL-3.0-or-later")
 :active-sheet "Control"
 :sheets
 [(:sheet
   :name "Control"
   :columns
   [(:column :name "KEY" :type :text :width 14)
    (:column :name "HOURS" :type :boolean :width 8 :format "ON|OFF")
    (:column :name "MIC" :type :boolean :width 8 :format "ON|OFF")
    (:column :name "TOTAL" :type :number :format "%.2f")]
   :rows
   [["OPEN" :true :false (:formula (+ 2 3.5))]
    ["REHEARSAL" :true :true (:formula (sum (range B1 C2)))]])
  (:sheet
   :name "Notes"
   :columns [(:column :name "NOTE" :type :text)]
   :rows [["Text beginning with = is literal"]])])
```

## 7. Safe-reader requirements

A conforming implementation must parse PPS as untrusted data.

The Emacs reference reader:

1. rejects files larger than `pps-max-file-bytes` before reading;
2. removes one initial BOM and rejects NUL;
3. binds `read-circle` and `read-symbol-shorthands` to nil;
4. interns input symbols in a private obarray;
5. uses `read-from-string` to read exactly one form;
6. permits only whitespace or comments after that form; and
7. validates every property, tag, vector, cell, and formula before building
   the workbook model.

GNU Emacs has no reader-evaluation form analogous to Common Lisp `#.` and
rejects `#.` as invalid reader syntax.  An implementation using a reader that
does offer reader evaluation must disable it.  Circular-reader notation,
arbitrary records, hash tables, byte code, functions, and other reader-created
objects are outside the PPS grammar and must be rejected.

Formula evaluation must be an explicit dispatch over the operator allowlist.
It must never call general-purpose `eval`, resolve arbitrary functions, load
code, expand macros, access files, start processes, or use the network.

## 8. Canonical serialization

The reference writer replaces the displayed grid with a normalized data form
when Emacs saves the buffer.  It writes:

```text
;; Pinnacle Point Spreadsheet — PPS 1
;; https://github.com/Pinnacle-Point-Development/pps-mode
```

followed by a pretty-printed `(pps ...)` form and a final LF.

Canonical output has these properties:

- UTF-8, no BOM, LF line endings;
- the workbook key order `:version`, `:meta`, `:active-sheet`, `:sheets`;
- sheet key order `:name`, `:columns`, `:rows`;
- column key order `:name`, `:type`, then present `:width` and `:format`;
- vectors for sheets, columns, rows, and row cells;
- explicit `:blank` cells, including trailing blanks;
- escaped newlines inside strings; and
- no source comments other than the standard banner.

Whitespace and pretty-print line wrapping are not semantically significant.
Other writers need not reproduce Emacs's exact line wrapping, but they must
emit the same data shapes and canonical UTF-8/LF text profile.

## 9. Interoperability

PPS resembles Emacs Lisp for efficient use in Emacs, but it is a restricted
format rather than an arbitrary `.el` file.  External producers and consumers
need only implement the grammar in this document: proper lists, vectors,
symbols, strings, and numbers.

The reference editor also provides delimited interchange:

- CSV or TSV import creates a new sheet.
- Import can use the first record as column names.
- Values import as text unless type inference is requested.  Inference
  recognizes booleans, numbers, date forms, and date-time forms.
- An imported field beginning with `=` always remains literal text; importing
  a delimited file cannot inject a PPS formula.
- Export writes the active sheet, including one header record, with LF record
  endings and a final LF.
- Export can write formula source such as `=(+ A1 B1)` or calculated values.
- Fields containing the delimiter, quote, CR, or LF are double-quoted, and an
  embedded quote is doubled.

Delimited interchange cannot retain sheet structure, column declarations,
widths, formats, metadata, typed date wrappers, or the distinction between a
blank and an empty string.

## 10. Resource limits

The reference implementation defaults to these input limits:

| Resource | Default limit |
| --- | ---: |
| Decoded source size | 32 MiB |
| Columns per sheet | 16,384 |
| Rows per sheet | 1,000,000 |
| Stored column width | 4 through 200 |
| Formula nesting | 64 levels |
| Cells expanded by one formula range | 100,000 |

The byte, row, column, formula-range, and minimum-width limits are Emacs
customization variables and may be made stricter or looser by a local
installation.  There is no separate PPS 1 limit on sheet count, string length,
or cell count beyond the source-size and sheet-dimension limits.  Producers
should stay within the defaults for portable use.

## 11. Version and compatibility rules

PPS 1 readers must reject a missing version, a noninteger version, and every
version other than integer `1`.  They must also reject unknown properties,
tags, column types, stored-cell forms, metadata keys, and formula operators.
This strict behavior prevents a reader from silently discarding spreadsheet
meaning it does not understand.

Consequently, a producer targeting PPS 1 must use only the syntax defined
here.  Adding a property, stored value form, or formula operator that older
PPS 1 readers would need to understand requires a new format version.
Changes to rendering, editing commands, performance, or evaluation bugs that
do not add on-disk syntax may retain version 1.

Readers may accept noncanonical whitespace, comments, a BOM, CRLF, and
property ordering, but a save through the reference writer normalizes those
differences as described in section 8.
