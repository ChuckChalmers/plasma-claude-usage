// Attention badge helper — shared by the QML widget and its node test.
//
// Turns the tracker's {blocked: [projects], turn: [projects]} summary into what
// the badge shows. Blocked (a permission prompt or a question) outranks "your
// turn" (a session finished), so one blocked session sets the colour.
//
// Pure and portable: no QML/Plasma APIs, no side effects.

function badgeFor(summary) {
  var blocked = (summary && summary.blocked) || [];
  var turn = (summary && summary.turn) || [];

  var lines = [];
  if (blocked.length) lines.push("Blocked: " + blocked.join(", "));
  if (turn.length) lines.push("Done: " + turn.join(", "));

  var count = blocked.length + turn.length;
  var title = count === 0 ? "No sessions waiting on you"
    : count === 1 ? "1 session waiting on you"
    : count + " sessions waiting on you";

  return {
    level: blocked.length ? "blocked" : turn.length ? "turn" : "none",
    count: count,
    title: title,
    tooltip: lines.join("\n"),
  };
}

// Export for the node test; harmless under QML's JS engine (module is undefined).
if (typeof module !== "undefined" && module.exports) {
  module.exports = { badgeFor };
}
