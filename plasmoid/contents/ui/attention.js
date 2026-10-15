// Attention badge helper — shared by the QML widget and its node test.
//
// Turns the tracker's {blocked: [...], turn: [...]} summary (lists of
// {session, project}, longest waiting first) into what the badge and its
// tooltip show. Blocked (a permission prompt or a question) outranks "your
// turn" (a session finished), so one blocked session sets the colour.
//
// Pure and portable: no QML/Plasma APIs, no side effects.

function badgeFor(summary) {
  var blocked = (summary && summary.blocked) || [];
  var turn = (summary && summary.turn) || [];

  var groups = [];
  if (blocked.length) groups.push({ label: "Blocked", sessions: blocked });
  if (turn.length) groups.push({ label: "Done", sessions: turn });

  var count = blocked.length + turn.length;
  var title = count === 0 ? "No sessions waiting on you"
    : count === 1 ? "1 session waiting on you"
    : count + " sessions waiting on you";

  return {
    level: blocked.length ? "blocked" : turn.length ? "turn" : "none",
    count: count,
    title: title,
    groups: groups,
  };
}

// Export for the node test; harmless under QML's JS engine (module is undefined).
if (typeof module !== "undefined" && module.exports) {
  module.exports = { badgeFor };
}
