.PHONY: setup build install uninstall run test clean check-deps

RELAY_DIR := relay
APP_DIR := app
RELAY_BIN := $(RELAY_DIR)/airplanemode-relay
PREFIX ?= $(HOME)/.local

PROFILE ?= turkish-air
DOMAINS ?=

# ── User targets ─────────────────────────────────────────────────

SUPPORT_DIR := $(HOME)/Library/Application Support/AirplaneMode
CERT_FILE := $(SUPPORT_DIR)/localhost.pem
KEY_FILE := $(SUPPORT_DIR)/localhost-key.pem
HOSTNAME := $(shell scutil --get LocalHostName 2>/dev/null || echo localhost)

## Install TLS certificates for the relay
setup: check-deps
	@echo "==> Installing mkcert CA (may prompt for admin password)..."
	mkcert -install
	@mkdir -p "$(SUPPORT_DIR)"
	@echo "==> Generating TLS certificates..."
	mkcert -cert-file "$(CERT_FILE)" -key-file "$(KEY_FILE)" \
		localhost "$(HOSTNAME).local" 127.0.0.1 ::1
	@echo "✓ Setup complete"
	@echo "  cert: $(CERT_FILE)"
	@echo "  key:  $(KEY_FILE)"

## Build the relay binary and Swift app
build: check-deps
	@echo "==> Building Go relay..."
	cd $(RELAY_DIR) && go build -o airplanemode-relay .
	@echo "==> Building Swift app..."
	cd $(APP_DIR) && swift build
	@echo "✓ Build complete"

## Build and install to PREFIX/bin (default: ~/.local/bin)
install: build
	@mkdir -p $(PREFIX)/bin
	@cp $(RELAY_BIN) $(PREFIX)/bin/airplanemode-relay
	@cp $$(cd $(APP_DIR) && swift build --show-bin-path)/airplanemode $(PREFIX)/bin/airplanemode
	@chmod 755 $(PREFIX)/bin/airplanemode-relay $(PREFIX)/bin/airplanemode
	@echo "✓ Installed to $(PREFIX)/bin"
	@case ":$$PATH:" in \
		*":$(PREFIX)/bin:"*) ;; \
		*) echo ""; \
		   echo "Add to your PATH if not already:"; \
		   echo "  export PATH=\"$(PREFIX)/bin:\$$PATH\""; \
		   echo ""; \
		   echo "(Add that line to ~/.zshrc to make it permanent)"; \
		   ;; \
	esac

## Remove installed binaries
uninstall:
	rm -f $(PREFIX)/bin/airplanemode-relay
	rm -f $(PREFIX)/bin/airplanemode
	@echo "✓ Uninstalled from $(PREFIX)/bin"

## Start profiling traffic
run: build
	@if [ -n "$(DOMAINS)" ]; then \
		cd $(APP_DIR) && swift run airplanemode start --profile $(PROFILE) --domains $(DOMAINS); \
	else \
		echo "Usage: make run PROFILE=turkish-air DOMAINS=example.com,api.example.com"; \
		echo ""; \
		echo "  PROFILE  Network profile (default: turkish-air)"; \
		echo "           Options: none, starlink, jetblue, turkish-air"; \
		echo "  DOMAINS  Comma-separated domains to profile (required)"; \
		exit 1; \
	fi

## Run all tests
test: check-deps
	@echo "==> Running Go tests..."
	cd $(RELAY_DIR) && go test ./...
	@echo "==> Running Swift tests..."
	cd $(APP_DIR) && swift test
	@echo "✓ All tests passed"

## Remove build artifacts
clean:
	rm -f $(RELAY_BIN)
	cd $(APP_DIR) && swift package clean 2>/dev/null || true
	rm -rf .build
	@echo "✓ Clean"

# ── Internal ─────────────────────────────────────────────────────

check-deps:
	@missing=""; \
	command -v go >/dev/null 2>&1 || missing="$$missing go"; \
	command -v swift >/dev/null 2>&1 || missing="$$missing swift"; \
	command -v mkcert >/dev/null 2>&1 || missing="$$missing mkcert"; \
	if [ -n "$$missing" ]; then \
		echo "Missing dependencies:$$missing"; \
		echo ""; \
		echo "Install with:"; \
		echo "  brew install$$missing"; \
		echo ""; \
		echo "(Swift is included with Xcode or Xcode Command Line Tools)"; \
		exit 1; \
	fi
