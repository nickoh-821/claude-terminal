# Vendored SwiftTerm

- Upstream: https://github.com/migueldeicaza/SwiftTerm
- Version: v1.13.0 (revision `8e7a1e154f470e19c709a00a8768df348ba5fc43`)
- Copied: 2026-07-02, verbatim from the SwiftPM checkout of the pinned
  release (`Sources/SwiftTerm` + `LICENSE` only; tests, benchmarks,
  SwiftTermFuzz, Termcast, and the example app are dropped, along with
  their swift-argument-parser and swift-docc-plugin dependencies).
- `Package.swift` is ours (library target only); everything under
  `Sources/` is upstream code except the patches below.

Vendored so the app has zero remote dependencies and so we can carry
local fixes. Diff against the upstream tag before pulling in any
upstream update.

## Local patches

1. **Wire up `Terminal.userScrolling`** (`Apple/AppleTerminalView.swift`,
   `scrollTo(row:notifyAccessibility:)`): upstream declares the flag and
   `Terminal.scroll()` checks it before snapping the viewport to the
   bottom on new output (`buffer.yDisp = buffer.yBase`), but nothing in
   the package ever sets it — so any output stream (e.g. Claude
   responding) makes scrolling up impossible: the view snaps back on
   every new line. The patch sets
   `terminal.userScrolling = row < displayBuffer.yBase` on every
   user-initiated scroll (wheel, scroller, page keys, search reveal),
   which keeps the viewport anchored while scrolled back and re-enables
   follow-output once the user returns to the bottom. Mirrors xterm.js
   (`suppressScrollToBottomOnOutput`) behavior, which this code was
   ported from.

2. **Snap to bottom on keypress** (`Mac/MacTerminalView.swift`,
   `keyDown(with:)`): with patch 1 the viewport stays put while scrolled
   back, so typing needs to bring the prompt back into view first —
   standard Terminal.app/iTerm behavior.

3. **Wheel handling for the alternate screen and mouse-tracking apps**
   (`Mac/MacTerminalView.swift`, `scrollWheel(with:)`): upstream always
   scrolls the view's own scrollback, which is a no-op in the alternate
   buffer (yBase stays 0) — so the wheel was dead in any full-screen TUI,
   including Claude Code, which runs its interface in the alternate
   screen. The patch adds the standard xterm cascade: if the app enabled
   mouse tracking, report the wheel as button 4/5 press events (SGR
   aware, via encodeButton/sendEvent); otherwise, if the alternate buffer
   is active, send arrow-key sequences ("alternate scroll mode" — what
   iTerm and Terminal.app do by default); otherwise scroll the viewport
   as before. Arrow/report bursts are capped at 5 per wheel event.

4. **SGR motion events no longer masquerade as left-button releases**
   (`Terminal.swift`, `sendEvent(buttonFlags:...)`): under any-event
   tracking (mode 1003) a buttonless hover motion is encoded as
   3 (no button) + 32 (motion bit) = 35, but the SGR release check was
   `(buttonFlags & 3) == 3` — true for 35 too — so every hover motion
   went out as `CSI <32;x;y m`, i.e. a left-button mouse-up at the
   hovered cell. Claude Code treated each one as a click: hovering an
   artifact link opened it once per motion event. Now only a non-motion
   3 counts as a release; motion is sent as `CSI <35;x;y M` (xterm
   behavior). Also dropped upstream's stray `print()` in the sgrPixel
   branch.
