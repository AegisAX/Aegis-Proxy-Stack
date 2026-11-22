#!/usr/bin/env bash
set -euo pipefail

image=${1:?Pass the local NPM candidate image to test}
id=$(docker image inspect --format '{{.Id}}' "$image")
password=$(openssl rand -hex 20)
container=$(docker run --pull never --network none -d \
    --mount type=volume,dst=/ext/appsec --mount type=volume,dst=/etc/letsencrypt \
    -e INITIAL_ADMIN_EMAIL=fixture@example.test -e INITIAL_ADMIN_PASSWORD="$password" \
    -e IP_RANGES_FETCH_ENABLED=false -e DISABLE_IPV6=true "$id")
trap 'docker rm -fv "$container" >/dev/null' EXIT

# All API requests, the temporary private key and the SQLite database stay in the fixture.
docker exec -i "$container" bash -euo pipefail <<'FIXTURE'
api=http://127.0.0.1:81/api
for ((i=0; i<60; i++)); do
    if curl -fsS --max-time 2 "$api/" 2>/dev/null | jq -es 'length == 1 and .[0].status == "OK"' >/dev/null; then break; fi
    sleep 1
done
token=$(jq -nc '{identity:env.INITIAL_ADMIN_EMAIL,secret:env.INITIAL_ADMIN_PASSWORD}' |
    curl -fsS --max-time 10 -H 'Content-Type: application/json' --data-binary @- "$api/tokens" | jq -er .token)
auth="Authorization: Bearer $token"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=fixture.example.test \
    -out /tmp/fixture.crt -keyout /tmp/fixture.key 2>/dev/null
cert=$(curl -fsS --max-time 15 -H "$auth" -H 'Content-Type: application/json' \
    -d '{"provider":"other","nice_name":"fixture"}' "$api/nginx/certificates" | jq -er .id)
curl -fsS --max-time 15 -H "$auth" -F 'certificate=@/tmp/fixture.crt' \
    -F 'certificate_key=@/tmp/fixture.key' "$api/nginx/certificates/$cert/upload" |
    jq -e 'has("certificate")' >/dev/null
FIXTURE

fragment=$(docker exec "$container" sed -n '2p' /tmp/fixture.key)
[[ -n $fragment ]]
logs=$(docker logs "$container" 2>&1)
if [[ $logs == *"$password"* || $logs == *'PRIVATE KEY-----'* || $logs == *"$fragment"* ]]; then
    printf 'FAIL: a fixture credential was written to the NPM logs.\n' >&2
    exit 1
fi
printf 'PASS: administrator initialization and certificate upload completed without logging fixture credentials.\n'
