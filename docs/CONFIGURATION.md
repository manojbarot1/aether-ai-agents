# Configuration

## Where settings live

| File | Committed | Holds |
|---|---|---|
| `agents.conf` | yes | Shared defaults for every machine. Don't put secrets or machine-specific values here. |
| `agents.local.conf` | **no** (gitignored) | This machine's settings: LAN IP, panel token, `OLLAMA_MODELS`, … Start from `agents.local.conf.example`. |
| `.app/.env` | no | `ENCRYPTION_KEY` shared by all FreeLLMAPI agents (generated on first start). |
| `.runtime/agent-<port>/data/` | no | Each FreeLLMAPI agent's database: login, provider keys (encrypted with the key above), settings. |
| `~/.aether-lite/` | no | Aether's engineers, sessions, memory and keys (shared with the Aether desktop app). |

**Precedence:** environment variable > `agents.local.conf` > `agents.conf`.
`agents.local.conf` is read first and `agents.conf` only fills in what is still
unset, because every line in it has the form `VAR="${VAR:-default}"`. Write the
same form in `agents.local.conf` if an environment variable should still be able
to override a value for one run:

```bash
# agents.local.conf
LAN_IP="${LAN_IP:-192.168.1.50}"
```

One-off override: `BASE_PORT=5001 ./llm start freellm 2`.

## All settings

| Variable | Default | What it does |
|---|---|---|
| `BIND_HOST` | `0.0.0.0` | Address FreeLLMAPI and Ollama listen on. `127.0.0.1` keeps them on this machine. |
| `LAN_IP` | empty | This machine's LAN address. `./llm` prints `http://LAN_IP:<port>` URLs and warns when an instance does not answer there. |
| `BASE_PORT` | `3001` | First FreeLLMAPI port; agent N uses `BASE_PORT + N - 1`. |
| `FALLBACK_TIME_BUDGET_MS` | `120000` | (FreeLLMAPI's own, exported.) How long one request may keep failing over between providers. FreeLLMAPI's default is 45000, too short when free providers hang 30–60 s; restart the agents after changing it. |
| `OLLAMA_BASE_PORT` | `11435` | First Ollama port (11434 is left to the Ollama app / system service). |
| `OLLAMA_BIND_HOST` | `$BIND_HOST` | Ollama's listen address, if different. |
| `OLLAMA_MODELS` | `~/.ollama/models` | (Ollama's own variable, `export` it.) Where instances find models. |
| `OLLAMA_NOPRUNE` | unset | (Ollama's own, `export` it.) Set to `1` when the models folder is read-only. |
| `AETHER_PORT` / `AETHER_HOST` | `3910` / `127.0.0.1` | Aether's own server, reached through the panel's Chat tab. |
| `AETHER_WEB_TOKEN` | empty | Required only if you set `AETHER_HOST` to something other than localhost. |
| `AETHER_CODE_DIR` | `.aether-code` | aether-code checkout to run (cloned on first start if missing). Point it at a checkout you already have. |
| `AETHER_CODE_REF` | `lead-summary-attachments-themes` | Branch to clone. Browser mode (`web.py`) is on this branch. |
| `AETHER_CODE_REPO` | `https://github.com/manojbarot1/aether-code.git` | Where to clone aether-code from. |
| `AETHER_PYTHON` | newest `python3.x` ≥ 3.10 | Python for Aether (`.aether-code/.venv` wins if present). |
| `PANEL_PORT` / `PANEL_HOST` | `3900` / `127.0.0.1` | Control panel address. |
| `PANEL_TOKEN` | empty | Required when the panel listens on the network. |
| `FREELLMAPI_REPO` / `FREELLMAPI_REF` | upstream / `main` | Which FreeLLMAPI to clone. Pin `FREELLMAPI_REF` to a tag for reproducible deploys. |
| `FREELLMAPI_APP_DIR` / `FREELLMAPI_RUN_DIR` | `.app` / `.runtime` | Where the build and the per-instance data live. |
| `CLONE` | `1` | `CLONE=0` starts new FreeLLMAPI agents empty instead of as copies of agent 1. |
| `CLONE_FROM` | `$BASE_PORT` | Agent new agents are copied from. |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` | unset | Pre-create the FreeLLMAPI admin on first start. |

## Opening the panel to your network

The panel can start and stop services, and the chat behind it can run commands
and edit files on the machine, so by default it only listens on `127.0.0.1`. To
use it from your laptop or phone, set **both** in `agents.local.conf`:

```bash
PANEL_HOST="${PANEL_HOST:-0.0.0.0}"
PANEL_TOKEN="${PANEL_TOKEN:-<output of: openssl rand -hex 24>}"
```

then restart it and open the link with the token in the fragment:

```bash
./llm stop panel && ./llm start panel
# http://<LAN_IP>:3900/#token=<PANEL_TOKEN>
```

- The panel refuses to listen on the network without a token.
- The token goes after `#`, so it never reaches server logs; the page keeps it
  for the browser tab. Every API call and the chat need it (401 without).
- Aether itself stays on `127.0.0.1`; the panel proxies it at `/chat/`.
- `deploy/deploy-remote.sh --open-panel` writes both lines with a fresh token.

## Exposing FreeLLMAPI and Ollama

With `BIND_HOST=0.0.0.0` (default) each instance answers on `localhost` and on
the LAN:

- FreeLLMAPI dashboard: `http://<LAN_IP>:3001` (its own login).
- FreeLLMAPI API: `http://<LAN_IP>:3001/v1` (unified API key).
- Ollama: `http://<LAN_IP>:11435` and `/v1` — **no authentication**.

Use a trusted network, reserve the machine's IP in your router, or set
`BIND_HOST="127.0.0.1"` in `agents.local.conf` to keep them private.

## Agent defaults

Model servers → *New agents from these servers* (saved in
`.runtime/agent-defaults.json`) sets the model, role and lead setting that newly
synced agents get. Existing agents are edited in the Agents tab.

## Example: a Linux server that starts at boot

```bash
# agents.local.conf
LAN_IP="${LAN_IP:-192.168.1.50}"
PANEL_HOST="${PANEL_HOST:-0.0.0.0}"
PANEL_TOKEN="${PANEL_TOKEN:-3f9c...}"            # openssl rand -hex 24
export OLLAMA_MODELS="${OLLAMA_MODELS:-/usr/share/ollama/.ollama/models}"
export OLLAMA_NOPRUNE=1
```

plus the systemd user service from [DEPLOY.md](DEPLOY.md#step-6-start-at-boot-linux-systemd).
