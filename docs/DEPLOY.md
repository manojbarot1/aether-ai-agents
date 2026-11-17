# Deploying to another machine

A step-by-step plan for running the stack on another machine (a home server, a
spare laptop) and managing it from your own. It works for Debian, Ubuntu and
macOS targets; the boot service and the Ollama permission step are Linux only.

- [The plan at a glance](#the-plan-at-a-glance)
- [Step 0: decide](#step-0-decide)
- [Step 1: SSH access](#step-1-ssh-access)
- [Step 2: requirements on the target](#step-2-requirements-on-the-target)
- [Step 3: copy and build](#step-3-copy-and-build)
- [Step 4: the target's settings](#step-4-the-targets-settings)
- [Step 5: agent data (optional)](#step-5-agent-data-optional)
- [Step 6: start at boot (Linux, systemd)](#step-6-start-at-boot-linux-systemd)
- [Step 7: start and verify](#step-7-start-and-verify)
- [Updating a deployment](#updating-a-deployment)
- [Ollama models on Linux](#ollama-models-on-linux)
- [Troubleshooting](#troubleshooting)
- [Manual deployment (without the script)](#manual-deployment-without-the-script)

## The plan at a glance

| # | Step | Script option | Changes on the target |
|---|---|---|---|
| 0 | Decide what runs where, and whether to copy your configured agents | — | — |
| 1 | Passwordless SSH from your machine | — | `~/.ssh/authorized_keys` |
| 2 | Requirements: Node 20.18–24, npm, git, rsync, Python 3.10+, curl, lsof, zsh | `--install-packages` | apt packages |
| 3 | Copy the code, clone + build FreeLLMAPI, clone aether-code | (always) | `~/aether-ai-agents/` |
| 4 | The target's `agents.local.conf`: LAN IP, panel token | `--lan-ip`, `--open-panel` | `agents.local.conf` |
| 5 | Copy your agents' data and encryption key | `--with-data` | `.runtime/agent-*/data`, `.app/.env` |
| 5b | Let instances read the Ollama service's models | `--ollama-system-models` | ACL on `/usr/share/ollama` |
| 6 | systemd user service, so it starts at boot | `--service` | `~/.config/systemd/user/`, lingering |
| 7 | Start it, check it from your machine | `--start` | running processes |

`deploy/deploy-remote.sh` does all of it; every step is also written out below
so you can do it by hand. **Nothing is started unless you pass `--start`**, and
`--dry-run` shows what would be copied and run without changing anything.

```bash
deploy/deploy-remote.sh --help
deploy/deploy-remote.sh user@192.168.1.50 --dry-run                     # preview
deploy/deploy-remote.sh user@192.168.1.50 --install-packages --open-panel \
    --with-data --ollama-system-models --service --start                # everything
deploy/deploy-remote.sh user@192.168.1.50                               # copy + build only
```

## Step 0: decide

- **Which services and how many.** The default is
  `freellm 5 ollama 1 aether panel` (`--services "…"` to change it). Each
  FreeLLMAPI agent needs ~110–150 MB RAM; Ollama needs RAM for its model.
- **Fresh agents or a copy of yours.** Without `--with-data` the target's
  agents start empty and you log in and add keys there
  ([INSTALL.md, step 7](INSTALL.md#7-first-login-freellmapi)). With `--with-data`
  they get your agents' login, provider keys and settings. Only do that with
  machines you trust: those databases hold your provider keys.
- **Whether the panel is reachable from other devices** (`--open-panel`), and
  whether it should **start at boot** (`--service`).
- **Folder.** Default `~/<name of your local folder>`; `--dir` to change it.

## Step 1: SSH access

The script uses `ssh` with `BatchMode`, so it needs key login:

```bash
ssh-copy-id user@192.168.1.50
ssh user@192.168.1.50 true && echo ok
```

`--install-packages`, `--ollama-system-models` and `--service` use `sudo` on
the target; without passwordless sudo, run those steps by hand (below).

## Step 2: requirements on the target

The script checks for `node` (20.18–24), `npm`, `git`, `rsync`, `python3`
(3.10+), `curl`, `lsof` and `zsh`, and stops with a list of what is missing.
On Debian/Ubuntu `--install-packages` installs them with apt; by hand:

```bash
sudo apt install -y nodejs npm git rsync python3 curl lsof zsh
```

Ubuntu 24.04's Node.js is too old (18); see [INSTALL.md](INSTALL.md#ubuntu-2404--2604).
zsh matters: Aether runs the engineers' shell commands with `/bin/zsh`, and
without it every command an agent runs fails with
`No such file or directory: '/bin/zsh'`.

## Step 3: copy and build

The script rsyncs this folder to the target **without** `.git`, `.app/`,
`.runtime/`, `.aether-code/`, `agents.local.conf` or `node_modules`, and never
deletes files on the target. Then, on the target, it runs FreeLLMAPI's and
Aether's preparation, the same thing `./llm start` does on first use, but
without starting anything:

- clone FreeLLMAPI into `.app/`, `npm ci`, `npm run build` (only if the build is missing),
- create `.app/.env` with a new `ENCRYPTION_KEY` (only if missing),
- clone aether-code into `.aether-code/` (branch `AETHER_CODE_REF`).

By hand, on the target, that is:

```bash
git clone https://github.com/manojbarot1/aether-ai-agents.git ~/aether-ai-agents
cd ~/aether-ai-agents
bash -c 'source ./common.sh && prepare_freellm && prepare_aether'
```

## Step 4: the target's settings

Settings that differ per machine go in the target's `agents.local.conf`
([CONFIGURATION.md](CONFIGURATION.md)). On the first deploy the script writes:

```bash
LAN_IP="${LAN_IP:-192.168.1.50}"            # --lan-ip, or the host when it is an IP
PANEL_HOST="${PANEL_HOST:-0.0.0.0}"         # with --open-panel
PANEL_TOKEN="${PANEL_TOKEN:-<random>}"      # with --open-panel
```

Later deploys keep the target's file as it is. A target deployed before
`agents.local.conf` existed (its LAN IP and token edited into `agents.conf`)
gets those lines moved into `agents.local.conf` before `agents.conf` is
replaced by the shared one.

Read the token on the target with
`grep ^PANEL_TOKEN ~/aether-ai-agents/agents.local.conf`.

## Step 5: agent data (optional)

`--with-data` copies `.app/.env` (the encryption key) and every
`.runtime/agent-*/data/` folder (each agent's database). Logs and pid files
are not copied. The script refuses while FreeLLMAPI runs on the target, so a
database is never replaced while open: `./llm stop freellm` there first.

Both must travel together: the provider keys in the databases are encrypted
with that key. By hand:

```bash
./llm stop freellm                                   # on the target, if running
rsync -az .app/.env user@host:aether-ai-agents/.app/.env
rsync -az --include='agent-*/' --include='agent-*/data/' --include='agent-*/data/**' \
      --exclude='*' .runtime/ user@host:aether-ai-agents/.runtime/
```

Aether's own engineers (Claude, Gemini, … with their keys) are in
`~/.aether-lite` and are not copied; the target's chat gets the FreeLLMAPI and
Ollama engineers automatically.

## Step 6: start at boot (Linux, systemd)

`--service` installs [`deploy/freellmapi-agents.service`](../deploy/freellmapi-agents.service)
as a **user** service, enables lingering (so it runs at boot with nobody logged
in), and enables it. By hand, on the target:

```bash
cd ~/aether-ai-agents
mkdir -p ~/.config/systemd/user
sed -e "s|@DIR@|$PWD|g" -e "s|@SERVICES@|freellm 5 ollama 1 aether panel|g" \
    deploy/freellmapi-agents.service > ~/.config/systemd/user/freellmapi-agents.service
sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now freellmapi-agents.service
```

It is a `oneshot` unit that runs `./llm start …` and stays active;
`systemctl --user stop` runs `./llm stop`. The panel and `./llm` keep working
alongside it, and instances they start run inside the service.

```bash
systemctl --user status freellmapi-agents
journalctl --user -u freellmapi-agents -n 50
systemctl --user restart freellmapi-agents
```

On macOS there is no unit: start it with `./llm start …` (or a launchd agent
of your own).

## Step 7: start and verify

Start with `--start`, or on the target:

```bash
cd ~/aether-ai-agents && ./llm start freellm 5 ollama 1 aether panel
```

Then check from **your** machine:

```bash
HOST=192.168.1.50
for p in 3001 3002 3003 3004 3005; do curl -s -o /dev/null -w "$p %{http_code}\n" http://$HOST:$p/livez; done
curl -s http://$HOST:11435/api/version
curl -s http://$HOST:3900/api/ping                                   # {"ok":true}
curl -s -o /dev/null -w "%{http_code}\n" http://$HOST:3900/api/status # 401 without the token
```

Open `http://<host>:3900/#token=<PANEL_TOKEN>`. Model servers should show every
instance *healthy*. Send the team a small task in the chat (e.g. "create
fizzbuzz.py, run it and show the output") to check the agents can call their
providers and run commands.

Checklist:

- [ ] every FreeLLMAPI port answers `/livez` with 200
- [ ] the panel answers `/api/ping`, and `/api/status` is 401 without the token
- [ ] Aether's port (3910) is **not** reachable from your machine (it is localhost-only)
- [ ] a chat task runs a shell command without the `/bin/zsh` error
- [ ] after a reboot (`--service`), `./llm status` shows everything healthy again

## Updating a deployment

Run the same command again. It copies the changed scripts, keeps the target's
`agents.local.conf` and data, and rebuilds FreeLLMAPI only if its build is
missing. Then restart what changed:

```bash
deploy/deploy-remote.sh user@192.168.1.50
ssh user@192.168.1.50 'systemctl --user restart freellmapi-agents'   # with the service
ssh user@192.168.1.50 'cd ~/aether-ai-agents && ./llm start freellm 5 ollama 1 aether panel'  # without
```

To update FreeLLMAPI or Aether themselves on the target: `./llm update` and
`git -C .aether-code pull`.

## Ollama models on Linux

Ollama's Linux installer runs a system service as user `ollama` with its models
in `/usr/share/ollama/.ollama/models`, a folder only that user can open. The
instances `./llm` starts run as you, so either:

- **Use your own models folder** (default `~/.ollama/models`): pull through an
  instance, `OLLAMA_HOST=127.0.0.1:11435 ollama pull qwen2.5:3b`. Simple, but
  models the service already downloaded are not shared.
- **Share the service's models** (`--ollama-system-models`), read-only:

  ```bash
  sudo setfacl -m "u:$USER:rx" /usr/share/ollama      # or: sudo chmod 750 + ollama group
  # agents.local.conf
  export OLLAMA_MODELS="${OLLAMA_MODELS:-/usr/share/ollama/.ollama/models}"
  export OLLAMA_NOPRUNE=1
  ```

  New models are then pulled through the system service (`ollama pull …` on
  `:11434`) and every instance sees them.

Why an ACL rather than only the `ollama` group: a systemd user manager that was
already running when you joined the group does not get it until you log out
completely, so a boot service started from it would still be refused.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Agents' commands fail: `No such file or directory: '/bin/zsh'` | zsh not installed | `sudo apt install zsh` (no restart needed). |
| `ollama :11435 NOT RUNNING`, log says `mkdir /usr/share/ollama/.ollama: permission denied` | `OLLAMA_MODELS` points at the service's folder, which you cannot open | [Ollama models on Linux](#ollama-models-on-linux). |
| `... has no web.py (Aether's browser mode)` | aether-code checkout from a branch without browser mode | `rm -rf .aether-code` and start again (uses `AETHER_CODE_REF`), or point `AETHER_CODE_DIR` at a checkout that has `web.py`. |
| `FreeLLMAPI needs Node >=20.18 <25` | Node too old or too new | Install Node 22 (NodeSource, nvm or Homebrew `node@22`). |
| `Refusing to listen on 0.0.0.0 without PANEL_TOKEN` | `PANEL_HOST=0.0.0.0` without a token | Add `PANEL_TOKEN` to `agents.local.conf`. |
| Panel asks for an access token / API calls 401 | Opened without `#token=…` | Open `http://<host>:3900/#token=<PANEL_TOKEN>`. |
| `SKIPPED - port is used by another program` | Another program holds that port | `lsof -nP -iTCP:<port> -sTCP:LISTEN`; change `BASE_PORT`/`PANEL_PORT`. |
| `WARNING - not reachable on <LAN_IP>` | `LAN_IP` is wrong, or a firewall | Fix `LAN_IP` in `agents.local.conf`; check `ufw`/firewall rules. |
| systemd unit `failed` right after start | One service did not come up (often Ollama) | `journalctl --user -u freellmapi-agents -n 50`, then the instance's `./llm logs …`. |
| After copying data, requests fail because no provider key works | `.app/.env` not copied with the databases, so stored keys cannot be decrypted | Copy `.app/.env` from the source machine (step 5) and restart the agents. |
| `npm ci` fetches from `registry.npmmirror.com` / fails | Upstream lockfile pins that mirror | `./llm` already passes `--replace-registry-host=always`; check your npm registry config. |

| Chat: `HTTP 502: All 2 routed attempt(s) failed … (timeout, rate_limited) … retry time budget 45s exceeded` | Free providers overloaded (Google `503 high demand`, OpenRouter `429`) and the failover budget ran out | `FALLBACK_TIME_BUDGET_MS=120000` (the default in `agents.conf`; restart the agents). Add more providers/keys on agent 1 and `./llm clone`. Fewer agents sharing the same keys hit fewer 429s. |
| A job stops after one reply, no summary | The model answered with its own `<tool_call>` syntax or a stray word instead of a ```` ```run ```` / ```` ```aether ```` block | Update aether-code: it now tells the agent and asks again. Otherwise say "continue" in the chat. |
| Ollama agent: `not responding (no output for 4 min)` | Ollama runs on the CPU (no supported GPU) and every instance loads its own copy of the model | Run **one** Ollama instance with a small model (≤ 4B, e.g. `qwen2.5:3b`) and keep it Lead = *Never*; let FreeLLMAPI agents lead. `grep "inference compute" .runtime/ollama-*/server.log` shows `library=cpu` when there is no GPU. |
| Copy button does nothing / `clip_set failed … pbcopy` in the chat log | Older aether-code copied with the server's macOS clipboard | Update aether-code: copy now happens in your browser. |

Logs: `./llm logs <service> <port> [lines]`, or `.runtime/<service>-<port>/server.log`.

## Manual deployment (without the script)

On the target:

```bash
sudo apt install -y nodejs npm git rsync python3 curl lsof zsh       # step 2
git clone https://github.com/manojbarot1/aether-ai-agents.git ~/aether-ai-agents
cd ~/aether-ai-agents
cp agents.local.conf.example agents.local.conf && chmod 600 agents.local.conf
"${EDITOR:-nano}" agents.local.conf                                 # step 4: LAN_IP, panel
./llm start freellm 1 aether panel                                  # builds, then starts
```

Then log in to `http://<host>:3001` and add your keys (or copy data as in
step 5), scale up with `./llm start freellm 5 ollama 1 aether panel`, and
install the boot service as in step 6.
