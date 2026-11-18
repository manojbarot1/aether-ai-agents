# Shared code for ./llm and the wrapper scripts. Sourced, not run.
# Works with the bash 3.2 that ships with macOS (no associative arrays).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# agents.local.conf (gitignored) holds this machine's own settings: LAN IP,
# panel token, extra exports. It is read first; agents.conf only fills in
# what is still unset, so environment > agents.local.conf > agents.conf.
if [[ -f "$SCRIPT_DIR/agents.local.conf" ]]; then source "$SCRIPT_DIR/agents.local.conf"; fi
if [[ -f "$SCRIPT_DIR/agents.conf" ]]; then source "$SCRIPT_DIR/agents.conf"; fi

REPO_URL="${FREELLMAPI_REPO:-https://github.com/tashfeenahmed/freellmapi.git}"
REPO_REF="${FREELLMAPI_REF:-main}"
APP_DIR="${FREELLMAPI_APP_DIR:-$SCRIPT_DIR/.app}"      # FreeLLMAPI checkout + build
RUN_DIR="${FREELLMAPI_RUN_DIR:-$SCRIPT_DIR/.runtime}"  # per-instance data, logs, pids

BIND_HOST="${BIND_HOST:-127.0.0.1}"
LAN_IP="${LAN_IP:-}"
BASE_PORT="${BASE_PORT:-3001}"                 # FreeLLMAPI
OLLAMA_BASE_PORT="${OLLAMA_BASE_PORT:-11435}"  # 11434 is left to the Ollama app
OLLAMA_BIND_HOST="${OLLAMA_BIND_HOST:-$BIND_HOST}"
PANEL_PORT="${PANEL_PORT:-3900}"
PANEL_HOST="${PANEL_HOST:-127.0.0.1}"
CLONE_FROM="${CLONE_FROM:-$BASE_PORT}"         # FreeLLMAPI agent new agents are copied from
AETHER_PORT="${AETHER_PORT:-3910}"
AETHER_HOST="${AETHER_HOST:-127.0.0.1}"
AETHER_CODE_REPO="${AETHER_CODE_REPO:-https://github.com/manojbarot1/aether-code.git}"
AETHER_CODE_REF="${AETHER_CODE_REF:-main}"
AETHER_CODE_DIR="${AETHER_CODE_DIR:-$SCRIPT_DIR/.aether-code}"

SERVICES="freellm ollama aether panel"

# --- service definitions ----------------------------------------------------

is_service() { case "$1" in freellm|ollama|aether|panel) return 0 ;; esac; return 1; }
# Services that run exactly one instance.
is_single()  { case "$1" in aether|panel) return 0 ;; esac; return 1; }

svc_label() {
  case "$1" in freellm) echo "FreeLLMAPI" ;; ollama) echo "Ollama" ;; aether) echo "Aether chat" ;; panel) echo "Control panel" ;; esac
}
# Runtime dir prefix. FreeLLMAPI keeps "agent" so existing data stays put.
svc_prefix() {
  case "$1" in freellm) echo agent ;; ollama) echo ollama ;; aether) echo aether ;; panel) echo panel ;; esac
}
svc_base_port() {
  case "$1" in freellm) echo "$BASE_PORT" ;; ollama) echo "$OLLAMA_BASE_PORT" ;; aether) echo "$AETHER_PORT" ;; panel) echo "$PANEL_PORT" ;; esac
}
svc_bind() {
  case "$1" in freellm) echo "$BIND_HOST" ;; ollama) echo "$OLLAMA_BIND_HOST" ;; aether) echo "$AETHER_HOST" ;; panel) echo "$PANEL_HOST" ;; esac
}
svc_health_path() {
  case "$1" in freellm) echo /livez ;; ollama) echo /api/version ;; aether) echo /healthz ;; panel) echo /api/ping ;; esac
}

# One-time checks before any instance of $1 starts.
svc_prepare() {
  case "$1" in
    freellm) prepare_freellm ;;
    ollama)
      command -v ollama >/dev/null || {
        echo "ollama is not installed: brew install ollama (or https://ollama.com/download)" >&2
        return 1
      } ;;
    aether) prepare_aether ;;
    panel) command -v node >/dev/null || { echo "node is required" >&2; return 1; } ;;
  esac
}

# Runs in the background subshell; exec replaces it so the pid file is right.
svc_exec() {
  local svc="$1" port="$2"
  case "$svc" in
    freellm)
      cd "$APP_DIR"
      export NODE_ENV=production PORT="$port" HOST="$BIND_HOST" \
             FREEAPI_DB_PATH="$(db_file "$port")"
      if [[ -n "${CONFIG_JSON:-}" ]]; then export FREEAPI_CONFIG_JSON="$CONFIG_JSON"; fi
      exec node server/dist/index.js ;;
    ollama)
      export OLLAMA_HOST="$OLLAMA_BIND_HOST:$port"
      exec ollama serve ;;
    aether)
      cd "$AETHER_CODE_DIR"
      export AETHER_WEB_TOKEN="${AETHER_WEB_TOKEN:-}"
      exec "$(aether_python)" web.py --host "$AETHER_HOST" --port "$port" ;;
    panel)
      export PANEL_HOST PANEL_PORT="$port" PANEL_TOKEN="${PANEL_TOKEN:-}" LLM_DIR="$SCRIPT_DIR" RUN_DIR LAN_IP \
             AETHER_PORT AETHER_WEB_TOKEN="${AETHER_WEB_TOKEN:-}"
      exec node "$SCRIPT_DIR/panel/server.mjs" ;;
  esac
}

# --- addresses --------------------------------------------------------------

is_wildcard() { case "$1" in 0.0.0.0|::|'') return 0 ;; esac; return 1; }

# Where the scripts connect to reach a service bound to $1.
probe_host() {
  if is_wildcard "$1"; then echo 127.0.0.1
  elif [[ "$1" == *:* ]]; then echo "[$1]"
  else echo "$1"; fi
}

# URLs instance $1:$2 can be reached at, space separated: LAN first, then local.
inst_urls() {
  if [[ "$1" == aether ]]; then   # people reach it through the panel's Chat tab
    inst_urls panel "$PANEL_PORT" | sed 's|\( \)|/#chat |g; s|$|/#chat|'
    return
  fi
  local bind; bind="$(svc_bind "$1")"
  if is_wildcard "$bind"; then
    if [[ -n "$LAN_IP" ]]; then echo "http://$LAN_IP:$2 http://localhost:$2"
    else echo "http://localhost:$2"; fi
  else
    echo "http://$(probe_host "$bind"):$2"
  fi
}

inst_alive() {
  curl -fsS -o /dev/null --noproxy '*' --max-time 2 \
    "http://$(probe_host "$(svc_bind "$1")"):$2$(svc_health_path "$1")" 2>/dev/null
}

# True if $1:$2 answers on LAN_IP (always true when that does not apply).
inst_lan_alive() {
  is_wildcard "$(svc_bind "$1")" && [[ -n "$LAN_IP" ]] || return 0
  curl -fsS -o /dev/null --noproxy '*' --max-time 2 "http://$LAN_IP:$2$(svc_health_path "$1")" 2>/dev/null
}

# True if something already accepts connections on the port.
# curl exit 7 = refused, 28 = timed out (address unreachable): both mean free.
port_in_use() {
  local rc=0
  curl -s -o /dev/null --noproxy '*' --max-time 1 "http://$(probe_host "$(svc_bind "$1")"):$2/" 2>/dev/null || rc=$?
  [[ $rc -ne 7 && $rc -ne 28 ]]
}

# --- instance bookkeeping ---------------------------------------------------

instance_dir() { echo "$RUN_DIR/$(svc_prefix "$1")-$2"; }
pid_file()     { echo "$(instance_dir "$1" "$2")/server.pid"; }
log_file()     { echo "$(instance_dir "$1" "$2")/server.log"; }
db_file()      { echo "$(instance_dir freellm "$1")/data/freellmapi.db"; }

# True if process $3 is an instance of service $1 (guards against pid reuse
# and lets a port's listener be recognised).
svc_owns() {
  local cmd
  cmd="$(ps -o command= -p "$3" 2>/dev/null)" || return 1
  case "$1" in
    freellm) [[ "$cmd" == *server/dist/index.js* ]] ;;
    ollama)  [[ "$cmd" == *ollama*serve* ]] ;;
    aether)  [[ "$cmd" == *web.py* ]] ;;
    panel)   [[ "$cmd" == *panel/server.mjs* ]] ;;
    *) return 1 ;;
  esac
}

# PID of the process of service $1 listening on port $2, if any.
listener_pid() {
  command -v lsof >/dev/null || return 1
  local pid
  for pid in $(lsof -nP -iTCP:"$2" -sTCP:LISTEN -t 2>/dev/null); do
    if svc_owns "$1" "$2" "$pid"; then echo "$pid"; return 0; fi
  done
  return 1
}

# Prints the PID if instance $1:$2 is running, else returns 1. Uses the pid
# file, and falls back to whatever instance of the service holds the port (a
# process left over from an earlier run), adopting it into the pid file.
running_pid() {
  local pf pid
  pf="$(pid_file "$1" "$2")"
  if [[ -f "$pf" ]]; then
    pid="$(cat "$pf")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && svc_owns "$1" "$2" "$pid"; then
      echo "$pid"
      return 0
    fi
    rm -f "$pf"
  fi
  if pid="$(listener_pid "$1" "$2")"; then
    mkdir -p "$(instance_dir "$1" "$2")"
    echo "$pid" > "$pf"
    echo "$pid"
    return 0
  fi
  return 1
}

# Ports of every instance of $1 that has a runtime dir, ascending.
known_ports() {
  [[ -d "$RUN_DIR" ]] || return 0
  local prefix d
  prefix="$(svc_prefix "$1")"
  for d in "$RUN_DIR/$prefix"-*; do
    if [[ -d "$d" ]]; then echo "${d##*/$prefix-}"; fi
  done | sort -n
}

# "pid command" of whatever listens on port $1, for messages.
port_owner() {
  local pid
  pid="$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -n1)"
  if [[ -n "$pid" ]]; then echo "pid $pid ($(ps -o command= -p "$pid" 2>/dev/null | cut -c1-60))"
  else echo "unknown (check: lsof -nP -iTCP:$1 -sTCP:LISTEN)"; fi
}

# Source files of the panel and Aether chat. Either one keeps running old code
# after an edit or a `git pull`, so starting it again restarts it when one of
# these is newer than the running process. (Aether re-reads ui.html by itself.)
svc_code() {
  case "$1" in
    panel)  echo "$SCRIPT_DIR/panel/server.mjs" ;;
    aether) echo "$AETHER_CODE_DIR/web.py $AETHER_CODE_DIR/app.py $AETHER_CODE_DIR/orchestrate.py $AETHER_CODE_DIR/api_engineer.py $AETHER_CODE_DIR/web/bridge.js" ;;
  esac
}

code_changed() {
  local pidf f
  pidf="$(pid_file "$1" "$2")"
  [[ -f "$pidf" ]] || return 1
  for f in $(svc_code "$1"); do
    [[ -f "$f" && "$f" -nt "$pidf" ]] && return 0
  done
  return 1
}

# Start instance $1:$2 unless it is already running (and up to date).
launch_instance() {
  local svc="$1" port="$2" pid
  if pid="$(running_pid "$svc" "$port")"; then
    if ! code_changed "$svc" "$port"; then
      echo "  $svc :$port already running (pid $pid)"
      return 0
    fi
    echo "  $svc :$port code changed since it started: restarting"
    stop_instance "$svc" "$port"
  fi
  if port_in_use "$svc" "$port"; then
    echo "  $svc :$port SKIPPED - port is used by another program: $(port_owner "$port")" >&2
    return 0
  fi
  mkdir -p "$(instance_dir "$svc" "$port")/data"
  ( trap '' HUP; svc_exec "$svc" "$port" ) >>"$(log_file "$svc" "$port")" 2>&1 </dev/null &
  pid=$!
  echo "$pid" > "$(pid_file "$svc" "$port")"
  # Wait until the subshell has exec'd into the service, so running_pid's
  # ownership check recognises it from here on.
  for _ in $(seq 1 20); do
    svc_owns "$svc" "$port" "$pid" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  echo "  $svc :$port started (pid $pid, log $(log_file "$svc" "$port"))"
}

# Wait up to ~30s for $1:$2 to pass its health check.
wait_healthy() {
  local svc="$1" port="$2"
  # Not ours (e.g. skipped because another program holds the port): its
  # health check would only describe that other program.
  if ! running_pid "$svc" "$port" >/dev/null; then
    echo "  $svc :$port NOT RUNNING" >&2
    return 1
  fi
  for _ in $(seq 1 60); do
    if inst_alive "$svc" "$port"; then
      echo "  $svc :$port UP   $(inst_urls "$svc" "$port" | sed 's/ /  /g')"
      inst_lan_alive "$svc" "$port" || echo "  $svc :$port WARNING - not reachable on $LAN_IP; is that still this machine's IP? (macOS: ipconfig getifaddr en0, Linux: hostname -I)" >&2
      return 0
    fi
    running_pid "$svc" "$port" >/dev/null || break
    sleep 0.5
  done
  echo "  $svc :$port FAILED - see $(log_file "$svc" "$port")" >&2
  tail -n 15 "$(log_file "$svc" "$port")" >&2 || true
  return 1
}

stop_instance() {
  local svc="$1" port="$2" pid
  if ! pid="$(running_pid "$svc" "$port")"; then
    echo "  $svc :$port not running"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "  $svc :$port did not exit, sending SIGKILL"
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$(pid_file "$svc" "$port")"
  echo "  $svc :$port stopped (pid $pid)"
}

# --- FreeLLMAPI specifics ---------------------------------------------------

# Clone + build on first use (or when UPDATE=1), and make the shared
# encryption key. Sets CONFIG_JSON when ADMIN_EMAIL/ADMIN_PASSWORD are set.
prepare_freellm() {
  command -v node >/dev/null || { echo "node is required (>=20.18 <25)" >&2; return 1; }
  command -v git  >/dev/null || { echo "git is required" >&2; return 1; }
  local major
  major="$(node -p 'process.versions.node.split(".")[0]')"
  if (( major < 20 || major >= 25 )); then
    echo "FreeLLMAPI needs Node >=20.18 <25 (found $(node -v))" >&2
    return 1
  fi

  local update="${UPDATE:-0}"
  if [[ ! -d "$APP_DIR/.git" ]]; then
    echo "==> cloning $REPO_URL ($REPO_REF)"
    git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$APP_DIR"
    update=1
  elif (( update )); then
    echo "==> updating FreeLLMAPI checkout"
    git -C "$APP_DIR" pull --ff-only
  fi
  if (( update )) || [[ ! -f "$APP_DIR/server/dist/index.js" ]]; then
    echo "==> installing FreeLLMAPI dependencies"
    (cd "$APP_DIR" && npm ci --no-audit --no-fund --replace-registry-host=always)
    echo "==> building FreeLLMAPI"
    (cd "$APP_DIR" && npm run build)
  fi

  # One encryption key shared by all agents, kept in the app's .env.
  if ! grep -qs '^ENCRYPTION_KEY=[0-9a-f]\{64\}$' "$APP_DIR/.env"; then
    echo "==> generating ENCRYPTION_KEY in $APP_DIR/.env"
    local key
    key="$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')"
    printf 'ENCRYPTION_KEY=%s\n' "$key" > "$APP_DIR/.env"
    chmod 600 "$APP_DIR/.env"
  fi

  CONFIG_JSON=""
  if [[ -n "${ADMIN_EMAIL:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    CONFIG_JSON="$(node -e 'console.log(JSON.stringify({admin:{email:process.env.ADMIN_EMAIL,password:process.env.ADMIN_PASSWORD}}))')"
  fi
}

# Copy FreeLLMAPI agent $1's DB (keys, account, models, routing) onto agent $2.
# The license, sessions and request history are left out (see clone-db.cjs).
clone_db() {
  node "$SCRIPT_DIR/clone-db.cjs" "$APP_DIR" "$(db_file "$1")" "$(db_file "$2")"
}

# --- Aether chat (aether-code's browser mode) --------------------------------

# Python for Aether: its own .venv if present, else the newest python3 >= 3.10.
aether_python() {
  local py
  for py in "${AETHER_PYTHON:-}" "$AETHER_CODE_DIR/.venv/bin/python" python3.13 python3.12 python3.11 python3.10 python3; do
    [[ -n "$py" ]] && command -v "$py" >/dev/null || continue
    if "$py" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
      command -v "$py"
      return 0
    fi
  done
  return 1
}

# Clone aether-code on first use; it must have browser mode (web.py).
prepare_aether() {
  if [[ ! -d "$AETHER_CODE_DIR" ]]; then
    echo "==> cloning $AETHER_CODE_REPO ($AETHER_CODE_REF) into $AETHER_CODE_DIR"
    git clone --depth 1 --branch "$AETHER_CODE_REF" "$AETHER_CODE_REPO" "$AETHER_CODE_DIR"
  fi
  if [[ ! -f "$AETHER_CODE_DIR/web.py" ]]; then
    echo "$AETHER_CODE_DIR has no web.py (Aether's browser mode)." >&2
    echo "Update it (git -C \"$AETHER_CODE_DIR\" pull) or point AETHER_CODE_DIR in agents.local.conf at a checkout that has it." >&2
    return 1
  fi
  aether_python >/dev/null || { echo "Aether needs Python 3.10+: brew install python" >&2; return 1; }
  if [[ "$AETHER_HOST" != 127.0.0.1 && "$AETHER_HOST" != localhost && -z "${AETHER_WEB_TOKEN:-}" ]]; then
    echo "AETHER_HOST=$AETHER_HOST needs AETHER_WEB_TOKEN in agents.local.conf: Aether engineers can run commands on this machine." >&2
    return 1
  fi
  install_aether_helpers
}

# Aether tells its engineers to use `freeport` (first free port) and `aserve <dir>` (serve a folder on a
# free port). The desktop app ships them in ~/.local/bin; browser mode needs them there too, or every
# "start a test server" step fails and the team ends without verifying anything.
install_aether_helpers() {
  local bin="$HOME/.local/bin" name src
  mkdir -p "$bin"
  for name in freeport aserve; do
    src="$AETHER_CODE_DIR/$name.py"
    [[ -f "$src" ]] || continue
    chmod +x "$src"
    if [[ -L "$bin/$name" || ! -e "$bin/$name" ]]; then
      ln -sf "$src" "$bin/$name"
    fi
  done
}
