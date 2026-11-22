# Retain the entrypoint's upstream gosu version and rebuild its embedded Go stdlib.
FROM docker.io/library/golang@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS gosu-build
WORKDIR /src
RUN set -eu; \
    wget -O /tmp/gosu.tgz https://codeload.github.com/tianon/gosu/tar.gz/6456aaa0f3c854d199d0f037f068eb97515b7513; \
    echo '33d7537d588ea49458b9509bcf4554bdf5ceacc66da71e5caa1058ea3b689c3b  /tmp/gosu.tgz' | sha256sum -c -; \
    tar -xzf /tmp/gosu.tgz --strip-components=1; \
    GOTOOLCHAIN=local go get github.com/moby/sys/user@v0.4.1 golang.org/x/sys@v0.44.0; \
    grep -Fx 'github.com/moby/sys/user v0.4.1 h1:RgjRlaDKi/Xmyrz4t8lyzXT6v2ooFeO/7xtchmhVWE0=' go.sum; \
    grep -Fx 'golang.org/x/sys v0.44.0 h1:ildZl3J4uzeKP07r2F++Op7E9B29JRUy+a27EibtBTQ=' go.sum; \
    go mod verify; \
    CGO_ENABLED=0 GOTOOLCHAIN=local go build -mod=readonly -trimpath -ldflags='-d -w' -o /gosu .; \
    /gosu --version | grep -F '1.19 (go1.27.4'

# MariaDB published 10.11.20 before the corresponding Docker Official Image.
FROM docker.io/library/mariadb@sha256:e5fe75b2b9de0eb9f6f9a4d9c97272fb3a7480e389ccd487a786bab2a12cc0d7

COPY --from=gosu-build /gosu /usr/local/bin/gosu

ENV MARIADB_VERSION=1:10.11.20+maria~ubu2204

# Keep the package postinst's temporary system database out of the runtime image.
RUN --mount=type=tmpfs,target=/var/lib/mysql set -eu; \
    printf '%s\n' 'deb [signed-by=/etc/apt/trusted.gpg.d/mariadb.gpg] https://archive.mariadb.org/mariadb-10.11.20/repo/ubuntu/ jammy main' > /etc/apt/sources.list.d/mariadb.list; \
    rm -rf /var/lib/apt/lists/*; \
    apt-get -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/mariadb.list -o Dir::Etc::sourceparts=- update; \
    set -- /var/lib/apt/lists/*_InRelease; \
    test "$#" -eq 1; \
    echo "b3856f58fa7d9443a48c14a5564b3d09a085cc28f8bd2e44b0fd272b41834435  $1" | sha256sum -c -; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "libmariadb3=${MARIADB_VERSION}" "mariadb-backup=${MARIADB_VERSION}" \
        "mariadb-client=${MARIADB_VERSION}" "mariadb-client-core=${MARIADB_VERSION}" \
        "mariadb-common=${MARIADB_VERSION}" "mariadb-server=${MARIADB_VERSION}" \
        "mariadb-server-core=${MARIADB_VERSION}" "mysql-common=${MARIADB_VERSION}"; \
    mariadbd --version | grep -F '10.11.20-MariaDB'; \
    rm -rf /var/lib/apt/lists/*

RUN test -d /var/lib/mysql && test -z "$(ls -A /var/lib/mysql)"
