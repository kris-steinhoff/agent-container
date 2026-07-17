FROM node:24-trixie-slim

# node:24-trixie-slim doesn't ship the ca-certificates package, so
# update-ca-certificates doesn't exist yet — install it (and everything else)
# before touching the trust store below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        openssh-server \
        sudo \
        zsh \
        direnv \
        ripgrep \
        fd-find \
        bat \
        fzf \
        less \
        unzip \
        xz-utils \
        build-essential \
        python3 \
        python3-venv \
        python3-pip \
        locales \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && locale-gen \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat

ENV LANG=en_US.UTF-8

# Corporate TLS-inspecting proxies (Zscaler, Netskope, etc.) re-sign HTTPS with
# a private root CA the container doesn't trust, so every curl/npm/git fetch
# below fails cert verification. Drop that root (or bundle) as one or more
# *.crt files into ./certs/ and it gets added to the trust store here, before
# any of the curl-based installs further down.
# ./certs/ ships empty (just .gitkeep), so off-corp-network builds are a no-op.
# NODE_EXTRA_CA_CERTS makes node/npm honor it too — node ignores the system
# store otherwise, at build time and for claude/opencode at runtime.
COPY certs/ /usr/local/share/ca-certificates/extra/
RUN update-ca-certificates
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
# pip ships its own CA bundle (certifi) and ignores the system trust store, so
# Mason's PyPI installs (ruff, ty) fail TLS on a MITM network unless pointed at
# the system bundle. No-op off-corp — it's the standard bundle either way.
ENV PIP_CERT=/etc/ssl/certs/ca-certificates.crt
ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# Debian's apt doesn't carry gh; pull from GitHub's own apt repo per its
# official install docs (https://github.com/cli/cli/blob/trunk/docs/install_linux.md).
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# GitLab's glab isn't in Debian/apt either. It ships pre-built release tarballs
# on gitlab.com; resolve the latest tag via the API and pull the matching arch
# binary (bin/glab inside the tarball). uname -m for the same reason as nvim below.
RUN arch=$(case "$(uname -m)" in aarch64) echo arm64 ;; *) echo amd64 ;; esac) \
    && tag=$(curl -fsSL "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4) \
    && ver=${tag#v} \
    && curl -fsSLo /tmp/glab.tar.gz "https://gitlab.com/gitlab-org/cli/-/releases/${tag}/downloads/glab_${ver}_linux_${arch}.tar.gz" \
    && tar -C /tmp -xzf /tmp/glab.tar.gz \
    && mv /tmp/bin/glab /usr/local/bin/glab \
    && rm -rf /tmp/glab.tar.gz /tmp/bin

# Neovim's Debian/apt build lags releases by a lot; the dotfiles' lazy-lock.json
# and treesitter setup expect a current release, so pull the GitHub binary.
# uname -m (not TARGETARCH) since that ARG only gets auto-populated by
# BuildKit — silently empty otherwise, defaulting to the wrong arch.
RUN arch=$(case "$(uname -m)" in aarch64) echo arm64 ;; *) echo x86_64 ;; esac) \
    && curl -fsSLo /tmp/nvim.tar.gz "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${arch}.tar.gz" \
    && tar -C /opt -xzf /tmp/nvim.tar.gz \
    && mv /opt/nvim-linux-${arch} /opt/nvim \
    && ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim \
    && rm /tmp/nvim.tar.gz

RUN BINDIR=/usr/local/bin sh -c "$(curl -fsLS get.chezmoi.io)"

RUN curl -fsSL https://starship.rs/install.sh | sh -s -- --yes

RUN npm install -g @anthropic-ai/claude-code opencode-ai tree-sitter-cli @github/copilot @openai/codex \
    && npm cache clean --force

RUN useradd -m -s /usr/bin/zsh agent \
    && echo 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent \
    && mkdir -p /home/agent/.ssh \
    && chmod 700 /home/agent/.ssh \
    && chown -R agent:agent /home/agent/.ssh

COPY sshd_config /etc/ssh/sshd_config.d/agent-container.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

# herdr installs into the invoking user's home dir, and chezmoi apply runs
# run_once_bootstrap.sh (which skips the brew step here since brew isn't
# installed) to lay down dotfiles and pre-fetch the pinned nvim plugins.
USER agent
WORKDIR /home/agent
RUN curl -fsSL https://herdr.dev/install.sh | sh
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/home/agent/.local/bin:${PATH}"
# The uv installer above writes a fresh ~/.zshrc to wire up its PATH shim;
# drop it so chezmoi's bootstrap can lay one down without prompting
# interactively (PATH is already set via ENV, so nothing is lost).
RUN rm -f /home/agent/.zshrc
RUN chezmoi init --apply kris-steinhoff/dotfiles

USER root
EXPOSE 22
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
