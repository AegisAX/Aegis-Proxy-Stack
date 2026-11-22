def epoch:
  sub("\\+00:00$"; "Z") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def archived:
  (.npm | type == "number" and . >= 1) and (.waf | type == "number" and . >= 1);

.phase == "complete" and .cleanup == "complete" and (.samples | type == "number" and . >= 228) and
((.ended_at | epoch) - (.started_at | epoch) >= 14400) and
((.scheduled_archives | archived) or
  (.log_scheduler | .phase == "complete" and .schedule == "0 0 * * *" and
    .image_id == $manifest[0].images["log-rotator"].target_id and (.archives | archived))) and
(.images | .["log-rotator"] = .log | del(.log)) ==
($manifest[0].images | map_values(.target_id))
