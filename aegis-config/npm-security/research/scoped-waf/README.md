# WAF availability candidate

This Linux/amd64 engineering recipe builds the paired NGINX attachment and the NPM policy integration. The image uses the installed `/ext/appsec/local_policy.yaml` at startup and watches for subsequent changes. The running NGINX configuration exposes its revision on a container-local Unix socket. The NPM policy API waits for the selected revision to be active in both the proxy and the agent.

| Installed scope | Normal request | Agent unavailable or requested policy pending |
| --- | --- | --- |
| Prevent | Origin response after inspection. An explicit denial uses the policy response. | HTTP 503 before proxying the request |
| Detect, inactive, unlisted with inactive default | Existing proxy and WAF behaviour | Existing fallback behaviour. The qualified stack expects normal requests to reach the origin |
| NPM management port 81 | Management API | Management API |

Run `build.sh OPEN_APPSEC_NPM_GIT ATTACHMENT_ARCHIVE NEW_OUTPUT` with the reviewed AegisAX/open-appsec-npm checkout and the attachment archive pinned by the script. The verified NPM base must be present in the local Docker daemon. The output `image.id` identifies the candidate to test with the scoped agent. Installations use the signed release through `update.sh` once both images qualify.

The current scope compiler accepts exact DNS names, leading DNS wildcards and the default rule. A policy using an unsupported selector, including a location-specific selector, fails the candidate parser check before the updater stops the installed services. The prevent path requires buffered request bodies. Check streaming routes before qualifying a site that overrides NPM's default request buffering.

Run `tests/waf-cold-start.sh sha256:IMAGE_ID` on the staging Docker host to check startup with private IPC and a loopback origin. The integration probe in `tests/waf-availability.cjs` uses a synthetic proxy host, a benign route explicitly denied by test policy, and unique origin markers. Qualification requires confirmed policy transitions, a request interrupted during body upload, healthy and unavailable results for all three modes, and repeated recovery checks on the exact NPM and agent IDs. Both release workflows also require the four-hour observation for that exact stack.
