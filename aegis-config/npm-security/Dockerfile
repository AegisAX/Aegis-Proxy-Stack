ARG ENGINE_IMAGE=aegis-npm:security-candidate
FROM ${ENGINE_IMAGE} AS logging
COPY patch-app-logging.js /tmp/patch-app-logging.js
RUN node /tmp/patch-app-logging.js --apply \
    && node /tmp/patch-app-logging.js --check \
    && node --check /app/setup.js \
    && node --check /app/internal/certificate.js

FROM ${ENGINE_IMAGE}
COPY --from=logging /app/setup.js /app/setup.js
COPY --from=logging /app/internal/certificate.js /app/internal/certificate.js
