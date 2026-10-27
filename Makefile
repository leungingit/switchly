.PHONY: help all bootstrap generate build build-release test test-unit clean dist package zip checksums github-release open run version bump-patch bump-minor bump-major bump-build release-patch release-minor release-major release-build

.DEFAULT_GOAL := help

# Configuration
PROJECT_NAME := Switchly
SCHEME := Switchly
APP_NAME := Switchly
BUILD_DIR := ./build
DERIVED_DATA := ./DerivedData

# Marketing version, read from Info.plist (the single source of truth).
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo 0.0.0)
BUILD_NUMBER := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist 2>/dev/null || echo 0)

# Colors
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m

help: ## Show this help message
	@echo "📱 ${BLUE}${PROJECT_NAME}${NC} Build System"
	@echo ""
	@echo "Usage: make [command]"
	@echo ""
	@echo "Commands:"
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*## "}; {printf "  ${GREEN}%-15s${NC} %s\n", $$1, $$2}'
	@echo ""
	@echo "${BLUE}Quick Start:${NC}"
	@echo "  1. make bootstrap   - Generate Xcode project"
	@echo "  2. make open        - Open in Xcode"
	@echo "  3. make build       - Build the app"
	@echo "  4. make test-unit   - Run the unit tests"
	@echo "  5. make run         - Build and launch"
	@echo ""
	@echo "${BLUE}Release:${NC}"
	@echo "  make release-minor && git push origin main --tags"

all: bootstrap build ## Bootstrap and build the project

# --- Bootstrapping ---

bootstrap: check-xcodegen ## Generate Xcode project
	@echo "${YELLOW}📦 Bootstrapping ${PROJECT_NAME}...${NC}"
	@xcodegen generate
	@echo "${GREEN}✅ Project generated!${NC}"

check-xcodegen:
	@which xcodegen > /dev/null || (echo "${RED}❌ xcodegen not found!${NC} Please install: brew install xcodegen"; exit 1)

generate: ## Regenerate Xcode project
	@echo "${YELLOW}🔄 Generating Xcode project...${NC}"
	@xcodegen generate
	@echo "${GREEN}✅ Project regenerated!${NC}"

# --- Building ---
# Signing identity resolution order (highest wins):
#   1. make build SIGN_IDENTITY="..."  — explicit one-off override
#   2. local git-ignored Config/Local.xcconfig — stable dev certificate
#   3. Config/Base.xcconfig defaults — ad-hoc "-" (fresh clones & CI)
ifdef SIGN_IDENTITY
SIGN_FLAG := CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)"
endif

build: version ## Build the project (Debug)
	@echo "${YELLOW}🔨 Building ${PROJECT_NAME} (Debug)...${NC}"
	@Scripts/xcodebuild-no-warnings.sh -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'generic/platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		$(SIGN_FLAG) \
		-quiet \
		build
	@echo "${GREEN}✅ Build complete!${NC}"
	@echo "   ${BLUE}→ $(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app${NC}"
	@echo "   ${BLUE}   运行最新版: make run（会先退出旧实例）${NC}"

build-release: version ## Build the project (Release)
	@echo "${YELLOW}🔨 Building ${PROJECT_NAME} (Release)...${NC}"
	@Scripts/xcodebuild-no-warnings.sh -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		$(SIGN_FLAG) \
		-quiet \
		build
	@echo "${GREEN}✅ Release build complete!${NC}"
	@echo "   ${BLUE}→ $(DERIVED_DATA)/Build/Products/Release/$(APP_NAME).app${NC}"
	@echo "   ${BLUE}   更新 build/ 下的可分发副本: make dist 或 ./build.sh${NC}"

# --- Testing ---

test: ## Run the full test suite (unit + UI)
	@echo "${YELLOW}🧪 Running tests...${NC}"
	@xcodebuild -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-derivedDataPath $(DERIVED_DATA) \
		$(SIGN_FLAG) \
		test
	@echo "${GREEN}✅ Tests complete!${NC}"

test-unit: ## Run unit tests only (what CI runs)
	@echo "${YELLOW}🧪 Running unit tests...${NC}"
	@xcodebuild -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-derivedDataPath $(DERIVED_DATA) \
		$(SIGN_FLAG) \
		-skip-testing:SwitchlyUITests \
		test
	@echo "${GREEN}✅ Unit tests complete!${NC}"

# --- Distribution ---

dist: build-release ## Build and copy app to build/ directory
	@echo "${YELLOW}📦 Preparing distribution build...${NC}"
	@mkdir -p $(BUILD_DIR)
	@cp -R "$(DERIVED_DATA)/Build/Products/Release/$(APP_NAME).app" $(BUILD_DIR)/
	@echo "${GREEN}✅ App copied to $(BUILD_DIR)/$(APP_NAME).app${NC}"

package: zip ## Alias for `zip` — deterministic build/Switchly-<version>.zip

zip: dist ## Create a deterministic release zip: build/Switchly-<version>.zip + .sha256
	@echo "${YELLOW}📦 Creating release archive for v$(VERSION)...${NC}"
	@ASSET="$(APP_NAME)-$(VERSION).zip"; \
	rm -f "$(BUILD_DIR)/$$ASSET" "$(BUILD_DIR)/$$ASSET.sha256"; \
	ditto -c -k --keepParent "$(BUILD_DIR)/$(APP_NAME).app" "$(BUILD_DIR)/$$ASSET"; \
	cd $(BUILD_DIR) && shasum -a 256 "$$ASSET" > "$$ASSET.sha256"; \
	echo "${GREEN}✅ $(BUILD_DIR)/$$ASSET${NC}"; \
	echo "${GREEN}✅ $(BUILD_DIR)/$$ASSET.sha256${NC}"

checksums: ## Print SHA-256 checksums for everything in build/
	@cd $(BUILD_DIR) && shasum -a 256 *.zip

github-release: ## Tag and publish a GitHub Release (requires the gh CLI; TAG=vX.Y.Z)
	@which gh > /dev/null || (echo "${RED}❌ gh CLI not found!${NC} Install: brew install gh"; exit 1)
	@test -n "$(TAG)" || (echo "${RED}❌ TAG is required, e.g. make github-release TAG=v1.0.0${NC}"; exit 1)
	@echo "$(TAG)" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+' || (echo "${RED}❌ TAG must look like vX.Y.Z${NC}"; exit 1)
	@test "$(TAG)" = "v$(VERSION)" || (echo "${RED}❌ TAG $(TAG) does not match Info.plist version v$(VERSION)${NC}"; exit 1)
	@if git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null; then \
		if [ "$$(git rev-parse "$(TAG)^{commit}")" != "$$(git rev-parse HEAD)" ]; then \
			echo "${RED}❌ Tag $(TAG) exists but does not point at HEAD${NC}"; exit 1; \
		fi; \
		echo "${BLUE}ℹ️  Tag $(TAG) already exists at HEAD — pushing it.${NC}"; \
	else \
		echo "${YELLOW}🏷️  Creating tag $(TAG)...${NC}"; \
		git tag -a "$(TAG)" -m "$(TAG)"; \
	fi
	@git push origin "$(TAG)"
	@echo "${GREEN}✅ Tag pushed. GitHub Actions (.github/workflows/release.yml) will publish the release.${NC}"
	@echo "${BLUE}ℹ️  To publish locally instead, run:${NC}"
	@echo "   make zip && gh release create $(TAG) build/$(APP_NAME)-$(VERSION).zip build/$(APP_NAME)-$(VERSION).zip.sha256 --title $(TAG) --notes-file CHANGELOG.md"

# --- Cleanup ---

clean: ## Clean build artifacts
	@echo "${YELLOW}🧹 Cleaning up...${NC}"
	@rm -rf $(BUILD_DIR)
	@rm -rf $(DERIVED_DATA)
	@rm -rf *.xcodeproj
	@echo "${GREEN}✅ Clean complete!${NC}"

# --- Development helpers ---

open: ## Open the project in Xcode
	@if [ ! -d "$(PROJECT_NAME).xcodeproj" ]; then \
		echo "${YELLOW}⚠️ Project not found, generating first...${NC}"; \
		xcodegen generate; \
	fi
	@open $(PROJECT_NAME).xcodeproj

run: ## Build and run the app (Debug)
	@make build
	@# `open` only re-activates an already-running instance of the same bundle id
	@# instead of loading the new binary — kill it first so the fresh build runs.
	@-pkill -f "$(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@-pkill -x "$(APP_NAME)" 2>/dev/null || true
	@sleep 1
	@open $(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app

version: ## Print current version and build number
	@./Scripts/version.sh show

bump-patch: ## Bump patch version (0.1.0 → 0.1.1); edits Info.plist only
	@./Scripts/version.sh bump patch

bump-minor: ## Bump minor version (0.1.0 → 0.2.0); edits Info.plist only
	@./Scripts/version.sh bump minor

bump-major: ## Bump major version (0.1.0 → 1.0.0); edits Info.plist only
	@./Scripts/version.sh bump major

bump-build: ## Bump build number (1 → 2); edits Info.plist only
	@./Scripts/version.sh bump build

# Atomic releases: bump + promote CHANGELOG + commit + tag, in one step. Nothing
# is pushed — `git push origin main --tags` hands the tag to CI, which builds,
# packages and publishes the GitHub Release.
release-patch: ## Cut a patch release: bump, CHANGELOG, commit, tag vX.Y.Z
	@./Scripts/version.sh release patch

release-minor: ## Cut a minor release: bump, CHANGELOG, commit, tag vX.Y.Z
	@./Scripts/version.sh release minor

release-major: ## Cut a major release: bump, CHANGELOG, commit, tag vX.Y.Z
	@./Scripts/version.sh release major

release-build: bump-build zip ## Bump build number & package (build numbers are not tagged)
