EMACS ?= emacs

.PHONY: all compile info test checkdoc check clean

all: check

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile pps-mode.el

info:
	$(EMACS) -Q --batch pps-mode.texi \
	  -f texinfo-format-buffer -f save-buffer

test:
	$(EMACS) -Q --batch -L . -L test \
	  --eval '(setq load-prefer-newer t)' \
	  -l test/pps-mode-test.el -f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch -L . -l pps-mode.el -l checkdoc \
	  --eval '(checkdoc-file "pps-mode.el")'

check: compile info checkdoc test

clean:
	$(RM) pps-mode.elc test/pps-mode-test.elc
