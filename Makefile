# claudeled -- Caps Lock LED indicator for Claude Code.
#
#   make            build the app bundle
#   make test       run the checks over Core/
#   make install    build, install into /Applications and PATH, relaunch
#   make uninstall  remove everything but your config
#   make release    zip the bundle for a GitHub release
#   make clean      throw away build output

VERSION ?= 1.0.0-alpha
APP      = build/claudeled.app
BUNDLE   = com.odiumuniverse.claudeled

# Core/ is free of AppKit and IOKit, so the tests can compile against it directly.
# App/ is the shell around it. A new file in either is picked up without editing this.
CORE     = $(wildcard Sources/claudeled/Core/*.swift)
APPSRC   = $(wildcard Sources/claudeled/App/*.swift)
SOURCES  = $(CORE) $(APPSRC)

# Apple silicon Homebrew is already on PATH and fpath; Intel and plain installs are not.
PREFIX  ?= $(shell [ -d /opt/homebrew ] && echo /opt/homebrew || echo /usr/local)
COMPDIR  = $(PREFIX)/share/zsh/site-functions

.PHONY: all build test install uninstall release clean run help

all: build

## build the app bundle
build: $(APP)

$(APP): $(SOURCES) Resources/claudeled.icns Makefile
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -O $(SOURCES) -o $(APP)/Contents/MacOS/claudeled
	@cp Resources/claudeled.icns $(APP)/Contents/Resources/claudeled.icns
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0">' \
	  '<dict>' \
	  '    <key>CFBundleName</key><string>claudeled</string>' \
	  '    <key>CFBundleDisplayName</key><string>claudeled</string>' \
	  '    <key>CFBundleIdentifier</key><string>$(BUNDLE)</string>' \
	  '    <key>CFBundleExecutable</key><string>claudeled</string>' \
	  '    <key>CFBundleIconFile</key><string>claudeled</string>' \
	  '    <key>CFBundlePackageType</key><string>APPL</string>' \
	  '    <key>CFBundleShortVersionString</key><string>$(VERSION)</string>' \
	  '    <key>CFBundleVersion</key><string>$(VERSION)</string>' \
	  '    <key>LSMinimumSystemVersion</key><string>13.0</string>' \
	  '    <key>LSUIElement</key><true/>' \
	  '</dict>' \
	  '</plist>' > $(APP)/Contents/Info.plist
	@# Ad-hoc signature: SMAppService ("Start at login") refuses an unsigned bundle.
	@# It also changes with every build, which is why install resets the TCC grant.
	@codesign --force --sign - $(APP) 2>/dev/null
	@echo "built $(APP)"

# Drawn from code rather than committed as a blob, so it stays reviewable in a diff.
Resources/claudeled.icns: Tools/make-icon.swift
	@mkdir -p build Resources
	swiftc -O Tools/make-icon.swift -o build/make-icon
	@./build/make-icon Resources/claudeled.iconset
	@iconutil -c icns Resources/claudeled.iconset -o $@

## run the checks
test: build/tests
	@./build/tests

build/tests: $(CORE) Tests/main.swift
	@mkdir -p build
	swiftc -O $(CORE) Tests/main.swift -o $@

## build, install into /Applications and PATH, relaunch
install: build
	@# A running copy would keep hold of the LEDs after its bundle is replaced.
	@pkill -f '/claudeled.app/Contents/MacOS/claudeled' 2>/dev/null || true
	@sleep 1
	rm -rf /Applications/claudeled.app
	cp -R $(APP) /Applications/claudeled.app
	@mkdir -p $(PREFIX)/bin $(COMPDIR)
	ln -sf /Applications/claudeled.app/Contents/MacOS/claudeled $(PREFIX)/bin/claudeled
	@# Remove first: the destination may be a symlink back to this very file.
	@rm -f $(COMPDIR)/_claudeled
	cp completions/_claudeled $(COMPDIR)/_claudeled
	@# The rebuilt bundle has a new ad-hoc identity, so the old Input Monitoring grant
	@# no longer applies and macOS will not re-ask by itself. Clearing it restores the
	@# prompt; the app restarts itself once you answer.
	@tccutil reset ListenEvent $(BUNDLE) >/dev/null 2>&1 || true
	@open /Applications/claudeled.app
	@echo
	@echo "installed: /Applications/claudeled.app"
	@echo "cli:       $(PREFIX)/bin/claudeled"
	@echo "grant Input Monitoring when asked; the app restarts itself once you do"

## remove everything but ~/.config/claudeled
uninstall:
	@echo "untick 'Claude Code hooks installed' in the menu first, or the hooks stay behind"
	@pkill -f '/claudeled.app/Contents/MacOS/claudeled' 2>/dev/null || true
	rm -rf /Applications/claudeled.app
	rm -f $(PREFIX)/bin/claudeled $(COMPDIR)/_claudeled
	@echo "config left at ~/.config/claudeled -- remove it by hand if you mean it"

## zip the bundle for a GitHub release
release: build
	@cp -R completions build/completions
	@cd build && zip -qr claudeled-$(VERSION).zip claudeled.app completions
	@echo "release: build/claudeled-$(VERSION).zip"
	@echo "sha256:  $$(shasum -a 256 build/claudeled-$(VERSION).zip | cut -d' ' -f1)"

## run the built app without installing it
run: build
	@open $(APP)

## throw away build output
clean:
	rm -rf build

help:
	@awk '/^## /{doc=substr($$0,4);next} \
	      /^[a-z][a-z-]*:/{if(doc){split($$0,t,":");printf "  make %-11s %s\n",t[1],doc;doc=""}}' Makefile
