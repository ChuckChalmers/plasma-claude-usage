// Tests for the staleness helper. Run with: node plasmoid/test_staleness.js
//
// The helper is shared with the QML widget (contents/ui/staleness.js); it must
// stay pure and portable so it runs identically here and in Plasma's JS engine.
"use strict";

const { displayedPercent } = require("./contents/ui/staleness.js");

let pass = 0;
let fail = 0;

function check(name, expected, actual) {
  if (expected === actual) {
    console.log("ok   - " + name);
    pass++;
  } else {
    console.log(`FAIL - ${name}\n        expected: ${expected}\n        actual:   ${actual}`);
    fail++;
  }
}

// now and resets_at are both epoch SECONDS.
const NOW = 1000;

check("below reset: shows used_percentage",
  62, displayedPercent({ used_percentage: 62, resets_at: 2000 }, NOW));

check("past reset: drops to 0",
  0, displayedPercent({ used_percentage: 62, resets_at: 500 }, NOW));

check("exactly at reset: drops to 0 (boundary)",
  0, displayedPercent({ used_percentage: 62, resets_at: 1000 }, NOW));

check("missing resets_at: shows used_percentage (don't blank on bad data)",
  62, displayedPercent({ used_percentage: 62 }, NOW));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
