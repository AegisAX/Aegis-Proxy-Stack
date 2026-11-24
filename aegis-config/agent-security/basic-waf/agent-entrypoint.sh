#!/bin/sh
set -eu
case "${1:-}" in
    /cp-nano-agent)
        for arg in "$@"; do
            if [ "$arg" = --standalone ]; then
                /usr/local/bin/aegis-agent-scope-ack &
                break
            fi
        done
        ;;
esac
exec "$@"
