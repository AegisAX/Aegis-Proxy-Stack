FROM docker.io/library/alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f

RUN apk upgrade --no-cache \
    && apk add --no-cache logrotate tzdata \
    && mkdir -p /usr/local/etc/aegis /usr/local/sbin \
    && chmod 0755 /usr/local/etc /usr/local/etc/aegis /usr/local/sbin \
    && rm -f /etc/periodic/daily/logrotate \
    && printf '%s\n' '0 0 * * * /usr/sbin/logrotate -v /usr/local/etc/aegis/logrotate.conf' >> /etc/crontabs/root

COPY --chown=0:0 --chmod=0644 aegis-rotate.conf /usr/local/etc/aegis/logrotate.conf
COPY --chown=0:0 --chmod=0755 aegis-check-logrotate /usr/local/sbin/aegis-check-logrotate
RUN /usr/local/sbin/aegis-check-logrotate

HEALTHCHECK --interval=60s --timeout=15s --start-period=5s --retries=3 CMD ["/usr/local/sbin/aegis-check-logrotate", "--health"]
CMD ["crond", "-f", "-l", "8"]
