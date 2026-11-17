#!/usr/bin/env bash
# Deploy this folder to another machine over SSH (Linux or macOS), build it
# there, and optionally copy your agents' data, install a boot service and
# start it. Nothing is started unless you pass --start.
#
#   deploy/deploy-remote.sh user@host [options]
#
# Options
#   --dir PATH            Remote folder (default: ~/<name of this folder>).
#   --lan-ip IP           The remote's LAN IP for agents.local.conf
#                         (default: host, when host is an IP address).
#   --open-panel          Panel on the network: PANEL_HOST=0.0.0.0 plus a
#                         generated PANEL_TOKEN (only when agents.local.conf
#                         is created).
#   --with-data           Also copy FreeLLMAPI agent data (.runtime/agent-*/data)
#                         and .app/.env (the encryption key). These hold your
#                         provider keys: only use with machines you trust.
#   --install-packages    Debian/Ubuntu: apt-get install what is missing
#                         (nodejs npm git rsync python3 curl lsof zsh). Uses sudo.
#   --ollama-system-models  Linux: let the instances read the models of the
#                         Ollama system service (/usr/share/ollama). Uses sudo.
#   --service             Linux: install + enable the systemd user service
#                         (starts at boot; enables lingering). Uses sudo.
#   --services "SPEC"     What the service / --start runs
#                         (default: "freellm 5 ollama 1 aether panel").
#   --start               Start now (through the service when installed).
#   --dry-run             Show what would be copied and run; change nothing.
#
# Safe to run again: it updates the code, keeps the remote's agents.local.conf
# and data, and only rebuilds FreeLLMAPI when its build is missing.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 1; }
die()   { echo "error: $*" >&2; exit 1; }
say()   { printf '\n==> %s\n' "$*"; }

TARGET="" DIR="" LAN="" OPEN_PANEL=0 WITH_DATA=0 INSTALL=0 OLLAMA_SYS=0
SERVICE=0 START=0 DRY=0 SPEC="freellm 5 ollama 1 aether panel"
while (( $# )); do
  case "$1" in
    --dir) DIR="${2:?}"; shift 2 ;;
    --lan-ip) LAN="${2:?}"; shift 2 ;;
    --open-panel) OPEN_PANEL=1; shift ;;
    --with-data) WITH_DATA=1; shift ;;
    --install-packages) INSTALL=1; shift ;;
    --ollama-system-models) OLLAMA_SYS=1; shift ;;
    --service) SERVICE=1; shift ;;
    --services) SPEC="${2:?}"; shift 2 ;;
    --start) START=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) [[ -z "$TARGET" ]] || die "only one user@host"; TARGET="$1"; shift ;;
  esac
done
[[ -n "$TARGET" ]] || usage
HOST="${TARGET#*@}"
if [[ -z "$LAN" && "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then LAN="$HOST"; fi

SSH=(ssh -o ConnectTimeout=10 -o BatchMode=yes "$TARGET")
# Run a script on the remote. In --dry-run, print it instead.
remote()    { if (( DRY )); then printf '    [dry-run] would run on %s:\n%s\n' "$TARGET" "$(sed 's/^/      /' <<<"$1")"; else "${SSH[@]}" "bash -s" <<<"$1"; fi; }
# Read-only checks always run.
remote_ro() { "${SSH[@]}" "bash -s" <<<"$1"; }
q() { printf '%q' "$1"; }

# --- 1. reach the machine ------------------------------------------------------
say "checking $TARGET"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $TARGET without a password. Set up a key: ssh-copy-id $TARGET"
RHOME="$(remote_ro 'printf %s "$HOME"')"
ROS="$(remote_ro 'uname -s')"
[[ -n "$DIR" ]] || DIR="$RHOME/$(basename "$SRC")"
DIR="${DIR/#\~/$RHOME}"
echo "    remote folder: $DIR ($ROS)"
if (( SERVICE || OLLAMA_SYS )) && [[ "$ROS" != Linux ]]; then
  die "--service and --ollama-system-models are for Linux; on macOS start it with ./llm (see docs/DEPLOY.md)"
fi

# --- 2. tools ----------------------------------------------------------------
say "checking tools on the remote"
MISSING="$(remote_ro '
  m=""
  for c in node npm git rsync python3 curl lsof zsh; do command -v $c >/dev/null || m="$m $c"; done
  if command -v node >/dev/null; then
    v=$(node -p "process.versions.node.split(\".\")[0]"); { [ "$v" -ge 20 ] && [ "$v" -lt 25 ]; } || m="$m node(>=20.18,<25;found-$(node -v))"
  fi
  if command -v python3 >/dev/null; then python3 -c "import sys; sys.exit(sys.version_info < (3,10))" || m="$m python3(>=3.10)"; fi
  # zsh: Aether runs the engineers shell commands with /bin/zsh.
  command -v ollama >/dev/null || echo "note: ollama is not installed (only needed for ollama instances)" >&2
  echo $m')"
if [[ -n "$MISSING" ]]; then
  echo "    missing: $MISSING"
  if (( INSTALL )) && [[ "$ROS" == Linux ]]; then
    remote 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q nodejs npm git rsync python3 curl lsof zsh >/dev/null && node -v'
  else
    die "install them first (Debian/Ubuntu: rerun with --install-packages; macOS: brew install node@22 git python), see docs/INSTALL.md"
  fi
else
  echo "    node, npm, git, rsync, python3, curl, lsof, zsh: ok"
fi

# --- 3. keep the remote's own settings ---------------------------------------
# Older deployments kept their LAN IP / token in agents.conf itself. Move those
# lines to agents.local.conf before agents.conf is replaced by the shared one.
say "settings (agents.local.conf)"
HAS_LOCAL="$(remote_ro "test -f $(q "$DIR/agents.local.conf") && echo yes || true")"
HAS_CONF="$(remote_ro "test -f $(q "$DIR/agents.conf") && echo yes || true")"
if [[ "$HAS_LOCAL" == yes ]]; then
  echo "    keeping the remote's agents.local.conf"
elif [[ "$HAS_CONF" == yes ]]; then
  echo "    moving this machine's settings from its old agents.conf into agents.local.conf"
  remote "cd $(q "$DIR") && {
    echo '# This machine'\''s own settings (moved from agents.conf by deploy-remote.sh).'
    grep -E '^(LAN_IP|PANEL_HOST|PANEL_TOKEN|AETHER_CODE_DIR|AETHER_WEB_TOKEN|export )' agents.conf || true
  } > agents.local.conf && chmod 600 agents.local.conf && grep -E '^(LAN_IP|PANEL_HOST|export)' agents.local.conf"
else
  TOKEN=""
  (( OPEN_PANEL )) && TOKEN="$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  LOCAL="# This machine's own settings (written by deploy-remote.sh). See agents.local.conf.example.
LAN_IP=\"\${LAN_IP:-$LAN}\""
  if (( OPEN_PANEL )); then
    LOCAL="$LOCAL
PANEL_HOST=\"\${PANEL_HOST:-0.0.0.0}\"
PANEL_TOKEN=\"\${PANEL_TOKEN:-$TOKEN}\""
  fi
  echo "    creating agents.local.conf (LAN_IP=${LAN:-unset}$( (( OPEN_PANEL )) && echo ', panel on the network with a new token'))"
  remote "mkdir -p $(q "$DIR") && umask 077 && printf '%s\n' $(q "$LOCAL") > $(q "$DIR/agents.local.conf")"
fi
if (( OLLAMA_SYS )); then
  remote "cd $(q "$DIR") && grep -q '^export OLLAMA_MODELS' agents.local.conf 2>/dev/null || printf '%s\n' \
    '# Ollama instances read the models of the Ollama system service.' \
    'export OLLAMA_MODELS=\"\${OLLAMA_MODELS:-/usr/share/ollama/.ollama/models}\"' \
    'export OLLAMA_NOPRUNE=1' >> agents.local.conf"
fi

# --- 4. code -----------------------------------------------------------------
say "copying code to $TARGET:$DIR"
# No --delete: files that exist only on the remote (data, builds, its settings) stay.
RSYNC=(rsync -az -e "ssh -o BatchMode=yes"
  --exclude '/.git/' --exclude '/.app/' --exclude '/.runtime/' --exclude '/.aether-code/'
  --exclude '/agents.local.conf' --exclude 'node_modules/' --exclude '__pycache__/' --exclude '.DS_Store')
(( DRY )) && RSYNC+=(--dry-run --itemize-changes)
"${RSYNC[@]}" "$SRC/" "$TARGET:$DIR/"

# --- 5. build FreeLLMAPI + fetch aether-code (no start) ------------------------
say "preparing FreeLLMAPI and Aether on the remote (clone + build when missing; nothing starts)"
remote "cd $(q "$DIR") && bash -c 'set -e; source ./common.sh; prepare_freellm; prepare_aether' && ls -l .app/server/dist/index.js"

# --- 6. optional: agent data ---------------------------------------------------
if (( WITH_DATA )); then
  say "copying agent data + encryption key (provider keys inside)"
  RUNNING="$(remote_ro "cd $(q "$DIR") 2>/dev/null && ./llm status freellm 2>/dev/null | tail -n +2 | grep -v stopped || true")"
  [[ -z "$RUNNING" ]] || (( DRY )) || die "FreeLLMAPI is running on the remote; stop it first (./llm stop freellm) so its databases are not overwritten while open"
  DRYF=(); (( DRY )) && DRYF=(--dry-run --itemize-changes)
  rsync -az "${DRYF[@]}" -e "ssh -o BatchMode=yes" "$SRC/.app/.env" "$TARGET:$DIR/.app/.env"
  remote "chmod 600 $(q "$DIR/.app/.env")"
  # Only each agent's data/ folder: no logs or pid files.
  rsync -az "${DRYF[@]}" -e "ssh -o BatchMode=yes" \
    --include='agent-*/' --include='agent-*/data/' --include='agent-*/data/**' --exclude='*' \
    "$SRC/.runtime/" "$TARGET:$DIR/.runtime/"
fi

# --- 7. optional: Ollama system models (Linux) ------------------------------------
if (( OLLAMA_SYS )); then
  say "letting $TARGET's user read /usr/share/ollama models"
  remote 'command -v setfacl >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q acl >/dev/null
sudo setfacl -m "u:$(id -un):rx" /usr/share/ollama && getfacl -p /usr/share/ollama 2>/dev/null | grep "^user:$(id -un)"'
fi

# --- 8. optional: systemd user service ----------------------------------------
if (( SERVICE )); then
  say "installing the systemd user service (runs: ./llm start $SPEC)"
  remote "set -e; mkdir -p ~/.config/systemd/user
sed -e $(q "s|@DIR@|$DIR|g") -e $(q "s|@SERVICES@|$SPEC|g") $(q "$DIR/deploy/freellmapi-agents.service") > ~/.config/systemd/user/freellmapi-agents.service
sudo loginctl enable-linger \"\$(id -un)\"
systemctl --user daemon-reload
systemctl --user enable freellmapi-agents.service"
fi

# --- 9. optional: start --------------------------------------------------------------
if (( START )); then
  say "starting"
  if (( SERVICE )) || [[ "$(remote_ro 'systemctl --user is-enabled freellmapi-agents.service 2>/dev/null || true')" == enabled ]]; then
    remote "systemctl --user restart freellmapi-agents.service && cd $(q "$DIR") && ./llm status"
  else
    remote "cd $(q "$DIR") && ./llm start $SPEC"
  fi
fi

# --- summary -----------------------------------------------------------------------
say "done$( (( DRY )) && echo ' (dry run: nothing was changed)')"
cat <<EOF
    folder:  $TARGET:$DIR
    start:   ssh $TARGET 'cd $DIR && ./llm start $SPEC'
    status:  ssh $TARGET 'cd $DIR && ./llm status'
    panel:   http://${LAN:-<host>}:3900/#token=<PANEL_TOKEN from $DIR/agents.local.conf>
             (only with PANEL_HOST=0.0.0.0 there; otherwise http://localhost:3900 on that machine)
EOF
