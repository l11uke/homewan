# homewan tools: speedtest, drive health and (later) the weekly report.
FROM python:3.13-slim-trixie

# Ookla's official speedtest CLI from Ookla's signed apt repository,
# and smartmontools for drive health.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg smartmontools; \
    curl -fsSL https://packagecloud.io/ookla/speedtest-cli/gpgkey | gpg --dearmor -o /usr/share/keyrings/ookla.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/ookla.gpg] https://packagecloud.io/ookla/speedtest-cli/debian/ trixie main" > /etc/apt/sources.list.d/ookla.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends speedtest; \
    apt-get purge -y gnupg; apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && rm /tmp/requirements.txt

COPY homewan_tools /app/homewan_tools
WORKDIR /app
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "-m", "homewan_tools"]
