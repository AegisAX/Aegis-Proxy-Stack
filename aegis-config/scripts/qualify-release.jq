def epoch:
  sub("\\+00:00$"; "Z") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def archived:
  (.npm | type == "number" and . >= 1) and (.waf | type == "number" and . >= 1);

# Each HTTP sample records the client response and the origin's count for its unique marker.
def expected_waf_sample($phase):
  [ ["prevent","detect","off"][] as $host | ["GET","POST"][] as $method |
    ($host == "prevent" and ($phase == "cold" or $phase == "unavailable")) as $held |
    {host:$host, method:$method, path:"/health-probe",
     status:(if $held then 503 else 200 end), visits:(if $held then 0 else 1 end)} ] +
  (if $phase == "cold" then [] else
    [{host:"prevent", method:"GET", path:"/policy-deny-probe",
      status:(if $phase == "unavailable" then 503 else 403 end), visits:0}]
   end) | sort;

def verified_waf_samples($phase; $minimum):
  [.samples[] | select(.scenario == $phase)] |
  length >= $minimum and all(.[]; (.rows | sort) == expected_waf_sample($phase));

def waf_available:
  .waf_availability as $w |
  ($w.schema == 1 and $w.policy_source == "installed" and
   $w.images == (.images | {agent,npm}) and
   $w.body_interruption == {status:503, visits:0} and
   (($w.policy_change.prevent == 200 or $w.policy_change.prevent == 201) and
    $w.policy_change.detect == 200 and $w.policy_change.pending_checked == true and
    $w.policy_change.restored == true and
    ($w.policy_change.connected_workers | type == "number" and . > 0 and floor == .) and
    ($w.policy_change.rechecks | type == "array" and length >= 1 and
      all(.[]; .prevent == 200 and .detect == 200))) and
   ($w | verified_waf_samples("cold"; 1) and verified_waf_samples("ready"; 1) and
         verified_waf_samples("unavailable"; 1) and verified_waf_samples("recovered"; 2)));

waf_available and .phase == "complete" and .cleanup == "complete" and (.samples | type == "number" and . >= 228) and
((.ended_at | epoch) - (.started_at | epoch) >= 14400) and
((.scheduled_archives | archived) or
  (.log_scheduler | .phase == "complete" and .schedule == "0 0 * * *" and
    .image_id == $manifest[0].images["log-rotator"].target_id and (.archives | archived))) and
(.images | .["log-rotator"] = .log | del(.log)) ==
($manifest[0].images | map_values(.target_id))
