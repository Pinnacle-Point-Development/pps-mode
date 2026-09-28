EMACS ?= emacs

.PHONY: all compile test checkdoc check clean

all: check

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile pps-mode.el

test:
	$(EMACS) -Q --batch -L . -L test \
	  --eval '(setq load-prefer-newer t)' \
	  -l test/pps-mode-test.el -f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch -L . -l pps-mode.el -l checkdoc \
	  --eval '(checkdoc-file "pps-mode.el")'

check: compile checkdoc test

clean:
	$(RM) pps-mode.elc test/pps-mode-test.elc

