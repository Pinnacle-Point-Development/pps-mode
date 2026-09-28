# PPS Mode

PPS Mode is the GNU Emacs editor and reference implementation for the
Pinnacle Point Spreadsheet (`.pps`) format.  It turns a safe, readable
S-expression into a compact black-and-yellow spreadsheet interface modeled on
the COLORMODECTL display.

The package is keyboard first, works in GUI and terminal Emacs, and has no
dependencies outside GNU Emacs.

## Features

- Multiple sheets with typed columns and configurable widths
- Cell and rectangular-range editing, copy, cut, paste, and fill
- Row and column insertion/deletion with formula reference updates
- Lisp-shaped formulas with ranges, cross-sheet references, recalculation,
  cycle detection, and spreadsheet error values
- Search, regular-expression filtering, stable typed sorting, and selection
  summaries
- CSV/TSV import and export with RFC 4180 quoting
- Logical undo/redo, normal Emacs backups, file locking, save-as, revert, and
  valid `.pps` auto-save files
- Paged rendering for large sheets
- Strict data-only parsing: file formulas are interpreted by an allowlist and
  never passed to `eval`

The complete file-format contract is in [FORMAT.md](FORMAT.md).

## Requirements

GNU Emacs 29.1 or newer.  Development and release tests run on GNU Emacs 31.1.

## Install

Once the repository is published, Emacs 29 and newer can install it directly:

```elisp
(package-vc-install
 '(pps-mode
   :url "https://github.com/Pinnacle-Point-Development/pps-mode.git"
   :vc-backend Git
   :main-file "pps-mode.el"))
```

For a manual install, download `pps-mode.el`, run
`M-x package-install-file`, and select it.  Developers can clone the repository
and add it to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/pps-mode")
(require 'pps-mode)
```

Files ending in `.pps` then open in PPS Mode automatically.

## Manual

The distribution includes a GNU Info manual.  Run `M-x pps-info`, press
`C-c C-i` in a PPS buffer, or open the Info directory with `C-h i` and select
**PPS Mode**.  The Texinfo source is [pps-mode.texi](pps-mode.texi).

Repository channels are:

- `public` — stable, released code and the default install branch;
- `nightly` — the next tested integration state; and
- `experimental` — early work that may change or be discarded.

## Start

Open [examples/colormodectl.pps](examples/colormodectl.pps), or create a new
file whose name ends in `.pps`.  An empty file opens as a blank workbook.

Common keys:

| Key | Action |
| --- | --- |
| Arrows or `h j k l` | Move between cells |
| `TAB` / `S-TAB` | Move and wrap between rows |
| `RET`, `F2`, or `e` | Edit cell |
| `=` | Enter a formula |
| `SPC` | Start or clear a rectangular selection |
| `M-w`, `C-w`, `C-y` | Copy, cut, paste |
| `o` / `O` | Insert row below / above |
| `D` | Delete selected rows |
| `I` | Insert column before |
| `s` | Sort by active column |
| `/` / `f` | Search / filter |
| `g` | Go to an address such as `B12` or `Rates!B2` |
| `[` / `]` | Previous / next sheet |
| `u` / `U` | Undo / redo |
| `C-c C-i` | Open the Info manual |
| `?` | Full mode help |

The **Spreadsheet** menu exposes every command, including sheet management,
validation, import, and export.

## Formulas

Formula entry begins with `=` and uses a restricted Lisp-shaped expression:

```elisp
=(+ B1 C1)
=(sum (range B1 B20))
=(if (> C1 0) "OPEN" "CLOSED")
=(+ (cell "Rates" B2) $A$1)
```

Supported functions cover arithmetic, comparison, logic, text, numeric
helpers, aggregates, cells, and ranges.  A formula cannot execute Lisp, load
code, access files, start a process, or use the network.

## Interchange

`M-x pps-import-delimited-file` imports CSV or TSV as a new sheet.  Imported
fields beginning with `=` remain literal text.  With a prefix argument, the
importer infers numbers, booleans, dates, and date-times.

`M-x pps-export-delimited-file` exports the active sheet.  A prefix argument
exports calculated formula values; otherwise it exports formula source.

## Development

```sh
make check
```

This byte-compiles with warnings treated as errors, runs Checkdoc, and runs
the ERT suite.  See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution rules.

## License

PPS Mode is free software licensed under GNU GPL version 3 or, at your option,
any later version.  See [COPYING](COPYING).
