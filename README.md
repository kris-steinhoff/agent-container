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

`agent_home` is a named volume mounted at `/home/agent` — it's seeded from the image on first start (dotfiles, herdr, nvim plugins already installed) and then persists auth tokens, shell history, project checkouts, and anything else you don't mount separately across `docker compose restart`/`down`+`up`. `docker compose down -v` deletes it. Being a named volume, it's opaque to the host — there's no path on the Mac side to open a file an agent created in there. The shared scratch directory below is the escape hatch for that.

`ssh_host_keys` persists the sshd host keys across rebuilds so your local `known_hosts` doesn't need updating every time you rebuild the image.

To work on a project, bind-mount it in — see the commented example in `docker-compose.yml`. Anything not mounted only exists in `agent_home`.

### Shared scratch directory

A named volume has no path on the Mac side, so anything an agent leaves in its home directory is unreachable from Finder or a desktop editor. A small bind-mounted scratch directory fixes that in both directions: an agent drops a draft artifact — a drawio diagram, a screenshot, a document for review — into `~/scratch` inside the container and it's a real file on the Mac, and anything you drop in from the Mac side is immediately readable by the agent. Everything else (dotfiles, shell history, tool caches, project checkouts) stays in `agent_home` as normal.

Treat it as a handoff space, not storage. It sits outside `agent_home`, so `docker compose down -v` won't take it with the volume, but nothing backs it up or versions it either.

The host path only makes sense on the machine it points at, so it's wired up through two gitignored files rather than edited into `docker-compose.yml` directly:

- **`docker-compose.local.yml`** — a compose override, merged in on top of `docker-compose.yml`. Copy the tracked template and point the source at wherever you want the directory on the Mac:

  ```sh
  cp docker-compose.local.yml.example docker-compose.local.yml
  ```

  Compose adds this as a second, independent mount (different target path from `agent_home`'s `/home/agent`) — nothing else in `docker-compose.yml` needs to change.

- **`.envrc`** ([direnv](https://direnv.net/)) — so `docker compose` picks `docker-compose.local.yml` up automatically instead of needing `-f` on every invocation. Copy the tracked template (it also sets `AGENT_UID`, covered below):

  ```sh
  cp .envrc.example .envrc
  ```

  Run `direnv allow` once after creating it.

Create the host directory yourself before the first `up`, rather than letting Docker create the missing mount source for you — that way it lands owned by your Mac user with a mode you chose:

```sh
mkdir -p ~/Scratch
```

#### Matching `agent`'s uid to the host

Files under the scratch mount carry real host ownership in both directions: Colima's `sshfs` mount reports the host's uid regardless of which uid the writing process inside the container had, and doesn't remap it either way. So if `agent`'s uid doesn't match your Mac user's, each side sees the other's files as owned by a stranger — readable at the usual `644`, but not writable — which defeats the point of a shared directory. `agent`'s uid is set at build time via the `AGENT_UID` build arg (`Dockerfile`, `docker-compose.yml`); `.envrc.example` already sets it (`export AGENT_UID=$(id -u)`) alongside `COMPOSE_FILE`, so there's nothing more to add if you copied it above.

`agent_home`, unlike the scratch mount, is a real Docker volume with real POSIX permissions enforced (no `sshfs` involved) — so changing `agent`'s uid on rebuild leaves everything already in there (dotfiles, `.ssh`, shell history, caches) owned by the _old_ uid, unreadable/unwritable by the new one, unless it's rechowned first. One-time, before rebuilding:

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

Confirm things look right — ssh in, `id` should show `agent`'s uid matching `$(id -u)` on the host if you set `AGENT_UID`, `ls -la ~` should show `agent` as owner throughout rather than a bare number, and `~/scratch` should be owned by `agent` too. Write a file into it from each side and check the other side can edit it.

#### Migrating back from a bind-mounted `/home/agent/code`

Only relevant if you followed an earlier version of this README and bind-mounted `/home/agent/code` to a host directory. The scratch directory replaces that arrangement: project checkouts go back to living in `agent_home`, where they get real POSIX ownership and no `sshfs` in the path (which is also what git's `safe.directory` ownership check wants). Move the content back into the volume with the container down, before you switch `docker-compose.local.yml` over to the scratch mount:

```sh
docker compose down                 # stops the container, keeps the volume
vol=$(docker compose config --format json | jq -r '.volumes.agent_home.name')
src=~/Code/Agent                    # whatever docker-compose.local.yml points at

docker run --rm \
  -v "$src":/from \
  -v "$vol":/to \
  alpine sh -c '
    apk add --no-cache rsync >/dev/null
    mkdir -p /to/code
    rsync -a --partial --info=progress2 /from/ /to/code/
  '
```

`rsync`, not `cp`, on purpose: it writes each file to a temp name and `rename()`s it over the target instead of reopening the destination file in place, so it never collides with git's read-only pack/loose-object files (`444`) the way `cp` does — no permission errors, no need to clean the target between attempts. `--partial` keeps interrupted transfers instead of discarding them, and the default size+mtime comparison skips what's already there, so this is safe to re-run as many times as needed with no cleanup in between. The destination is a real volume this time (not `sshfs`), so full `-a` metadata preservation works and the earlier `--no-perms`/`--no-owner`/`--no-times` workarounds aren't needed.

Everything lands owned by whoever `rsync` ran as, so hand it to `agent`. Running the `chown` from this project's own image rather than `alpine` gets the uid right whether or not you set `AGENT_UID`, since the image already has the `agent` user:

```sh
docker run --rm -v "$vol":/vol --entrypoint sh agent-container -c 'chown -R agent:agent /vol/code'
```

Now switch `docker-compose.local.yml` from the `code` mount to the scratch mount, bring the container up, and check `~/code` from inside before deleting anything on the host side — `git status` in a repo or two is the quick version.

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
