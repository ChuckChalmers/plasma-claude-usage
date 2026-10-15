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

const none = { level: "none", count: 0, title: "No sessions waiting on you", groups: [] };

check("nothing waiting hides the badge", none, badgeFor({ blocked: [], turn: [] }));

check("missing summary hides the badge", none, badgeFor(null));

const a = { session: "a", project: "proj-a" };
const b = { session: "b", project: "proj-b" };
const c = { session: "c", project: "proj-c" };

check("finished sessions show as done",
  { level: "turn", count: 2, title: "2 sessions waiting on you",
    groups: [{ label: "Done", sessions: [a, b] }] },
  badgeFor({ blocked: [], turn: [a, b] }));

check("any blocked session makes the badge blocked, counting everything",
  { level: "blocked", count: 3, title: "3 sessions waiting on you",
    groups: [{ label: "Blocked", sessions: [c] }, { label: "Done", sessions: [a, b] }] },
  badgeFor({ blocked: [c], turn: [a, b] }));

check("a single session reads in the singular",
  { level: "blocked", count: 1, title: "1 session waiting on you",
    groups: [{ label: "Blocked", sessions: [a] }] },
  badgeFor({ blocked: [a], turn: [] }));

console.log("\n" + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
