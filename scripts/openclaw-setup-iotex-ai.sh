#!/usr/bin/env bash
# Setup IoTeX AI Gateway for OpenClaw
#
# Non-interactive (all params):
#   curl -fsSL https://docs.iotex.ai/scripts/setup-openclaw.sh | bash -s -- API_KEY [MODEL] [AUDIO_MODEL] [--default]
#
# Interactive:
#   curl -fsSL https://docs.iotex.ai/scripts/setup-openclaw.sh | bash
#   bash setup-openclaw.sh
#
# Examples:
#   bash setup-openclaw.sh sk-xxx                                          # defaults: gemini-2.5-flash-lite + whisper-large-v3-turbo
#   bash setup-openclaw.sh sk-xxx gemini-2.5-flash                         # pick LLM, default audio
#   bash setup-openclaw.sh sk-xxx gemini-2.5-flash-lite whisper-1 --default  # full non-interactive + set as default
#
set -euo pipefail

# ── Available models ──────────────────────────────────────────────────
LLM_MODELS=(
  "gemini-2.5-flash-lite|Gemini 2.5 Flash Lite|Google|\$0.10/\$0.40 per 1M tokens"
  "gemini-2.5-flash|Gemini 2.5 Flash|Google|\$0.30/\$2.50 per 1M tokens"
  "gemini-3-flash-preview|Gemini 3 Flash Preview|Google|\$0.50/\$3.00 per 1M tokens"
  "deepseek-ai/DeepSeek-V3-0324|DeepSeek V3|DeepSeek|\$0.27/\$0.88 per 1M tokens"
  "deepseek-ai/DeepSeek-R1-0528|DeepSeek R1 (reasoning)|DeepSeek|\$0.50/\$2.15 per 1M tokens"
  "Qwen/Qwen3-30B-A3B|Qwen3 30B|Qwen|\$0.08/\$0.29 per 1M tokens"
  "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8|Llama 4 Maverick|Meta|\$0.15/\$0.60 per 1M tokens"
  "gpt-4o-mini|GPT-4o Mini|OpenAI|\$0.15/\$0.60 per 1M tokens"
)

AUDIO_MODELS=(
  "openai/whisper-large-v3-turbo|Whisper Large V3 Turbo (fast)|\$0.0015/min"
  "openai/whisper-large-v3|Whisper Large V3 (standard)|\$0.0030/min"
  "whisper-1|Whisper 1 (legacy)|\$0.0060/min"
)

# ── Parse args ────────────────────────────────────────────────────────
API_KEY=""
LLM_MODEL=""
AUDIO_MODEL=""
SET_DEFAULT=false

for arg in "$@"; do
  case "$arg" in
    --default) SET_DEFAULT=true ;;
    sk-*)      API_KEY="$arg" ;;
    *)
      if [ -z "$LLM_MODEL" ]; then
        LLM_MODEL="$arg"
      elif [ -z "$AUDIO_MODEL" ]; then
        AUDIO_MODEL="$arg"
      fi
      ;;
  esac
done

# ── Interactive prompts ───────────────────────────────────────────────
pick_from_menu() {
  local prompt="$1"
  shift
  local options=("$@")
  local count=${#options[@]}

  echo ""
  echo "$prompt"
  echo ""
  for i in "${!options[@]}"; do
    IFS='|' read -r id name provider price <<< "${options[$i]}"
    local num=$((i + 1))
    local marker=""
    if [ "$num" -eq 1 ]; then marker=" (recommended)"; fi
    printf "  %d) %-45s %s%s\n" "$num" "$name ($id)" "$price" "$marker"
  done
  echo ""

  local choice
  printf "Choose [1-%d, default=1]: " "$count"
  read -r choice </dev/tty 2>/dev/null || choice=""
  choice="${choice:-1}"

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
    choice=1
  fi

  IFS='|' read -r PICKED_ID _ <<< "${options[$((choice - 1))]}"
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local yn
  if [ "$default" = "y" ]; then
    printf "%s [Y/n]: " "$prompt"
  else
    printf "%s [y/N]: " "$prompt"
  fi
  read -r yn </dev/tty 2>/dev/null || yn=""
  yn="${yn:-$default}"
  case "$yn" in
    [Yy]*) return 0 ;;
    *)     return 1 ;;
  esac
}

if [ -z "$API_KEY" ]; then
  echo ""
  echo "  IoTeX AI Gateway — OpenClaw Setup"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  printf "  API key (get one at https://gateway.iotex.ai/console/token): "
  read -r API_KEY </dev/tty 2>/dev/null || API_KEY=""
fi

if [ -z "$API_KEY" ]; then
  echo "Error: API key is required."
  exit 1
fi

if [ -z "$LLM_MODEL" ]; then
  pick_from_menu "Select an LLM model:" "${LLM_MODELS[@]}"
  LLM_MODEL="$PICKED_ID"
fi

if [ -z "$AUDIO_MODEL" ]; then
  pick_from_menu "Select an audio transcription model:" "${AUDIO_MODELS[@]}"
  AUDIO_MODEL="$PICKED_ID"
fi

if [ "$SET_DEFAULT" = false ] && [ -t 0 ]; then
  echo ""
  if ask_yes_no "  Set iotex/$LLM_MODEL as your default model?" "n"; then
    SET_DEFAULT=true
  fi
fi

# ── Preflight checks ─────────────────────────────────────────────────
if ! command -v openclaw &>/dev/null; then
  echo "Error: openclaw not found. Install it first: npm install -g openclaw"
  exit 1
fi

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
CONFIG="$OPENCLAW_DIR/openclaw.json"
if [ ! -f "$CONFIG" ]; then
  echo "Error: $CONFIG not found. Run 'openclaw onboard' first."
  exit 1
fi

# ── Build model alias from ID ────────────────────────────────────────
# "gemini-2.5-flash-lite" → "gemini-lite", "deepseek-ai/DeepSeek-V3-0324" → "deepseek-v3"
make_alias() {
  local id="$1"
  # take part after / if present
  local base="${id##*/}"
  # lowercase, keep alphanumeric and hyphens, collapse
  base=$(echo "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
  # shorten common patterns
  base=$(echo "$base" | sed 's/instruct.*//;s/-fp[0-9]*//;s/-0[0-9]*$//;s/-large-v3-turbo//' | sed 's/-$//')
  echo "$base"
}

LLM_ALIAS=$(make_alias "$LLM_MODEL")

# ── Apply config ──────────────────────────────────────────────────────
echo ""
echo "==> Adding IoTeX provider (model: $LLM_MODEL)..."

DEFAULT_MODEL_PATCH=""
if [ "$SET_DEFAULT" = true ]; then
  DEFAULT_MODEL_PATCH=', "model": { "primary": "iotex/'"$LLM_MODEL"'" }'
fi

openclaw config patch "$(cat <<EOF
{
  "models": {
    "providers": {
      "iotex": {
        "baseUrl": "https://gateway.iotex.ai/v1",
        "apiKey": "$API_KEY",
        "api": "openai-completions",
        "models": [
          {
            "id": "$LLM_MODEL",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 200000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "models": {
        "iotex/$LLM_MODEL": { "alias": "$LLM_ALIAS" }
      }
      $DEFAULT_MODEL_PATCH
    }
  },
  "auth": {
    "profiles": {
      "iotex:default": { "provider": "iotex", "mode": "api_key" }
    }
  },
  "tools": {
    "media": {
      "audio": {
        "enabled": true,
        "models": [
          {
            "provider": "openai",
            "model": "$AUDIO_MODEL",
            "baseUrl": "https://gateway.iotex.ai/v1",
            "profile": "iotex:default",
            "type": "provider"
          }
        ]
      }
    }
  }
}
EOF
)"

echo "==> Setting up auth profile..."
AGENT_DIR="$OPENCLAW_DIR/agents/main/agent"
mkdir -p "$AGENT_DIR"
AUTH_FILE="$AGENT_DIR/auth-profiles.json"

node -e "
const fs = require('fs');
const file = process.argv[1];
const key  = process.argv[2];
let store = { version: 1, profiles: {} };
try { store = JSON.parse(fs.readFileSync(file, 'utf-8')); } catch {}
store.profiles = store.profiles || {};
store.profiles['iotex:default'] = { type: 'api_key', provider: 'iotex', key };
fs.writeFileSync(file, JSON.stringify(store, null, 2) + '\n');
" "$AUTH_FILE" "$API_KEY"

echo "==> Restarting gateway..."
openclaw gateway restart 2>/dev/null || true
sleep 3

echo ""
echo "  Done! IoTeX AI Gateway is configured."
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  LLM:    iotex/$LLM_MODEL (alias: $LLM_ALIAS)"
echo "  Audio:  $AUDIO_MODEL (auto-transcribes voice messages)"
if [ "$SET_DEFAULT" = true ]; then
  echo "  Default model set to: iotex/$LLM_MODEL"
else
  echo ""
  echo "  To set as default model:"
  echo "    openclaw config patch '{\"agents\":{\"defaults\":{\"model\":{\"primary\":\"iotex/$LLM_MODEL\"}}}}'"
fi
echo ""
echo "  Switch models in chat:  /model $LLM_ALIAS"
echo "  Verify:                 openclaw gateway health"
echo ""
