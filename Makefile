EMACS      ?= emacs
PYTHON     ?= python3
# Extra flags injected before every Emacs invocation (e.g. `-L /tmp/compat'
# in CI so older Emacs versions can find the compat library).
EMACSFLAGS ?=
export EMACSFLAGS

XDG_CACHE_HOME ?= $(HOME)/.cache
MELPAZOID_DIR  ?= $(XDG_CACHE_HOME)/melpazoid
EVIL_DIR       ?= $(XDG_CACHE_HOME)/evil
LINT_ELPA_DIR  ?= $(XDG_CACHE_HOME)/ghostel-lint-elpa
LINT_DEPS_STAMP := $(LINT_ELPA_DIR)/.deps-installed

ELISP_FILES := $(filter-out %-autoloads.el,$(wildcard lisp/ghostel*.el) \
                                      $(wildcard extensions/evil-ghostel/*.el))
PACKAGE_FILES := $(shell grep -l '^;; Package-Requires:' $(ELISP_FILES) 2>/dev/null)
CORE_PACKAGE_FILE := $(firstword $(filter lisp/%,$(PACKAGE_FILES)))
ELISP := $(CORE_PACKAGE_FILE) $(filter-out $(CORE_PACKAGE_FILE),$(ELISP_FILES))
ELC := $(patsubst %.el,%.elc,$(ELISP))

CHECKDOC_FILES = $(ELISP) $(sort $(wildcard test/*-test-helpers.el)) $(TEST_FILES)
DOCQUOTE_FILES = $(ELISP)
elisp-string-list = $(foreach f,$(1),\"$(f)\")

# Native module artifact (kept in sync with `clean').  Listed as a real
# file so the per-test stamp rules depend on its mtime instead of on the
# phony `build' target — that way the Zig sources, not the act of asking
# for `build', decide whether tests need to re-run.
UNAME := $(shell uname)
ifeq ($(UNAME),Darwin)
  MODULE := ghostel-module.dylib
else
  MODULE := ghostel-module.so
endif
ZIG_SOURCES := $(wildcard src/*.zig src/*.c build.zig build.zig.zon symbols.map) \
               $(wildcard vendor/*.h)

.PHONY: all build test test-native test-zig test-hypothesis test-hypothesis-cases test-all test-evil lint melpazoid melpazoid-ghostel melpazoid-evil-ghostel byte-compile docquotes bench bench-quick bench-e2e bench-tui-partial clean regen-terminfo

# Recommended invocation: `make -j$(nproc) all' on Linux,
# `make -j$(sysctl -n hw.ncpu) all' on macOS.  GNU make 4+ also accepts
# bare `-j' (unlimited); pair with `-l$(nproc)' to cap by load.
all: build test-all test-evil lint

build: $(MODULE)

$(MODULE): $(ZIG_SOURCES)
	zig build -Doptimize=ReleaseFast -Dcpu=baseline

test-zig:
	zig build test

test-hypothesis: build
	$(PYTHON) -m unittest test/hypothesis/test_render.py

test-hypothesis-cases: build
	cd test/hypothesis && $(PYTHON) -m unittest test_render.RenderSavedCaseRegressionTest

# Pattern rule: rebuild .elc whenever its .el source is newer.
# Make's timestamp tracking keeps the byte-compiled files in sync, so
# test targets never load stale .elc (Emacs prefers .elc over .el
# even when the source is newer, which silently masks edits).
lisp/%.elc: lisp/%.el
	$(EMACS) --batch $(EMACSFLAGS) -Q -L lisp --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile $<

# Extension packages depend on third-party libraries; reuse the evil
# checkout that `test-evil' manages.
$(EVIL_DIR):
	git clone --depth 1 https://github.com/emacs-evil/evil.git "$@"

extensions/evil-ghostel/%.elc: extensions/evil-ghostel/%.el | $(EVIL_DIR)
	$(EMACS) --batch $(EMACSFLAGS) -Q -L "$(EVIL_DIR)" -L lisp -L extensions/evil-ghostel \
		--eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile $<

# Per-topic test files.  Each file becomes its own Make target with a
# per-file stamp under .build/tests/, so `make -jN' parallelises test
# execution across cores.  The slowest single file sets the wall floor,
# not the sum of all files.
TEST_FILES        := $(sort $(wildcard test/ghostel-*-test.el))
TEST_BASES        := $(notdir $(basename $(TEST_FILES)))
TEST_STAMPS_DIR   := .build/tests
TEST_ELISP_STAMPS  := $(patsubst %,$(TEST_STAMPS_DIR)/elisp-%.ok,$(TEST_BASES))
TEST_NATIVE_STAMPS := $(patsubst %,$(TEST_STAMPS_DIR)/native-%.ok,$(TEST_BASES))

test: $(TEST_ELISP_STAMPS)

test-native: $(TEST_NATIVE_STAMPS)

# Pass `-O target' (output-sync, GNU make 4+) for clean interleaving:
#   make -j$(nproc) -O target test
$(TEST_STAMPS_DIR):
	@mkdir -p $@

$(TEST_STAMPS_DIR)/elisp-%.ok: test/%.el test/ghostel-test-helpers.el $(ELC) | $(TEST_STAMPS_DIR)
	@printf '  ELISP   %s\n' $*
	@$(EMACS) --batch $(EMACSFLAGS) -Q -L lisp -L test \
		-l ert -l test/ghostel-test-helpers.el -l $< \
		--eval "(ert-run-tests-batch-and-exit '(not (tag native)))"
	@touch $@

$(TEST_STAMPS_DIR)/native-%.ok: test/%.el test/ghostel-test-helpers.el $(ELC) $(MODULE) | $(TEST_STAMPS_DIR)
	@printf '  NATIVE  %s\n' $*
	@$(EMACS) --batch $(EMACSFLAGS) -Q -L lisp -L test \
		-l ert -l test/ghostel-test-helpers.el -l $< \
		--eval "(ert-run-tests-batch-and-exit '(tag native))"
	@touch $@

test-all: test test-zig test-native

test-evil: build $(ELC) | $(EVIL_DIR)
	$(EMACS) --batch $(EMACSFLAGS) -Q -L "$(EVIL_DIR)" -L lisp -L extensions/evil-ghostel \
		-l ert -l test/evil-ghostel-test.el -f evil-ghostel-test-run

byte-compile: $(ELC)

lint: byte-compile package-lint checkdoc docquotes

# `package-lint' needs two things present that aren't on any default load path:
# the linter itself, and a resolvable `ghostel' package.
# Provision both into an isolated `package-user-dir'
# so `make package-lint' runs standalone.
$(LINT_DEPS_STAMP): $(CORE_PACKAGE_FILE)
	$(EMACS) --batch $(EMACSFLAGS) -Q \
		--eval "(setq package-user-dir \"$(LINT_ELPA_DIR)\")" \
		--eval "(package-initialize)" \
		--eval "(package-refresh-contents)" \
		--eval "(package-install 'package-lint)" \
		--eval "(package-install-file (expand-file-name \"$(CORE_PACKAGE_FILE)\"))"
	@touch $@

package-lint: $(LINT_DEPS_STAMP) $(PACKAGE_FILES)
	$(EMACS) --batch $(EMACSFLAGS) -Q -L lisp \
		--eval "(setq package-user-dir \"$(LINT_ELPA_DIR)\")" \
		--eval "(package-initialize)" \
		--eval "(require 'package-lint)" \
		-f package-lint-batch-and-exit \
		$(PACKAGE_FILES)

checkdoc: $(CHECKDOC_FILES)
	$(EMACS) --batch $(EMACSFLAGS) -Q \
		--eval "(require 'checkdoc)" \
		--eval "(let ((sentence-end-double-space nil) \
		              (checkdoc-proper-noun-list nil) \
		              (checkdoc-verb-check-experimental-flag nil) \
		              (ok t)) \
		  (dolist (f '($(call elisp-string-list,$(CHECKDOC_FILES)))) \
		    (ignore-errors (kill-buffer \"*Warnings*\")) \
		    (let ((inhibit-message t)) \
		      (checkdoc-file f)) \
		    (when (get-buffer \"*Warnings*\") \
		      (setq ok nil) \
		      (with-current-buffer \"*Warnings*\" \
		        (message \"%s\" (buffer-string))))) \
		  (unless ok (kill-emacs 1)))"

# Mirrors melpazoid's "Only use back/front quotes to link to top-level
# elisp symbols" check, widened to also catch identifiers with
# underscores like INSIDE_EMACS — env-var and macro-style names that
# melpazoid's stricter [A-Z]+ regex skips.
docquotes: $(DOCQUOTE_FILES)
	$(EMACS) --batch $(EMACSFLAGS) -Q \
		--eval "(let ((ok t)) \
		  (dolist (f '($(call elisp-string-list,$(DOCQUOTE_FILES)))) \
		    (with-temp-buffer \
		      (insert-file-contents f) \
		      (setq case-fold-search nil) \
		      (goto-char (point-min)) \
		      (while (re-search-forward \"\`[A-Z_]+'\" nil t) \
		        (setq ok nil) \
		        (message \"%s:%d:%d: Only use back/front quotes to link to top-level elisp symbols (%s)\" \
		                 f (line-number-at-pos) \
		                 (1+ (- (match-beginning 0) (line-beginning-position))) \
		                 (match-string 0))))) \
		  (unless ok (kill-emacs 1)))"

melpazoid: melpazoid-ghostel melpazoid-evil-ghostel

melpazoid-ghostel:
	@if [ ! -d "$(MELPAZOID_DIR)" ]; then \
		git clone https://github.com/riscy/melpazoid.git "$(MELPAZOID_DIR)"; \
	fi
	RECIPE='(ghostel :fetcher github :repo "dakra/ghostel" :files (:defaults "etc" "src" "vendor" "build.zig" "build.zig.zon" "symbols.map"))' \
		LOCAL_REPO=$(CURDIR) \
		make -C "$(MELPAZOID_DIR)"

melpazoid-evil-ghostel:
	@if [ ! -d "$(MELPAZOID_DIR)" ]; then \
		git clone https://github.com/riscy/melpazoid.git "$(MELPAZOID_DIR)"; \
	fi
	RECIPE='(evil-ghostel :fetcher github :repo "dakra/ghostel" :files ("extensions/evil-ghostel/evil-ghostel.el"))' \
		LOCAL_REPO=$(CURDIR) \
		make -C "$(MELPAZOID_DIR)"

bench:
	bash bench/run-bench.sh

bench-quick:
	bash bench/run-bench.sh --quick

bench-e2e:
	bash bench/run-bench.sh --e2e

bench-tui-partial:
	$(EMACS) --batch $(EMACSFLAGS) -Q -L lisp -l bench/ghostel-bench.el \
		--eval '(progn (setq ghostel-bench-include-vterm nil ghostel-bench-include-eat nil ghostel-bench-include-term nil) (ghostel-bench--load-backends) (ghostel-bench--run-tui-partial-scenarios))'

clean:
	rm -f ghostel-module.dylib ghostel-module.so
	rm -f $(ELC)
	rm -rf zig-out .zig-cache .build

# Maintainer-only: regenerate the bundled compiled terminfo from
# `etc/terminfo/xterm-ghostty.terminfo'.  Run after bumping libghostty
# (the source file should be re-extracted from a fresh Ghostty install
# via `infocmp -x xterm-ghostty') and commit the resulting binaries.
# `tic' on macOS emits the BSD hashed-dir layout (78/, 67/); the
# binary file format is identical to Linux ncurses, so we mirror the
# compiled entries into the Linux layout (x/, g/) by copying.
regen-terminfo:
	rm -rf etc/terminfo/x etc/terminfo/g etc/terminfo/78 etc/terminfo/67
	tic -x -o etc/terminfo/ etc/terminfo/xterm-ghostty.terminfo
	@if [ -d etc/terminfo/78 ]; then \
		mkdir -p etc/terminfo/x etc/terminfo/g; \
		cp etc/terminfo/78/xterm-ghostty etc/terminfo/x/xterm-ghostty; \
		cp etc/terminfo/67/ghostty etc/terminfo/g/ghostty; \
	fi
	@TERMINFO=$(CURDIR)/etc/terminfo infocmp xterm-ghostty >/dev/null \
		|| (echo "ERROR: regenerated terminfo failed to round-trip"; exit 1)
	@find etc/terminfo -type f | sort
