#!/bin/sh
set -eu

# No systemd/tmpfiles in the container to create sshd's privilege-separation
# dir, so make it.
mkdir -p -m 0755 /run/sshd

# On the cloud path the EFS mount shadows the home dir the Dockerfile set up,
# so /home/agent/.ssh (mkdir'd at build time) isn't there on first boot. Make
# sure it exists with the right perms before anything writes into it. (The EFS
# access point squashes all writes to uid/gid 1001, so the chown is a
# consistency belt-and-braces, harmless on the local path too.)
mkdir -p /home/agent/.ssh
chmod 700 /home/agent/.ssh
chown agent:agent /home/agent/.ssh

# Cloud first-boot seeding. On the local Docker path the agent_home volume is
# seeded from the image (chezmoi already ran at build), so this whole block is
# skipped there — it's gated on SSHD_HOST_KEY_DIR, which only the Fargate task
# definition sets, and on a marker so it's a no-op on later boots. chezmoi owns
# /home/agent; on an empty EFS mount it lays down the dotfiles here instead.
if [ ! -f /home/agent/.seeded-cloud ] && [ -n "${SSHD_HOST_KEY_DIR:-}" ]; then
    if su - agent -c 'chezmoi init --apply kris-steinhoff/dotfiles'; then
        # The shared zshrc only sources zsh-autosuggestions/zsh-syntax-highlighting
        # behind a `type brew` guard that never fires here — they come from apt.
        # The Dockerfile appends this same block for the local path; do it here
        # for the cloud path, where the image's ~/.zshrc is shadowed by EFS.
        cat >> /home/agent/.zshrc <<'ZSHRC'

# apt-installed zsh plugins, sourced last on purpose (see Dockerfile).
for _p in /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
          /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
  [ -r "$_p" ] && source "$_p"
done
unset _p
ZSHRC
        chown agent:agent /home/agent/.zshrc
        touch /home/agent/.seeded-cloud
    else
        echo "entrypoint: cloud seed (chezmoi init) failed; continuing to sshd" >&2
    fi
fi

# sshd host keys. On the cloud path persist them under SSHD_HOST_KEY_DIR (on the
# EFS mount) so known_hosts stays stable across task restarts; generate once,
# then point sshd at them via a drop-in that replaces the default HostKeys.
# Without the env var (local path) keep the original in-image generation.
if [ -n "${SSHD_HOST_KEY_DIR:-}" ]; then
    mkdir -p "$SSHD_HOST_KEY_DIR"
    chmod 700 "$SSHD_HOST_KEY_DIR"
    if ! ls "$SSHD_HOST_KEY_DIR"/ssh_host_*_key >/dev/null 2>&1; then
        ssh-keygen -A >/dev/null
        cp -p /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub "$SSHD_HOST_KEY_DIR"/
    fi
    chmod 600 "$SSHD_HOST_KEY_DIR"/ssh_host_*_key
    for k in "$SSHD_HOST_KEY_DIR"/ssh_host_*_key; do
        printf 'HostKey %s\n' "$k"
    done > /etc/ssh/sshd_config.d/host-keys.conf
else
    ssh-keygen -A >/dev/null
fi

# authorized_keys. On the cloud path it arrives as $AUTHORIZED_KEYS (injected
# from the SSM parameter via the task def's `secrets`); write it in. Otherwise
# fall back to the read-only mount used by the local Docker path.
if [ -n "${AUTHORIZED_KEYS:-}" ]; then
    printf '%s\n' "$AUTHORIZED_KEYS" > /home/agent/.ssh/authorized_keys
    chown agent:agent /home/agent/.ssh/authorized_keys
    chmod 600 /home/agent/.ssh/authorized_keys
elif [ -f /run/agent-container/authorized_keys ]; then
    # The mount is owned by whatever UID it has on the host, which fails sshd's
    # StrictModes check — copy it in and fix ownership/perms instead of mounting
    # straight into ~/.ssh.
    cp /run/agent-container/authorized_keys /home/agent/.ssh/authorized_keys
    chown agent:agent /home/agent/.ssh/authorized_keys
    chmod 600 /home/agent/.ssh/authorized_keys
fi

# If docker-compose.local.yml bind-mounts the host's docker.sock in (see
# docker-compose.local.yml.example), it arrives owned by whatever uid/gid the
# host-side socket has, which `agent` doesn't belong to. chmod (not chown —
# this is a bind mount, so it changes the host-side socket's mode too) so
# `agent` can use `docker` without sudo.
if [ -S /var/run/docker.sock ]; then
    chmod 666 /var/run/docker.sock
fi

# Cloud path: sshd in the background, idle-monitor in the foreground as PID 1's
# child so its exit stops the task. Local path: sshd stays the foreground
# process, exactly as before.
if [ "${IDLE_MONITOR:-}" = "1" ]; then
    /usr/sbin/sshd -e
    exec /usr/local/bin/idle-monitor.sh
else
    exec /usr/sbin/sshd -D -e
fi
