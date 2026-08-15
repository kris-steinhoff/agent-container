# agent-container

A Debian-based container for running Claude Code / opencode isolated from the host, attached to with [herdr](https://herdr.dev) over SSH. Runs locally for now; moving it to a remote host later is a matter of changing the SSH target, not the image.

Ships: `claude`, `opencode`, `copilot`, `codex`, `neovim` (latest release), `gh`, `glab`, `uv`, `chezmoi` (applies this dotfiles repo on build), and `sshd` so herdr can attach to a persistent session inside the container.

## First-time setup

Authorize an existing key to log in as `agent`. If your keys live in an SSH agent (1Password's SSH agent, `ssh-agent`, etc.) rather than as files under `~/.ssh`, get the public key from the agent instead of `cat`-ing a file that may not exist:

```sh
ssh-add -L
```

Pick the line for the key you want to use and write it to `authorized_keys` (a dedicated key is best, if you have one — this never needs your general personal key):

```sh
echo 'ssh-ed25519 AAAA... key-comment' > authorized_keys
```

(gitignored via the repo's root `.gitignore` and kept out of the image via `.dockerignore` regardless.)

The `Host agent-container` entry that herdr (and plain `ssh`) needs lives in `ssh_config` next to this README — this is the file to edit when you move to a remote host later (just change `HostName`). Pull it into your real SSH config with an `Include`, added near the top of `~/.ssh/config` since `Include` is processed in place and `ssh_config` uses first-match-wins:

```
# ~/.ssh/config
Include ~/.config/kris-steinhoff/agent-container/ssh_config
```

`ForwardAgent yes` in that entry lets git inside the container use your host's ssh-agent for clone/push over SSH, without ever putting a private key in the image.

## Behind a TLS-inspecting proxy

Corporate proxies that re-sign HTTPS with a private root CA break every `curl`/`apt`/`npm`/`git` fetch in the build (and `claude`/`opencode` at runtime), since the container doesn't trust that root. Drop the root (or bundle) into `certs/` as a `*.crt` (PEM) file and the build adds it to the container trust store:

```sh
cp /path/to/corp-root-ca.pem certs/corp.crt
```

`certs/` ships empty, so this is a no-op off-network. Real certs are gitignored and stay out of the repo.

## Build and run

```sh
docker compose build
docker compose up -d
herdr --remote agent-container
```

### Keeping the fast-moving tools current

`claude`, `copilot`, `codex`, `herdr`, and `bd` sit below a cache gate at the bottom of the Dockerfile so they can reinstall without busting the expensive base layers (apt, neovim, chezmoi plugin pre-fetch). The gate is the `TOOLS_REFRESH` build arg: change its value and only those tools rebuild. A plain build defaults it to `0`, which reuses the cache. `./up` passes a fresh timestamp and forces a recreate so those tools track latest on every run:

```sh
./up
```

Equivalent to `TOOLS_REFRESH=$(date +%s) docker compose up -d --build --force-recreate` — the `--force-recreate` guarantees a fresh container even in the (normally unlikely) case Compose's own change detection wouldn't otherwise trigger one. Everything else (including `opencode`, `neovim`, `terraform`, `gh`, `glab`) stays cached until you edit the Dockerfile or build with `--no-cache`.

`herdr --remote` installs herdr on the container the first time it connects and gives you a persistent session — detach and reattach freely, and it survives your local terminal closing.

## Credentials

Not baked into the image. Either:

- Run `claude` / `opencode` inside the container once and complete the normal interactive login, which persists in the `agent_home` volume, or
- Set `ANTHROPIC_API_KEY` / `OPENCODE_API_KEY` in the shell before `docker compose up` (compose reads them from the environment; see `docker-compose.yml`).

`gh` needs its own login too — `gh auth login` inside the container (persists in `agent_home`), separate from the `ForwardAgent`-based git-over-SSH access. `glab` is the same story — `glab auth login` for GitLab access.

## Persistence

`agent_home` is a named volume mounted at `/home/agent` — it's seeded from the image on first start (dotfiles, herdr, nvim plugins already installed) and then persists auth tokens, shell history, and anything else you don't mount separately across `docker compose restart`/`down`+`up`. `docker compose down -v` deletes it. Being a named volume, it's opaque to the host — there's no path on the Mac side to open a file an agent created in there.

`ssh_host_keys` persists the sshd host keys across rebuilds so your local `known_hosts` doesn't need updating every time you rebuild the image.

To work on a project, bind-mount it in — see the commented example in `docker-compose.yml`. Anything not mounted only exists in `agent_home`.

### Bind-mounting `/home/agent/code`

If an agent needs to hand you something you can open directly — a drawio diagram, a screenshot, any artifact you want in a normal Finder/editor path — bind-mount a subdirectory to a real directory on the host, alongside (not replacing) `agent_home`. Dotfiles, shell history, and tool caches stay in the named volume as normal; only what lives under `/home/agent/code` becomes a real path on the Mac. This is a per-machine choice (the path only makes sense on the machine it points at), so it's wired up through two gitignored files rather than edited into `docker-compose.yml` directly:

- **`docker-compose.local.yml`** — a compose override, merged in on top of `docker-compose.yml`. Copy the tracked template and adjust the path if you don't want it next to the repo:

  ```sh
  cp docker-compose.local.yml.example docker-compose.local.yml
  ```

  Compose adds this as a second, independent mount (different target path from `agent_home`'s `/home/agent`) — nothing else in `docker-compose.yml` needs to change.

- **`.envrc`** ([direnv](https://direnv.net/)) — so `docker compose` picks `docker-compose.local.yml` up automatically instead of needing `-f` on every invocation. Copy the tracked template (it also sets `AGENT_UID`, covered below — harmless to leave in even if you skip that part):

  ```sh
  cp .envrc.example .envrc
  ```

  Run `direnv allow` once after creating it.

#### Migrating existing `/home/agent/code` content

Skip this if you've never put anything at `/home/agent/code` — just create the empty local directory and move on. Otherwise, do this before switching `.envrc`/`docker-compose.local.yml` on, so `docker compose` here still resolves against the named-volume config:

```sh
docker compose down                 # stops the container, keeps the volume
mkdir -p ./agent_code               # or wherever docker-compose.local.yml points
vol=$(docker compose config --format json | jq -r '.volumes.agent_home.name')

docker run --rm \
  -v "$vol":/from \
  -v "$PWD/agent_code":/to \
  alpine sh -c '
    [ -d /from/code ] || exit 0
    apk add --no-cache rsync >/dev/null
    rsync -rlD --no-perms --no-owner --no-group --no-times \
      --size-only --partial --info=progress2 \
      /from/code/ /to/
  '
```

`rsync`, not `cp`, on purpose: it writes each file to a temp name and `rename()`s it over the target instead of reopening the destination file in place, so it never collides with git's read-only pack/loose-object files (`444`) the way `cp` does — no permission errors, no need to clean the target between attempts. `--no-perms --no-owner --no-group --no-times` skips metadata Colima's `sshfs` mount can't honor anyway (it proxies the write as your Mac user, which can't `chown` to an arbitrary uid, and its FUSE layer can't set an mtime on a symlink without following it) — new files just land with a normal writable mode. `--size-only` makes reruns cheap (skips the checksum pass on files already there — fine since the source, a stopped volume, isn't changing mid-migration), and `--partial` keeps interrupted transfers instead of discarding them. Safe to just re-run as many times as needed with no cleanup in between.

Sanity check afterward — should come back empty (no symlinks pointing at a missing target). GNU `find` has `-xtype l` for this; macOS's `find` doesn't, so:

```sh
find ./agent_code -type l ! -exec test -e {} \; -print
```

A hit here isn't necessarily a problem — check it against the source before assuming the copy dropped something. Some symlinks are expected to resolve "broken" when inspected from the Mac (a venv's `bin/python` pointing at an absolute in-container path like `/usr/bin/python3.13`, for instance) and will work fine once mounted back into the container. Others may just be pre-existing dangling symlinks that were already broken in the source — check with `docker run --rm -v "$vol":/vol alpine ls -la /vol/code/path/to/parent/dir`.

Once the copy looks right, bring the container up (below) — the bind mount fully shadows whatever's still under `code/` inside the volume, so the container never sees it either way. Reclaiming that space by deleting it from the volume is optional and can happen anytime later, not part of this sequence:

```sh
docker run --rm -v "$vol":/vol alpine rm -rf /vol/code
```

#### Matching `agent`'s uid to the host (optional)

Files written through the bind mount show up owned by your Mac user's uid, not `agent`'s — Colima's `sshfs` mount reports real host ownership regardless of which uid the writing process inside the container had (see above). Mostly cosmetic, but it's exactly what git's `safe.directory` ownership check keys off, so every `git` command in every repo under `~/code` will refuse to run with "detected dubious ownership" until either git's told to trust it:

```sh
git config --global --add safe.directory '*'
```

or `agent`'s uid is changed to genuinely match, via the `AGENT_UID` build arg (`Dockerfile`, `docker-compose.yml`). `.envrc.example` already sets it (`export AGENT_UID=$(id -u)`) alongside `COMPOSE_FILE` — nothing more to add if you copied it above.

`agent_home`, unlike `code/`, is a real Docker volume with real POSIX permissions enforced (no `sshfs` involved) — so changing `agent`'s uid on rebuild leaves everything already in there (dotfiles, `.ssh`, shell history, caches) owned by the _old_ uid, unreadable/unwritable by the new one, unless it's rechowned first. One-time, before rebuilding:

```sh
echo "AGENT_UID=$AGENT_UID"   # confirm it's actually set — see warning below
docker compose down
vol=$(docker compose config --format json | jq -r '.volumes.agent_home.name')
docker run --rm -v "$vol":/vol alpine chown -R "$AGENT_UID" /vol
```

This runs directly against the volume through a throwaway root container — no `sshfs` in the path, so it's a plain, reliable `chown` regardless of how much is in there. Skip it entirely on a first-time setup with nothing in `agent_home` yet.

**Check `$AGENT_UID` is actually populated before running this** — an empty value doesn't error, it silently does nothing: `chown -R "" /vol` (or the equivalent `chown -R : /vol` if you include a group) is a no-op, not a failure. That leaves `~`/`~/.ssh` owned by the old uid while `agent` is now a different one, and sshd's `StrictModes` then refuses every connection with the login just closing "[preauth]" — no clear error pointing at ownership. If you hit that: rerun the `chown` in a shell where `echo $AGENT_UID` actually prints a number (a fresh terminal, or `cd` out and back in, forces `direnv` to re-hook), then `docker compose restart agent`.

Now flip on `.envrc`/`docker-compose.local.yml` (and, if set, `AGENT_UID`) and recreate:

```sh
direnv allow
docker compose up -d --build
```

Confirm things look right — ssh in, `id` should show `agent`'s uid matching `$(id -u)` on the host if you set `AGENT_UID`, `ls -la ~` should show `agent` as owner throughout rather than a bare number, and `git status` in one of the repos under `~/code` should just work.

## Using a local model (LM Studio, etc.)

In LM Studio, Developer tab → Server Settings → enable "Serve on Local Network" (it binds `127.0.0.1` by default, which the container can't reach at all — note LM Studio's server has no auth by default, so this exposes it to your whole LAN, not just the container). Note the port (default `1234`).

`docker-compose.yml` already maps `host.docker.internal` to the Mac through Colima's VM (`extra_hosts: host-gateway`).

LM Studio 0.4.1+ serves a native Anthropic-compatible `/v1/messages` endpoint, so `claude` can point straight at it — no proxy, no opencode detour:

```sh
export ANTHROPIC_BASE_URL=http://host.docker.internal:1234
export ANTHROPIC_AUTH_TOKEN=lmstudio
```

`opencode` works the same way via its OpenAI-compatible endpoint if you'd rather use that instead; see its provider config docs.

## Moving to a remote host later

Rebuild the image on (or push it to) the remote host, run the compose stack there, then just point the `Host agent-container` block in `~/.ssh/config` at the remote address instead of `localhost`. Nothing about the container or the herdr invocation changes.

## Known gaps

- `zsh-autosuggestions` / `zsh-syntax-highlighting` in the shared zshrc are only sourced when Homebrew is present, which this container doesn't have (by choice, to keep the image apt-only). The shell works, just without those two plugins.
