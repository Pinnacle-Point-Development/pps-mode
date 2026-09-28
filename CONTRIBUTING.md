# Contributing

Contributions are welcome through the Pinnacle Point Development GitHub
repository.

1. Keep runtime code dependency-free and compatible with the minimum Emacs
   version declared in `pps-mode.el`.
2. Treat `.pps` input as untrusted data.  Never add general Lisp evaluation,
   arbitrary function dispatch, or implicit file/process/network access.
3. Update `FORMAT.md` and the format version when an on-disk change requires
   readers to understand new syntax.
4. Add focused ERT coverage for behavior changes and run `make check`.
5. Follow standard Emacs Lisp naming, documentation, package headers, and
   Checkdoc conventions.

By contributing, you agree that your contribution is licensed under GNU GPL
version 3 or any later version, matching the project.

