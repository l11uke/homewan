# ntopng from ntop's official packages for Raspberry Pi OS (Debian 13, arm64).
# ntop publishes only recent builds, so this installs the newest one;
# "homewan status" shows the version in use.
FROM debian:trixie-slim

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates wget gnupg lsb-release; \
    wget -q -O /tmp/apt-ntop.deb https://packages.ntop.org/RaspberryPI/apt-ntop.deb; \
    dpkg -i /tmp/apt-ntop.deb || apt-get -f install -y; \
    apt-get update; \
    apt-get install -y --no-install-recommends ntopng; \
    ntopng --version | head -1 > /etc/ntopng-version; \
    rm -rf /var/lib/apt/lists/* /tmp/apt-ntop.deb

# Runs as root inside the container (--dont-change-user): packet capture
# needs it, and the container only has NET_ADMIN and NET_RAW added.
ENTRYPOINT ["ntopng"]
