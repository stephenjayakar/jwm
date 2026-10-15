.PHONY: build run restore app install restart signing-cert clean

# Sign with the local self-signed identity if it exists (keeps the Accessibility grant across
# rebuilds), else ad-hoc. Create it once with `make signing-cert`.
SIGN_KC := $(HOME)/Library/Keychains/jwm-signing.keychain-db
SIGN_ID := $(shell security find-identity -p codesigning $(SIGN_KC) 2>/dev/null | awk '/jwm Local Signing/ {print $$2; exit}')
ifneq ($(SIGN_ID),)
SIGN := --sign $(SIGN_ID) --keychain $(SIGN_KC)
else
SIGN := --sign -
endif

build:
	swift build -c release

# Run from a terminal that has Accessibility permission (it inherits the terminal's grant).
run: build
	.build/release/jwm

# Bring back windows left offscreen if jwm crashed.
restore: build
	.build/release/jwm --restore

# Standalone app bundle. Ad-hoc signed builds need Accessibility re-granted after each rebuild.
app: build
	rm -rf jwm.app
	mkdir -p jwm.app/Contents/MacOS
	cp .build/release/jwm jwm.app/Contents/MacOS/jwm
	cp Info.plist jwm.app/Contents/Info.plist
	security unlock-keychain -p jwm $(SIGN_KC) 2>/dev/null || true
	codesign --force $(SIGN) jwm.app

# Replace /Applications/jwm.app. A running jwm keeps the old binary until you relaunch it.
install: app
	rm -rf /Applications/jwm.app
	ditto jwm.app /Applications/jwm.app

# Install, then restart the running jwm. SIGHUP quits without bringing hidden windows back, so the
# new jwm picks up the screen as it is. Waits up to 5 s for the old one to exit.
restart: install
	@if pgrep -x jwm >/dev/null; then \
		pkill -HUP -x jwm; \
		for i in $$(seq 1 50); do pgrep -x jwm >/dev/null || break; sleep 0.1; done; \
		if pgrep -x jwm >/dev/null; then echo "jwm did not quit; not starting a second one"; exit 1; fi; \
	fi
	open /Applications/jwm.app
	@for i in $$(seq 1 30); do pgrep -x jwm >/dev/null && break; sleep 0.1; done
	@if pgrep -x jwm >/dev/null; then echo "jwm restarted (pid $$(pgrep -x jwm))"; \
	else echo "jwm did not start; run: open -n /Applications/jwm.app --args --restore"; exit 1; fi

signing-cert:
	./scripts/make-signing-cert.sh

clean:
	rm -rf .build jwm.app
