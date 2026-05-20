#!/bin/sh
set -e

# ------------------------------------------------------------------------------
# Init-on-empty para volumenes persistentes.
# ------------------------------------------------------------------------------

# Host keys SSH persistentes (sobreviven a rebuilds de la imagen)
mkdir -p /etc/ssh/keys
if [ -z "$(ls -A /etc/ssh/keys 2>/dev/null)" ]; then
    echo "[qnetd] Generando host keys SSH persistentes..."
    ssh-keygen -t rsa     -b 4096 -f /etc/ssh/keys/ssh_host_rsa_key     -N "" -q
    ssh-keygen -t ecdsa           -f /etc/ssh/keys/ssh_host_ecdsa_key   -N "" -q
    ssh-keygen -t ed25519         -f /etc/ssh/keys/ssh_host_ed25519_key -N "" -q
fi

# authorized_keys: bind mount of ./configs/ssh-authorized-keys onto /root/.ssh.
# Force root:root ownership: the file is often uploaded via SMB/NFS with a
# non-root UID, and sshd with StrictModes would silently reject it.
mkdir -p /root/.ssh
chown -R root:root /root/.ssh
chmod 700 /root/.ssh
if [ -f /root/.ssh/authorized_keys ]; then
    chmod 600 /root/.ssh/authorized_keys
fi
# /root must also be owned by root and not group/world-writable
chown root:root /root
chmod 750 /root

# If someone deployed the example file without renaming it, hint loudly.
if [ ! -f /root/.ssh/authorized_keys ] && [ -f /root/.ssh/authorized_keys.example ]; then
    echo "[qnetd] WARNING: authorized_keys.example present but authorized_keys is missing."
    echo "[qnetd]          'pvecm qdevice setup' will fail with Permission denied."
    echo "[qnetd]          Copy authorized_keys.example to authorized_keys and add real pubkeys."
fi

# NSS DB del qnetd (lo que pvecm qdevice setup va a popular)
if [ -z "$(ls -A /etc/corosync/qnetd/nssdb 2>/dev/null)" ]; then
    echo "[qnetd] Inicializando NSS DB en /etc/corosync/qnetd/nssdb..."
    corosync-qnetd-certutil -i
fi

# Arrancar sshd en background (solo si hay authorized_keys configurado;
# si no, se arranca igual y el primer 'pvecm qdevice setup' fallara con
# permission denied, que es un mensaje claro para el operador)
echo "[qnetd] Arrancando sshd..."
/usr/sbin/sshd

echo "[qnetd] Arrancando corosync-qnetd en foreground..."
exec corosync-qnetd -f
