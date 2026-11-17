# Installation

Step by step, on one machine. To install on another machine from this one over
SSH, see [DEPLOY.md](DEPLOY.md) after step 1.

- [1. Requirements](#1-requirements)
- [2. Install the requirements](#2-install-the-requirements) (macOS, Debian, Ubuntu)
- [3. Get the code](#3-get-the-code)
- [4. Machine settings](#4-machine-settings)
- [5. First start](#5-first-start)
- [6. Check it works](#6-check-it-works)
- [7. First login (FreeLLMAPI)](#7-first-login-freellmapi)
- [8. Add agents, Ollama and the chat](#8-add-agents-ollama-and-the-chat)
- [9. Everyday commands](#9-everyday-commands)
- [10. Update and uninstall](#10-update-and-uninstall)

## 1. Requirements

| Needed for | Requirement | Why |
|---|---|---|
| everything | bash, curl, git | `./llm` is a bash script; it clones FreeLLMAPI and aether-code. |
| FreeLLMAPI, panel | **Node.js `>=20.18 <25`** and npm | FreeLLMAPI's supported range; `./llm` refuses others. |
| Aether chat | **Python 3.10+** (standard library only) | Aether's browser mode, `web.py`. |
| Aether chat | **zsh** at `/bin/zsh` | Aether runs the engineers' shell commands with `/bin/zsh -lc`. Built into macOS; install it on Linux. |
| Ollama instances | [Ollama](https://ollama.com) | Optional: only for local models. |
| `./llm` on Linux | lsof | Lets `./llm` recognise instances it started earlier. |
| deploy script | rsync, ssh | Only for [DEPLOY.md](DEPLOY.md). |

Hardware: FreeLLMAPI agents are light (~110–150 MB RAM each); they call cloud
providers. Ollama needs RAM for the models you run (an 8B model ≈ 6–8 GB per
instance). Disk: ~700 MB for the build, plus models.

Ports (all configurable, see [CONFIGURATION.md](CONFIGURATION.md)):
`3001…` FreeLLMAPI, `11435…` Ollama, `3900` panel, `3910` Aether (localhost only).

## 2. Install the requirements

### macOS (Homebrew)

```bash
brew install node@22 git python ollama
echo 'export PATH="$(brew --prefix node@22)/bin:$PATH"' >> ~/.zprofile && source ~/.zprofile
node -v        # v22.x
```

zsh, curl and lsof are part of macOS.

### Debian 13 (trixie)

Debian's own Node.js (20.19) is in the supported range:

```bash
sudo apt update
sudo apt install -y nodejs npm git curl python3 zsh lsof rsync
node -v        # v20.19.x
```

### Ubuntu 24.04 / 26.04

Ubuntu 26.04's Node.js (22) works. Ubuntu 24.04 ships Node 18, which is too old:
install Node 22 from [NodeSource](https://github.com/nodesource/distributions)
or [nvm](https://github.com/nvm-sh/nvm) first.

```bash
sudo apt update
sudo apt install -y nodejs npm git curl python3 zsh lsof rsync
node -v        # must be >= 20.18 and < 25
```

### Ollama on Linux (optional)

```bash
curl -fsSL https://ollama.com/install.sh | sh     # installs the ollama system service on :11434
ollama pull qwen2.5:3b                            # or any model you want
```

The installer's system service keeps its models in `/usr/share/ollama`, which
your user cannot read. Either pull models as your own user, or let the
instances read the service's models: see
[Ollama models on Linux](DEPLOY.md#ollama-models-on-linux).

## 3. Get the code

```bash
git clone https://github.com/manojbarot1/aether-ai-agents.git
cd aether-ai-agents
```

Everything lives in this folder: FreeLLMAPI is cloned into `.app/`, aether-code
into `.aether-code/`, and each instance's data and logs go to `.runtime/`.

## 4. Machine settings

Shared defaults are in `agents.conf` (committed). This machine's own values go in
`agents.local.conf`, which git ignores:

```bash
cp agents.local.conf.example agents.local.conf
chmod 600 agents.local.conf
```

Set at least `LAN_IP` (macOS: `ipconfig getifaddr en0`; Linux: `hostname -I`),
so `./llm` prints and checks the addresses other devices use. Everything else is
optional; see [CONFIGURATION.md](CONFIGURATION.md).

## 5. First start

Start one FreeLLMAPI agent, the chat and the panel:

```bash
./llm start freellm 1 aether panel
```

The first run:

1. clones FreeLLMAPI into `.app/` and runs `npm ci` + `npm run build` (a few minutes),
2. generates the shared `ENCRYPTION_KEY` in `.app/.env`,
3. clones aether-code (the branch with browser mode) into `.aether-code/`,
4. starts each service in the background and waits until it answers its health check.

Expected output ends with lines like:

```
  freellm :3001 UP   http://192.168.1.50:3001  http://localhost:3001
  aether :3910 UP   http://192.168.1.50:3900/#chat  http://localhost:3900/#chat
  panel :3900 UP   http://192.168.1.50:3900  http://localhost:3900
==> syncing Aether engineers
  Aether engineers synced: 1 from running instances; added FreeLLM 1
```

## 6. Check it works

```bash
./llm status
curl -s localhost:3001/livez          # FreeLLMAPI: {"status":"ok"...}
curl -s localhost:3900/api/ping       # panel: {"ok":true}
```

Then open **http://localhost:3900**: the Model servers tab should show the
agent and the chat as *healthy* (see the screenshots in the README).

## 7. First login (FreeLLMAPI)

1. Open `http://localhost:3001`.
2. Create the admin account.
3. On **Keys**, add your provider API keys (the free-tier providers FreeLLMAPI
   supports; each one you add widens what `auto` can route to).
4. Copy the agent's **unified API key** if you want to call it yourself:
   OpenAI-compatible at `http://localhost:3001/v1`, model `auto`.

`./llm sync` (run automatically after `start`) gives Aether that key, so the
chat works without you copying anything.

To skip the sign-up screen, create the admin when the agent first starts:

```bash
ADMIN_EMAIL=me@example.com ADMIN_PASSWORD='change-me' ./llm start freellm 1
```

Test a request:

```bash
KEY=...   # the unified API key from the dashboard
curl -s localhost:3001/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"Reply with: pong"}]}'
```

## 8. Add agents, Ollama and the chat

```bash
./llm start freellm 5 ollama 1 aether panel
```

- Agents 2–5 start as copies of agent 1 (same login, keys and API key).
- One Ollama instance starts on `:11435` using your local models.
- All of them appear as engineers in the chat; open
  **http://localhost:3900/#chat**, pick **Team**, and give the team a task.

You can do the same from the panel: **Model servers → Instances → Start / scale**.

## 9. Everyday commands

```bash
./llm status                    # what is running
./llm start freellm 3           # scale FreeLLMAPI to 3 agents
./llm stop ollama               # stop every Ollama instance
./llm logs freellm 3002 100     # last 100 log lines of agent 2
./llm stop                      # stop everything (data is kept)
```

To start everything at boot on Linux, install the systemd user service:
[DEPLOY.md, step 6](DEPLOY.md#step-6-start-at-boot-linux-systemd).

## 10. Update and uninstall

```bash
git pull                        # this repo: scripts, panel, docs
./llm update                    # FreeLLMAPI: git pull + rebuild
git -C .aether-code pull        # Aether chat
./llm start freellm 5 aether panel   # restarts what changed
```

`./llm start panel` / `./llm start aether` restart a running panel or chat by
themselves when their code changed since they started.

Uninstall: `./llm stop`, remove the systemd unit if you installed one
(`systemctl --user disable --now freellmapi-agents`), then delete the folder.
Aether's own data is in `~/.aether-lite`.
