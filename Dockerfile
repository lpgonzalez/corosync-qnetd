# syntax=docker/dockerfile:1.6
# ==============================================================================
#  corosync-qnetd  -  Lightweight QDevice arbitrator for Proxmox VE clusters
# ==============================================================================
#  Built from Debian bookworm-slim with corosync-qnetd + sshd (pubkey-only).
#  Final image size ~120 MB. Multi-arch capable (amd64, arm64, armv7).
# ==============================================================================

FROM debian:bookworm-slim

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
      org.opencontainers.image.base.name="docker.io/library/debian:bookworm-slim"

# --- Install runtime packages -------------------------------------------------
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        corosync-qnetd \
        openssh-server \
        ca-certificates \
        iproute2 \
        procps && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# --- sshd hardening ----------------------------------------------------------
#   - HostKey from persistent volume /etc/ssh/keys (survives rebuilds)
#   - root login ONLY via public key (pvecm qdevice setup needs SSH)
#   - passwords disabled, PAM disabled, challenge-response disabled
RUN sed -i \
    -e 's|^#*HostKey /etc/ssh/ssh_host_rsa_key.*|HostKey /etc/ssh/keys/ssh_host_rsa_key|' \
    -e 's|^#*HostKey /etc/ssh/ssh_host_ecdsa_key.*|HostKey /etc/ssh/keys/ssh_host_ecdsa_key|' \
    -e 's|^#*HostKey /etc/ssh/ssh_host_ed25519_key.*|HostKey /etc/ssh/keys/ssh_host_ed25519_key|' \
    -e 's|^#*PermitRootLogin.*|PermitRootLogin prohibit-password|' \
    -e 's|^#*PasswordAuthentication.*|PasswordAuthentication no|' \
    -e 's|^#*PubkeyAuthentication.*|PubkeyAuthentication yes|' \
    -e 's|^#*ChallengeResponseAuthentication.*|ChallengeResponseAuthentication no|' \
    -e 's|^#*UsePAM.*|UsePAM no|' \
    /etc/ssh/sshd_config

# Lock the root password (login only via authorized public keys)
RUN usermod -p '*' root && \
    mkdir -p /var/run/sshd /etc/corosync/qnetd

EXPOSE 5403/tcp 22/tcp

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ss -ltn | grep -q ':5403' && ss -ltn | grep -q ':22' || exit 1

ENTRYPOINT ["/entrypoint.sh"]
