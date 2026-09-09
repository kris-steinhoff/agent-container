# agent-container

A Debian-based container for running Claude Code / opencode isolated from the host, attached to with [herdr](https://herdr.dev) over SSH. Runs locally via Docker Compose, or as a scale-to-zero remote box on AWS Fargate — same image, same herdr workflow, just a different SSH target. See [Running on AWS Fargate](#running-on-aws-fargate).

Ships: `claude`, `opencode`, `copilot`, `codex`, `pi`, `neovim` (latest release), `gh`, `glab`, `uv`, `chezmoi` (applies this dotfiles repo on build), and `sshd` so herdr can attach to a persistent session inside the container.

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

`claude`, `copilot`, `codex`, `pi`, `herdr`, and `bd` sit below a cache gate at the bottom of the Dockerfile so they can reinstall without busting the expensive base layers (apt, neovim, chezmoi plugin pre-fetch). The gate is the `TOOLS_REFRESH` build arg: change its value and only those tools rebuild. A plain build defaults it to `0`, which reuses the cache. `./up docker --build` passes a fresh timestamp and forces a recreate so those tools track latest:

```sh
./up docker --build
```

Equivalent to `TOOLS_REFRESH=$(date +%s) docker compose up -d --build --force-recreate` — the `--force-recreate` guarantees a fresh container even in the (normally unlikely) case Compose's own change detection wouldn't otherwise trigger one. Everything else (including `opencode`, `neovim`, `terraform`, `gh`, `glab`) stays cached until you edit the Dockerfile or build with `--no-cache`. Plain `./up` (or `./up docker`) is the idempotent `docker compose up -d` with no rebuild; `./up docker --restart` force-recreates without rebuilding.

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

### Docker access

The container ships the `docker` CLI but no daemon — bind-mount the docker socket in via `docker-compose.local.yml` (see the commented line in `docker-compose.local.yml.example`) to let the agent run containers against Colima's (or Docker Desktop's) daemon directly:

```sh
- /var/run/docker.sock:/var/run/docker.sock
```

Use that plain path, not `~/.colima/default/docker.sock` — despite `docker context inspect` showing the latter as `Endpoints.docker.Host` for the Mac-side `docker` CLI, it's a macOS-side proxy Colima forwards over SSH, not the real socket. This project's containers are created by the dockerd _inside_ the Colima VM, and Docker resolves bind-mount sources against that daemon's own filesystem — so `/var/run/docker.sock` reaches the VM's native socket directly, while the `~/.colima/...` path gets proxied through a virtiofs share first. Unix domain sockets don't survive that hop (the file shows up with correct type bits — `ls`/`chmod` succeed — but `connect()` fails with "Cannot connect to the Docker daemon", even with Colima running, since the real listener lives in macOS's kernel, not the VM's).

This is a significant capability grant: anyone with a shell in the container gets full control of that docker daemon, equivalent to root on the Colima VM (or your Mac, on Docker Desktop) — it can mount arbitrary host paths into new containers, not just run existing ones. `agent` already has passwordless sudo inside the container, so this doesn't add a new trust boundary _inside_ the container, but it does extend the container's reach out to the host daemon. Skip it if that's more access than you want the agent to have.

`entrypoint.sh` `chmod`s the socket to `666` on container start (it arrives owned by whatever uid/gid the host side has, which `agent` isn't in) — since it's a bind mount, not a copy, this changes the permissions on the host-side socket too, not just inside the container.

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

Two ways. For any box you already run Docker on: rebuild the image on (or push it to) the remote host, run the compose stack there, then just point the `Host agent-container` block in `~/.ssh/config` at the remote address instead of `localhost`. Nothing about the container or the herdr invocation changes. For a managed, scale-to-zero remote box with nothing to keep running, use AWS Fargate — see below.

## Running on AWS Fargate

The same image, run as a single standalone Fargate task you start on demand with `./up cloud`. It scales to zero: when nothing's using it (no herdr agent working, nobody SSH'd in) it stops itself after ~30 minutes, and a stopped task costs nothing for compute. `./up cloud` again brings it straight back. The task gets a fresh auto-assigned public IP each start, so there's no fixed address — instead `./up cloud` resolves the current IP and rewrites the `Host agent-container` block in the project-root `ssh_config` (the same file you already `Include` from `~/.ssh/config`), so `herdr --remote agent-container` keeps working unchanged. The sshd host keys live on EFS, so the host key is stable across restarts and `known_hosts` doesn't churn even though the IP moves. Persistence (the whole `/home/agent`: dotfiles, auth tokens, herdr, project checkouts) lives on EFS and survives the task exiting.

`ssh_config` is tracked, but `./up` now owns its `Host agent-container` block: `./up cloud` writes the current cloud IP into it and `./up docker` restores the committed `localhost:2222` values. So while you're pointed at the cloud task the file shows as modified in git — that's expected, and you don't commit the cloud IP. A clean checkout stays in the local state.

Why a bare task and not an ECS Service: a Service would keep something running (and billing) to maintain desired-count. A one-off task that exits when idle is the whole point — the container's process exiting _is_ the scale-to-zero.

### One-time setup

Everything AWS-side is Terraform in `terraform/`:

```sh
cd terraform
terraform init
terraform apply
```

That creates the ECR repo, the EFS filesystem + access point, the ECS cluster, task definition, IAM roles, the two security groups, the CloudWatch log group, and an SSM parameter for your authorized key. Put your public key into that parameter (it's created with a placeholder, and Terraform ignores its value afterward so it never lands in state):

```sh
aws ssm put-parameter --name /agent-container/authorized_keys --type String \
  --overwrite --value "$(ssh-add -L | head -1)"
```

Then build and push the first image (arm64, since Fargate here runs Graviton):

```sh
cd ..
./up cloud --build
```

No SSH-config editing to do — you already `Include` the project-root `ssh_config` from `~/.ssh/config` (from the first-time setup at the top of this README), and `./up cloud` keeps its `Host agent-container` block pointed at the running task.

### Daily use

```sh
./up cloud
```

Starts the task if it's stopped (or reconnects you if it's already up), resolves its public IP and writes it into the `Host agent-container` block in `ssh_config`, opens port 22 to your current public IP, waits for SSH, and prints the `herdr --remote agent-container` line. Then attach as usual. The box shuts itself down after ~30 minutes with no herdr agent running and nobody SSH'd in; run `./up cloud` again to restart it (a fresh task — the in-container herdr server is gone, but everything in `/home/agent` is still on EFS, so `herdr --remote` reinstalls and reconnects).

- `./up cloud --restart` stops the running task and launches a fresh one. This kills the in-container herdr server, so any live agents go with it.
- `./up cloud --build` rebuilds the arm64 image, pushes it to ECR, then restarts onto it. Implies `--restart`.
- `./up cloud --stop` stops the task now (scale to zero on demand).
- `./up cloud --cidr 203.0.113.0/24` opens port 22 to a specific CIDR instead of your detected `/32`.

Each `./up cloud` rewrites the SSH security group so port 22 is open only to your current IP — no standing world-open rule.

### Configuration

- `AWS_REGION` — region for `./up cloud`'s API calls (default `us-east-2`). Terraform pins the same default via `var.region`; set `TF_VAR_region` to match if you change it.
- `AGENT_SUBNET_ID` — pin the task to a specific public subnet. `./up` forwards it to Terraform as `TF_VAR_subnet_id`. Left unset, Terraform uses the default VPC's default subnet.
- The idle-shutdown thresholds, all set on the task and overridable in the task definition's environment: `IDLE_TIMEOUT` (default 1800s — how long idle must hold before it stops), `STARTUP_GRACE` (default 1200s — never stop within this of boot), `MAX_LIFETIME` (default 43200s — hard cap, stop regardless), `IDLE_POLL_INTERVAL` (default 120s).
- Each Terraform output also has an `AGENT_*` env override (`AGENT_CLUSTER_ARN`, `AGENT_TASK_DEFINITION_FAMILY`, `AGENT_ECR_REPOSITORY_URL`, `AGENT_TASK_SG_ID`, `AGENT_SSH_SG_ID`, `AGENT_SUBNET_ID`, `AGENT_LOG_GROUP`), so you can drive `./up cloud` without Terraform on PATH once you know the values.

### Handing files back and forth

There's no bind mount in the cloud, so the shared scratch directory works over rsync instead. `scratch-pull` copies `agent-container:scratch/` down into `./agent_scratch/`; `scratch-push` copies the other way. Both take an optional path (relative to `scratch/`) to sync a single file or subdir, and both refuse if `./agent_scratch` doesn't exist yet (`mkdir -p agent_scratch` first):

```sh
scratch-pull                 # everything the agent left in ~/scratch
scratch-push diagram.drawio  # hand one file to the agent
```

### Cost

Roughly \$1.50/month while idle: the EFS storage you use plus ECR storage for the image — there's no Elastic IP to pay for, since the task uses its own auto-assigned public IP. Fargate compute is billed only while a task is actually running — a 1 vCPU / 4 GB Graviton task is a few cents an hour, and you pay nothing for it once the box scales to zero.

## Shell

The dotfiles' shared zshrc sources `zsh-autosuggestions` / `zsh-syntax-highlighting` from Homebrew paths, which don't exist here (no Homebrew, by choice, to keep the image apt-only). Both come from apt instead, and the build appends a source block to the end of `/home/agent/.zshrc` to load them (last, so syntax highlighting wraps every widget defined before it). `zsh-completions` has no Debian package, so it's cloned to `/usr/local/share/zsh-completions` and added to `fpath` from `/etc/zsh/zshrc`, which zsh reads before `~/.zshrc` and therefore before the shared zshrc's `compinit`.

Both live outside chezmoi's control, so `chezmoi apply` won't clobber them. Note that `/home/agent/.zshrc` only comes from the image when `agent_home` is first created, so an existing volume needs `docker compose down -v` (or a manual edit) to pick up the plugin block.
