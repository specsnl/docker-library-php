# syntax=docker/dockerfile:1
# check=error=true

# Latest version: https://hub.docker.com/r/bats/bats/tags
FROM bats/bats:1.14.0 AS bats

# Debian, for the same GNU tooling (gawk, GNU sed -i) that apply-templates.sh
# relies on in upstream's ubuntu-latest CI.
# Latest version: https://hub.docker.com/_/debian/tags
FROM debian:13.7-slim

COPY --from=bats /opt/bats /opt/bats
COPY --from=bats /usr/lib/bats/bats-support /usr/lib/bats/bats-support
COPY --from=bats /usr/lib/bats/bats-assert /usr/lib/bats/bats-assert
COPY --from=bats /usr/lib/bats/bats-file /usr/lib/bats/bats-file

RUN apt-get update \
    && apt-get install --assume-yes --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gawk \
        jq \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /opt/bats/bin/bats /usr/local/bin/bats

ENTRYPOINT ["bats"]
