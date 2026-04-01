EMACS ?= emacs

XDG_CACHE_HOME ?= $(HOME)/.cache
MELPAZOID_DIR  ?= $(XDG_CACHE_HOME)/melpazoid

.PHONY: all build check test lint melpazoid byte-compile bench bench-quick clean

all: build test lint

build:
	./build.sh

check:
	zig build check

test:
	$(EMACS) --batch -Q -L . -l ert -l test/ghostel-test.el -f ghostel-test-run-elisp

lint: melpazoid

melpazoid:
	@if [ ! -d "$(MELPAZOID_DIR)" ]; then \
		git clone https://github.com/riscy/melpazoid.git "$(MELPAZOID_DIR)"; \
	fi
	RECIPE='(ghostel :fetcher github :repo "dakra/ghostel")' \
		LOCAL_REPO=$(CURDIR) \
		make -C "$(MELPAZOID_DIR)"

byte-compile:
	$(EMACS) --batch -Q -L . -f batch-byte-compile ghostel.el ghostel-debug.el

bench:
	bash bench/run-bench.sh

bench-quick:
	bash bench/run-bench.sh --quick

clean:
	rm -f ghostel-module.dylib ghostel-module.so
	rm -f ghostel.elc ghostel-debug.elc
	rm -rf zig-out .zig-cache
