.PHONY: build debug run demo test audit netcheck snapshots icon install uninstall clean

build:
	bash scripts/build.sh

debug:
	CONFIG=debug bash scripts/build.sh

run: build
	open build/Brim.app

# Deterministic sample data, kept apart from real readings and settings.
demo: build
	open -n build/Brim.app --args --demo

test:
	bash scripts/test.sh

audit: build
	bash scripts/privacy-audit.sh

netcheck: build
	bash scripts/netcheck.sh

snapshots: build
	build/Brim.app/Contents/MacOS/Brim --render-snapshots build/snapshots

icon:
	mkdir -p build/icon
	swiftc -sdk "$$(tail -1 build/.sdk-cache)" scripts/make-icon.swift -o build/icon/make-icon
	build/icon/make-icon build/icon/AppIcon.iconset
	iconutil -c icns build/icon/AppIcon.iconset -o Resources/AppIcon.icns

install: build
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/Brim.app"
	cp -R build/Brim.app "$(HOME)/Applications/Brim.app"
	@echo "Installed to ~/Applications/Brim.app"

uninstall:
	bash scripts/uninstall.sh

clean:
	rm -rf build
