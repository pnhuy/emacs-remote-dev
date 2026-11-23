# Convenience wrappers; every target is a plain `sh`/`emacs` command you can run yourself.
EMACS ?= emacs

.PHONY: test quality lint check e2e bench clean

test:      ## ERT + Python unit tests (local, no network)
	sh test/run-all.sh

quality:   ## byte-compile, checkdoc, docstring and comment gates
	sh test/check-quality.sh

lint:      ## POSIX-sh / Python 3.8 portability checks
	sh test/portability-lint.sh

check: test quality lint

e2e:       ## one scenario: make e2e S=baseline [RDEV_TEST_SSH_TARGET=host]
	sh test/e2e/run.sh $(or $(S),baseline)

bench:     ## make bench HOST=myhost OUT=out.csv [PROFILES="rtt50 rtt150"]
	sh bench/run.sh $(HOST) $(or $(OUT),out.csv) $(PROFILES)

clean:
	rm -f *.elc
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
