# insanitty — convenience targets. Requires swift + zig on PATH (see scripts/setup-dev-env.sh).
SWIFT ?= swift
.PHONY: build test run smoke ghostty-vt clean

build:            ## Build the app shell + spikes
	$(SWIFT) build

test:             ## Run InsanittyCore unit tests
	$(SWIFT) test

run: build        ## Run the app shell (needs a display)
	.build/debug/insanitty

smoke: build      ## Headless smoke: GTK interop + app shell self-quit (CI uses this)
	xvfb-run -a .build/debug/spike-gtk-smoke
	INSANITTY_SMOKE=1 xvfb-run -a .build/debug/insanitty

ghostty-vt:       ## Build the forked Ghostty's libghostty-vt (verifies the engine toolchain)
	./scripts/build-ghostty.sh

clean:
	$(SWIFT) package clean 2>/dev/null || true
	rm -rf .build
