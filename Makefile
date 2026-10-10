.DEFAULT_GOAL := help

SWIFT_FORMAT := swift format
SWIFTLINT := swiftlint
SWIFT_FORMAT_CONFIG := .swift-format
SWIFT_SOURCES := Sources Tests

.PHONY: help build test format lint check run run-daemon

help:
	@printf '%s\n' \
		'make build       Compile all targets' \
		'make test        Run all module tests' \
		'make format      Format Swift sources in place' \
		'make lint        Run Swift format lint and SwiftLint when installed' \
		'make check       Build, test, and lint' \
		'make run         Run the empty app scaffold' \
		'make run-daemon  Run the daemon, optimized, on the provisional development socket'

build:
	swift build

test:
	swift test

format:
	$(SWIFT_FORMAT) format --in-place --configuration $(SWIFT_FORMAT_CONFIG) --recursive $(SWIFT_SOURCES)

lint:
	$(SWIFT_FORMAT) lint --strict --configuration $(SWIFT_FORMAT_CONFIG) --recursive $(SWIFT_SOURCES)
	@if command -v $(SWIFTLINT) >/dev/null 2>&1; then \
		$(SWIFTLINT) lint --strict; \
	else \
		printf '%s\n' 'SwiftLint is not installed; Swift format lint completed.'; \
	fi

check: build test lint

run:
	swift run HubAgentApp

# Always optimized: an unoptimized SwiftTerm parses terminal output about 30 times slower.
run-daemon:
	swift run -c release HubAgentDaemon
