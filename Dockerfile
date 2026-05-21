# syntax=docker/dockerfile:1.6
# ==============================================================================
#  corosync-qnetd  -  Lightweight QDevice arbitrator for Proxmox VE clusters
# ==============================================================================
#  Built from Debian 13-slim (trixie) with corosync-qnetd + sshd (pubkey-only).
#  Final image size ~120 MB. Multi-arch capable (amd64, arm64, armv7).
# ==============================================================================

FROM debian:13-slim

# --- Build-time metadata (populated by Makefile / CI) ------------------------
ARG VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

# --- OCI image labels --------------------------------------------------------
LABEL org.opencontainers.image.title="corosync-qnetd" \
      org.opencontainers.image.description="Lightweight corosync-qnetd QDevice arbitrator for Proxmox VE 2-node high-availability clusters. Provides external quorum vote via SSH-bootstrapped NSS certificate." \
      org.opencontainers.image.authors="Lisardo Prieto <lisardo.prieto.gonzalez@gmail.com>" \
      org.opencontainers.image.vendor="Lisardo Prieto" \
      org.opencontainers.image.source="https://github.com/lpgonzalez/corosync-qnetd-docker" \
      org.opencontainers.image.url="https://hub.docker.com/r/lpgonzalez/corosync-qnetd" \
      org.opencontainers.image.documentation="https://github.com/lpgonzalez/corosync-qnetd-docker#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="docker.io/library/debian:13-slim"

# --- Install runtime packages -------------------------------------------------
# 1. apt-get upgrade BEFORE install: applies every security update available
#    in the Debian point-release at build time. This is what cuts the bulk
#    of "high/critical" CVEs reported by Docker Scout — they are almost
#    always upstream-fixed packages that the base image snapshot hasn't
#    picked up yet.
# 2. Combined into a single RUN to keep the layer small.
# 3. Trim docs/man pages on cleanup to shave a few MB.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        corosync-qnetd \
        openssh-server \
        ca-certificates \
        iproute2 \
        procps && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* \
           /var/cache/apt/archives/*.deb \
           /usr/share/doc/* \
           /usr/share/man/* \
           /usr/share/info/*

# --- sshd hardening (drop-in) ------------------------------------------------
#   - HostKey from persistent volume /etc/ssh/keys (survives rebuilds)
#   - root login ONLY via public key (pvecm qdevice setup needs SSH)
#   - passwords disabled, PAM disabled, keyboard-interactive disabled
# Written as a drop-in instead of editing sshd_config in place. sshd Includes
# /etc/ssh/sshd_config.d/*.conf near the TOP of sshd_config and applies the
# FIRST value seen for each keyword, so a low-numbered drop-in overrides the
# stock defaults below it WITHOUT depending on their exact wording — which
# drifts across Debian/OpenSSH releases (e.g. ChallengeResponseAuthentication
# was renamed to KbdInteractiveAuthentication). Specifying HostKey here also
# disables sshd's built-in default host keys, so only the persistent ones load.
COPY <<'EOF' /etc/ssh/sshd_config.d/00-qnetd-hardening.conf
# Managed by the corosync-qnetd image. Do not edit inside the container.
HostKey /etc/ssh/keys/ssh_host_rsa_key
HostKey /etc/ssh/keys/ssh_host_ecdsa_key
HostKey /etc/ssh/keys/ssh_host_ed25519_key
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
EOF

# Lock the root password (login only via authorized public keys)
RUN usermod -p '*' root && \
    mkdir -p /var/run/sshd /etc/corosync/qnetd

EXPOSE 5403/tcp 22/tcp

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ss -ltn | grep -q ':5403' && ss -ltn | grep -q ':22' || exit 1

ENTRYPOINT ["/entrypoint.sh"]
