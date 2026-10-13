.PHONY: test build

test:
	swift run BridgeSelfTest

build:
	./scripts/build-app.sh
