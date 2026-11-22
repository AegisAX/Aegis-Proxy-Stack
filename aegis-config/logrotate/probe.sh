#!/bin/sh
# Feed this script to a fresh, unmounted candidate using docker run -i --entrypoint sh IMAGE -s.
set -eu
export LC_ALL=C
config=/usr/local/etc/aegis/logrotate.conf
target=/var/log/target
[ -f /.dockerenv ] && [ ! -e "$target" ] && [ ! -L "$target" ] || {
    echo 'The probe requires a new Docker container with no existing log target' >&2
    exit 1
}
/usr/local/sbin/aegis-check-logrotate
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$target/npm" "$target/waf"

for service in npm waf; do
    active="$target/$service/aegis-probe.log"
    printf 'Aegis %s rotation probe\nsecond line for %s\n' "$service" "$service" > "$work/$service.expected"
    cp "$work/$service.expected" "$active"
    stat -c '%i' "$active" > "$work/$service.inode"
done

/usr/sbin/logrotate --force --state "$work/state" "$config"
for service in npm waf; do
    active="$target/$service/aegis-probe.log"
    [ -f "$active" ] && [ ! -s "$active" ] &&
        [ "$(stat -c '%i' "$active")" = "$(cat "$work/$service.inode")" ] || {
        echo "$service active log failed copytruncate verification" >&2
        exit 1
    }
    set -- "$target/$service"/aegis-probe*.gz
    [ "$#" = 1 ] && [ -f "$1" ] || { echo "$service has no unique gzip archive" >&2; exit 1; }
    gzip -t "$1"
    gzip -dc "$1" > "$work/$service.restored"
    cmp "$work/$service.expected" "$work/$service.restored" >/dev/null ||
        { echo "$service archive content mismatch" >&2; exit 1; }
done
printf '%s\n' 'Verified copytruncate and gzip contents for both NPM and WAF log rules'
