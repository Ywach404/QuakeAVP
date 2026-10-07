SCHEME  := QuakeAVP
PROJECT := QuakeAVP.xcodeproj
DEST    := generic/platform=visionOS

.PHONY: help gen build device run check clean

help:
	@echo "make check    -- host-compile + link QuakeCore (no Xcode needed)"
	@echo "make gen      -- regenerate $(PROJECT) from project.yml"
	@echo "make build    -- gen, then build for the visionOS simulator"
	@echo "make device   -- gen, then build for a real Vision Pro"
	@echo "make run      -- build, install and launch on device DETACHED (audio works)"
	@echo "make clean    -- drop generated project and build output"

# The fast loop. Compiles every C translation unit and links an executable, so
# it catches type errors and missing platform stubs in a couple of seconds.
# It does NOT prove the visionOS build: run `make build` for that.
check:
	@tools/check-core.sh

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
		build

device: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DEST)' \
		build

# Launch on the headset WITHOUT the debugger (lldb breaks audio/compositor XPC).
# This is the way to test audio and immersive: one command, no Xcode Run button,
# no Stop-then-tap, no attached/detached ambiguity.
run: gen
	tools/run-device.sh

clean:
	rm -rf $(PROJECT) build DerivedData
