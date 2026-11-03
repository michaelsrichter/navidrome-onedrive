ARG NAVIDROME_VERSION
ARG RCLONE_VERSION

FROM navidrome/navidrome:${NAVIDROME_VERSION} AS navidrome
COPY --chown=1000:1000 build/plugins/ /plugins/
COPY licenses/ /usr/share/licenses/navidrome-plugins/
ENV ND_PLUGINS_FOLDER=/plugins
USER 1000:1000

FROM rclone/rclone:${RCLONE_VERSION} AS rclone-sync
USER 1000:1000
