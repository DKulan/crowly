"""Unit tests for crowly_emit — pure envelope/validation logic, no network.
Run: python3 test_crowly_emit.py  (exit 0 = all pass)."""
import crowly_emit as ce

def check(name, cond):
    print(("PASS" if cond else "FAIL") + " " + name)
    assert cond, name

# build_digest stamps the envelope and never lets the caller set id/version.
d = ce.build_digest({"job_id":"j","title":"T","bottom_line":"b","urgency":"low",
                     "id":"caller-tried","schema_version":99})
check("schema_version stamped, caller override ignored", d["schema_version"] == ce.SCHEMA_VERSION)
check("id stamped (caller's literal id honored)", d["id"] == "caller-tried")
check("created_at present + ISO", ce._parse_iso(d["created_at"]))
check("default source applied", d["source"] == ce.DEFAULT_SOURCE)

# id is stable for identical content, distinct for different content.
a = ce.build_digest({"job_id":"j","title":"T","bottom_line":"b","urgency":"low"})
b = ce.build_digest({"job_id":"j","title":"T","bottom_line":"b","urgency":"low"})
c = ce.build_digest({"job_id":"j","title":"DIFFERENT","bottom_line":"b","urgency":"low"})
check("same content -> same id (idempotent)", a["id"] == b["id"])
check("different content -> different id", a["id"] != c["id"])

# validation rejects what the app's decoder would reject.
for bad, why in [
    ({"title":"T","bottom_line":"b","urgency":"low"}, "missing job_id"),
    ({"job_id":"j","bottom_line":"b","urgency":"low"}, "missing title"),
    ({"job_id":"j","title":"T","urgency":"low"}, "missing bottom_line"),
    ({"job_id":"j","title":"T","bottom_line":"b","urgency":"nope"}, "bad urgency"),
]:
    try:
        ce.build_digest(bad); check("reject: "+why, False)
    except ce.EmitError:
        check("reject: "+why, True)

# unknown fields survive build (passthrough).
d2 = ce.build_digest({"job_id":"j","title":"T","bottom_line":"b","urgency":"low","v2_field":42})
check("unknown field preserved through build", d2.get("v2_field") == 42)

# optional sections/sources shape-checked.
try:
    ce.build_digest({"job_id":"j","title":"T","bottom_line":"b","urgency":"low",
                     "sections":[{"heading":"h"}]}); check("reject malformed section", False)
except ce.EmitError:
    check("reject malformed section", True)

# created_at must be a full datetime — date-only strings are rejected.
# The iOS decoder (CrowlyISO8601.parse) requires a time component, so the
# validator has to refuse a bare date or it'd store something the app can't
# decode. _parse_iso is the predicate validate() consults.
check("_parse_iso rejects date-only '2026-06-29'", not ce._parse_iso("2026-06-29"))
check("_parse_iso rejects empty string",          not ce._parse_iso(""))
check("_parse_iso rejects non-string input",      not ce._parse_iso(None))
check("_parse_iso accepts T-separated datetime",  ce._parse_iso("2026-06-29T19:00:00+00:00"))
check("_parse_iso accepts Z-suffix datetime",     ce._parse_iso("2026-06-29T19:00:00Z"))

# And the full validate() rejects a digest with a date-only created_at.
date_only = {
    "schema_version": 1, "id": "x", "job_id": "j", "source": "test",
    "title": "T", "created_at": "2026-06-29", "urgency": "low",
    "bottom_line": "b",
}
try:
    ce.validate(date_only); check("validate() rejects date-only created_at", False)
except ce.EmitError as e:
    check("validate() rejects date-only created_at",
          "created_at" in str(e))

print("\nall emitter tests passed")
