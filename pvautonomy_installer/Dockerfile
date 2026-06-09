# Supervisor 2026.04+ no longer injects BUILD_FROM — pin the base image explicitly.
FROM ghcr.io/home-assistant/base:latest

# Tools the installer needs. bashio ships in the HA base image.
RUN apk add --no-cache bash curl jq unzip

COPY run.sh installer.sh /
RUN chmod a+x /run.sh /installer.sh

CMD [ "/run.sh" ]
