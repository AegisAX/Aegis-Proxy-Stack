def epoch:
  sub("\\+00:00$"; "Z") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;

.phase == "complete" and .cleanup == "complete" and .samples >= 2736 and
((.ended_at | epoch) - (.started_at | epoch) >= 172800) and
.scheduled_archives.npm >= 1 and .scheduled_archives.waf >= 1 and
(.images | .["log-rotator"] = .log | del(.log)) ==
($manifest[0].images | map_values(.target_id))
