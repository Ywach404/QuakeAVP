SCHEME  := QuakeAVP
PROJECT := QuakeAVP.xcodeproj
DEST    := generic/platform=visionOS

ARCHIVE := build/QuakeAVP.xcarchive
IPA_DIR := build/ipa
IPA     := build/QuakeAVP.ipa

# The author's own paks and soundtrack rips live in App/DevGameData so a dev
# build runs without a manual Files copy. They are id Software's data and A.'s
# licensed rips; neither may leave this machine. Excluding them by NAME keeps
# QuakeSpasm's own quakespasm.pak, which is GPL and has to ship.
#
# EXCLUDED_SOURCE_FILE_NAMES has no case-insensitive mode, so the uppercase
# variants below are cheap partial cover only -- exactly how an original
# Quake CD spells its data (ID1/PAK0.PAK) would still slip past this list on
# a case-sensitive volume if a pattern were missing. The find assertion in
# the `ipa` recipe below is the real backstop: it is case-insensitive and is
# what the target actually depends on to refuse a dirty payload.
IPA_EXCLUDES := EXCLUDED_SOURCE_FILE_NAMES='pak0.pak pak1.pak pak2.pak PAK0.PAK PAK1.PAK PAK2.PAK music *.ogg *.OGG *.mp3 *.MP3 *.wav *.WAV *.flac *.FLAC'

# Case-insensitive on purpose (see the comment above IPA_EXCLUDES): this is
# the check that cannot be taken back, so it must not depend on how a pak or
# a music file happens to be cased. Covers id's own data extensions plus a
# music directory by name, not just the dev machine's current lowercase
# files -- deliberately a denylist rather than an allowlist of the expected
# six payload entries, so a legitimate new payload file Xcode adds later
# does not start failing `make ipa` on its own.
PAYLOAD_GUARD := \( -iname 'pak[0-9].pak' -o -iname '*.ogg' -o -iname '*.mp3' \
	-o -iname '*.wav' -o -iname '*.flac' -o -type d -iname 'music' \)

.PHONY: help gen build device run check ipa clean

help:
	@echo "make check    -- host-compile + link QuakeCore (no Xcode needed)"
	@echo "make gen      -- regenerate $(PROJECT) from project.yml"
	@echo "make build    -- gen, then build for the visionOS simulator"
	@echo "make device   -- gen, then build for a real Vision Pro"
	@echo "make run      -- build, install and launch on device DETACHED (audio works)"
	@echo "make ipa      -- unsigned $(IPA) for sideloading"
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

# The sideload artifact. Archives Release for a real device with signing off,
# then wraps the product the way an .ipa is defined: Payload/<app> in a zip.
# Unsigned on purpose -- whoever installs it signs with their own team, and a
# build signed with A.'s certificate would only install for A. anyway.
#
# An archive rather than a plain build because the archive's Products tree is
# the install-shaped copy of the app, already stripped of the intermediates a
# DerivedData path carries around.
#
# IPA_EXCLUDES is the mechanism that keeps the dev game data out; the find
# over the payload below is the check that it worked. Shipping someone else's
# game data is the one mistake here that cannot be taken back, so a dirty
# payload fails the target rather than producing a quietly wrong .ipa.
ipa: gen
	rm -rf $(ARCHIVE) $(IPA_DIR) $(IPA)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release \
		-destination '$(DEST)' \
		-archivePath $(ARCHIVE) \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
		$(IPA_EXCLUDES) \
		archive
	mkdir -p $(IPA_DIR)/Payload
	cp -R $(ARCHIVE)/Products/Applications/$(SCHEME).app $(IPA_DIR)/Payload/
	@if find $(IPA_DIR)/Payload $(PAYLOAD_GUARD) | grep -q .; then \
		echo "ipa: REFUSING -- game data in the payload:"; \
		find $(IPA_DIR)/Payload $(PAYLOAD_GUARD); \
		exit 1; \
	fi
	cd $(IPA_DIR) && zip -qry ../$(notdir $(IPA)) Payload
	@echo
	@ls -la $(IPA)

clean:
	rm -rf $(PROJECT) build DerivedData
