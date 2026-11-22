length == 1 and (.[0] |
  .schema_version == 1 and .channel == $channel and
  .from_version == $version and
  ($revision | test("^[a-f0-9]{40}$")) and .from_commit == $revision and
  (.release | test("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$")) and
  (.resolved_cves | type == "array" and
    all(.[]; test("^CVE-[0-9]{4}-[0-9]{4,}$"))) and
  ($channel != "security" or (.resolved_cves | length > 0)) and
  (.images | type == "object" and length > 0 and all(to_entries[];
    (.key | test("^[a-zA-Z0-9][a-zA-Z0-9_-]*$")) and
    (.value.from_id | test("^sha256:[a-f0-9]{64}$")) and
    (.value.target | test("^[a-z0-9][a-z0-9./:_-]*@sha256:[a-f0-9]{64}$")))) and
  (if has("strategy") then
    .strategy == "stack-v1" and
    (.images | keys == ["agent", "db", "log-rotator", "npm"]) and
    all(.images[]; (.target_id | type == "string" and test("^sha256:[a-f0-9]{64}$")))
  else true end))
