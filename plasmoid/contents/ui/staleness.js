// Staleness helper — shared by the QML widget and its node test.
//
// The cache only updates while Claude Code runs, so a stored percentage goes
// stale between sessions. But the cache carries resets_at per window, which
// tells us when the stored number stops being true: once a window's reset time
// has passed, its usage has reset, so we display 0% even without a fresh
// payload. This is display-only — the widget never writes the cache back.
//
// Pure and portable: no QML/Plasma APIs, no side effects. `now` and
// `resets_at` are both epoch SECONDS and must share that unit at the call site.

function displayedPercent(window, now) {
  if (!window.resets_at) {
    return window.used_percentage; // no reset info: trust the stored value
  }
  if (now >= window.resets_at) {
    return 0; // window has reset
  }
  return window.used_percentage;
}

// Export for the node test; harmless under QML's JS engine (module is undefined).
if (typeof module !== "undefined" && module.exports) {
  module.exports = { displayedPercent };
}
