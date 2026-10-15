// Tests for the attention badge helper. Run with: node plasmoid/test_attention.js
//
// The helper is shared with the QML widget (contents/ui/attention.js); it must
// stay pure and portable so it runs identically here and in Plasma's JS engine.
"use strict";

const { badgeFor } = require("./contents/ui/attention.js");

let pass = 0;
let fail = 0;

function check(name, expected, actual) {
  const e = JSON.stringify(expected);
  const a = JSON.stringify(actual);
  if (e === a) {
    console.log("ok   - " + name);
    pass++;
  } else {
    console.log("FAIL - " + name + "\n        expected: " + e + "\n        actual:   " + a);
    fail++;
  }
}

check("nothing waiting hides the badge",
  { level: "none", count: 0, title: "No sessions waiting on you", tooltip: "" },
  badgeFor({ blocked: [], turn: [] }));

check("missing summary hides the badge",
  { level: "none", count: 0, title: "No sessions waiting on you", tooltip: "" },
  badgeFor(null));

check("finished sessions show as done",
  { level: "turn", count: 2, title: "2 sessions waiting on you", tooltip: "Done: proj-a, proj-b" },
  badgeFor({ blocked: [], turn: ["proj-a", "proj-b"] }));

check("any blocked session makes the badge blocked, counting everything",
  { level: "blocked", count: 3, title: "3 sessions waiting on you", tooltip: "Blocked: proj-c\nDone: proj-a, proj-b" },
  badgeFor({ blocked: ["proj-c"], turn: ["proj-a", "proj-b"] }));

check("a single session reads in the singular",
  { level: "blocked", count: 1, title: "1 session waiting on you", tooltip: "Blocked: proj-a" },
  badgeFor({ blocked: ["proj-a"], turn: [] }));

console.log("\n" + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
