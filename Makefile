.PHONY: check test build integration verify install
PYTHON ?= .venv/bin/python
check:
	scripts/check.sh
test:
	scripts/test.sh
build:
	scripts/build.sh release
integration:
	$(PYTHON) scripts/integration-test.py
verify:
	python3 scripts/verify-app.py
install:
	scripts/install.sh
