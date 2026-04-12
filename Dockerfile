# NemoClaw sandbox image — OpenClaw + NemoClaw plugin inside OpenShell
#
# Layers PR-specific code (plugin, blueprint, config, startup script) on top
# of the pre-built base image from GHCR. The base image contains all the
# expensive, rarely-changing layers (apt, gosu, users, openclaw CLI).
#
# For local builds without GHCR access, build the base first:
#   docker build -f Dockerfile.base -t ghcr.io/nvidia/nemoclaw/sandbox-base:latest .

# Global ARG — must be declared before the first FROM to be visible
# to all FROM directives. Can be overridden via --build-arg.
ARG BASE_IMAGE=ghcr.io/nvidia/nemoclaw/sandbox-base:latest

# Stage 1: Build TypeScript plugin from source
FROM node:22-slim@sha256:4f77a690f2f8946ab16fe1e791a3ac0667ae1c3575c3e4d0d4589e9ed5bfaf3d AS builder
COPY nemoclaw/package.json nemoclaw/package-lock.json nemoclaw/tsconfig.json /opt/nemoclaw/
COPY nemoclaw/src/ /opt/nemoclaw/src/
WORKDIR /opt/nemoclaw
RUN npm ci && npm run build

# Stage 2: Runtime image — pull cached base from GHCR
FROM ${BASE_IMAGE}

# Base image provides system packages, users/groups, openclaw runtime layout,
# global tooling (openclaw, playwright, mcporter, etc.), and Python deps.

# Copy built plugin and blueprint into the sandbox
COPY --from=builder /opt/nemoclaw/dist/ /opt/nemoclaw/dist/
COPY nemoclaw/openclaw.plugin.json /opt/nemoclaw/
COPY nemoclaw/package.json nemoclaw/package-lock.json /opt/nemoclaw/
COPY nemoclaw-blueprint/ /opt/nemoclaw-blueprint/

# Install runtime dependencies only (no devDependencies, no build step)
WORKDIR /opt/nemoclaw
RUN npm ci --omit=dev

# Set up blueprint for local resolution
RUN mkdir -p /sandbox/.nemoclaw/blueprints/0.1.0 \
    && cp -r /opt/nemoclaw-blueprint/* /sandbox/.nemoclaw/blueprints/0.1.0/

# Copy startup script
COPY scripts/nemoclaw-start.sh /usr/local/bin/nemoclaw-start
RUN chmod 755 /usr/local/bin/nemoclaw-start

# Build args for config that varies per deployment.
# nemoclaw onboard passes these at image build time.
ARG NEMOCLAW_MODEL=nvidia/nemotron-3-super-120b-a12b
ARG NEMOCLAW_PROVIDER_KEY=nvidia
ARG NEMOCLAW_PRIMARY_MODEL_REF=nvidia/nemotron-3-super-120b-a12b
ARG CHAT_UI_URL=http://127.0.0.1:18789
ARG NEMOCLAW_INFERENCE_BASE_URL=https://inference.local/v1
ARG NEMOCLAW_INFERENCE_API=openai-completions
ARG NEMOCLAW_INFERENCE_COMPAT_B64=e30=
ARG NEMOCLAW_WEB_CONFIG_B64=e30=
ARG NEMOCLAW_SKILL_ENV_B64=e30=
# Base64-encoded JSON list of messaging channel names to pre-configure
# (e.g. ["discord","telegram"]). Channels are added with placeholder tokens
# so the OpenShell provider pipeline can resolve them at runtime.
ARG NEMOCLAW_MESSAGING_CHANNELS_B64=W10=
# Base64-encoded JSON map of channel->allowed sender IDs for DM allowlisting
# (e.g. {"telegram":["123456789"]}). Default: empty map.
ARG NEMOCLAW_MESSAGING_ALLOWED_IDS_B64=e30=
# Base64-encoded JSON map of Discord guild configs keyed by server ID.
ARG NEMOCLAW_DISCORD_GUILDS_B64=e30=
# Set to "1" to disable device-pairing auth (development/headless only).
# Default: "0" (device auth enabled — secure by default).
ARG NEMOCLAW_DISABLE_DEVICE_AUTH=0
# Unique per build to ensure each image gets a fresh auth token.
# Pass --build-arg NEMOCLAW_BUILD_ID=$(date +%s) to bust the cache.
ARG NEMOCLAW_BUILD_ID=default

# SECURITY: Promote build-args to env vars so the Python script reads them
# via os.environ, never via string interpolation into Python source code.
# Direct ARG interpolation into python3 -c is a code injection vector (C-2).
ENV NEMOCLAW_MODEL=${NEMOCLAW_MODEL} \
    NEMOCLAW_PROVIDER_KEY=${NEMOCLAW_PROVIDER_KEY} \
    NEMOCLAW_PRIMARY_MODEL_REF=${NEMOCLAW_PRIMARY_MODEL_REF} \
    CHAT_UI_URL=${CHAT_UI_URL} \
    NEMOCLAW_INFERENCE_BASE_URL=${NEMOCLAW_INFERENCE_BASE_URL} \
    NEMOCLAW_INFERENCE_API=${NEMOCLAW_INFERENCE_API} \
    NEMOCLAW_INFERENCE_COMPAT_B64=${NEMOCLAW_INFERENCE_COMPAT_B64} \
    NEMOCLAW_WEB_CONFIG_B64=${NEMOCLAW_WEB_CONFIG_B64} \
    NEMOCLAW_SKILL_ENV_B64=${NEMOCLAW_SKILL_ENV_B64} \
    NEMOCLAW_MESSAGING_CHANNELS_B64=${NEMOCLAW_MESSAGING_CHANNELS_B64} \
    NEMOCLAW_MESSAGING_ALLOWED_IDS_B64=${NEMOCLAW_MESSAGING_ALLOWED_IDS_B64} \
    NEMOCLAW_DISCORD_GUILDS_B64=${NEMOCLAW_DISCORD_GUILDS_B64} \
    NEMOCLAW_DISABLE_DEVICE_AUTH=${NEMOCLAW_DISABLE_DEVICE_AUTH}

WORKDIR /sandbox
USER sandbox

# Write the COMPLETE openclaw.json including gateway config and auth token.
# Default runtime mode is secure (read-only + integrity hash enforced).
# Optional runtime override NEMOCLAW_ALLOW_CONFIG_WRITES=1 can relax this at
# container start for controlled debugging workflows.
# Build args (NEMOCLAW_MODEL, CHAT_UI_URL) customize per deployment.
# Auth token is generated per build so each image has a unique token.
RUN python3 -c "\
import base64, json, os, secrets; \
from urllib.parse import urlparse; \
model = os.environ['NEMOCLAW_MODEL']; \
chat_ui_url = os.environ['CHAT_UI_URL']; \
provider_key = os.environ['NEMOCLAW_PROVIDER_KEY']; \
primary_model_ref = os.environ['NEMOCLAW_PRIMARY_MODEL_REF']; \
inference_base_url = os.environ['NEMOCLAW_INFERENCE_BASE_URL']; \
inference_api = os.environ['NEMOCLAW_INFERENCE_API']; \
inference_compat = json.loads(base64.b64decode(os.environ['NEMOCLAW_INFERENCE_COMPAT_B64']).decode('utf-8')); \
web_config = json.loads(base64.b64decode(os.environ.get('NEMOCLAW_WEB_CONFIG_B64', 'e30=') or 'e30=').decode('utf-8')); \
msg_channels = json.loads(base64.b64decode(os.environ.get('NEMOCLAW_MESSAGING_CHANNELS_B64', 'W10=') or 'W10=').decode('utf-8')); \
allowed_ids = json.loads(base64.b64decode(os.environ.get('NEMOCLAW_MESSAGING_ALLOWED_IDS_B64', 'e30=') or 'e30=').decode('utf-8')); \
discord_guilds = json.loads(base64.b64decode(os.environ.get('NEMOCLAW_DISCORD_GUILDS_B64', 'e30=') or 'e30=').decode('utf-8')); \
token_keys = {'discord': 'token', 'telegram': 'botToken', 'slack': 'botToken'}; \
env_keys = {'discord': 'DISCORD_BOT_TOKEN', 'telegram': 'TELEGRAM_BOT_TOKEN', 'slack': 'SLACK_BOT_TOKEN'}; \
channel_cfg = {ch: {'accounts': {'default': {token_keys[ch]: f'openshell:resolve:env:{env_keys[ch]}', 'enabled': True, **({'groupPolicy': 'open'} if ch == 'telegram' else {}), **({'dmPolicy': 'allowlist', 'allowFrom': allowed_ids[ch]} if ch in allowed_ids and allowed_ids[ch] else {})}}} for ch in msg_channels if ch in token_keys}; \
channel_cfg['discord'].update({'groupPolicy': 'allowlist', 'guilds': discord_guilds}) if 'discord' in channel_cfg and discord_guilds else None; \
parsed = urlparse(chat_ui_url); \
chat_origin = f'{parsed.scheme}://{parsed.netloc}' if parsed.scheme and parsed.netloc else 'http://127.0.0.1:18789'; \
origins = ['http://127.0.0.1:18789']; \
origins = list(dict.fromkeys(origins + [chat_origin])); \
config = { \
    'agents': {'defaults': {'model': {'primary': f'inference/{model}'}}}, \
    'models': {'mode': 'merge', 'providers': { \
        'nvidia': { \
            'baseUrl': 'https://inference.local/v1', \
            'apiKey': 'openshell-managed', \
            'api': 'openai-completions', \
            'models': [{'id': model.split('/')[-1], 'name': model, 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}] \
        }, \
        'inference': { \
            'baseUrl': 'https://inference.local/v1', \
            'apiKey': 'unused', \
            'api': 'openai-completions', \
            'models': [{'id': model, 'name': model, 'reasoning': False, 'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}, 'contextWindow': 131072, 'maxTokens': 4096}] \
        } \
    }}, \
    'channels': dict({'defaults': {'configWrites': False}}, **channel_cfg), \
    'messages': {'tts': {'auto': 'inbound', 'provider': 'openai', 'providers': {'openai': {'apiKey': 'openshell:resolve:env:OPENAI_API_KEY', 'baseUrl': 'https://api.openai.com/v1', 'model': 'gpt-4o-mini-tts', 'voice': 'alloy'}}}}, \
    'tools': {'media': {'audio': {'enabled': True, 'maxBytes': 20971520, 'echoTranscript': False, 'models': [{'type': 'cli', 'command': 'whisper', 'args': ['--model', 'base', '--language', 'en', '{{MediaPath}}'], 'timeoutSeconds': 120}]}}}, \
    'gateway': { \
        'mode': 'local', \
        'controlUi': { \
            'allowInsecureAuth': True, \
            'dangerouslyDisableDeviceAuth': True, \
            'allowedOrigins': origins, \
        }, \
        'trustedProxies': ['127.0.0.1', '::1'], \
        'auth': {'token': secrets.token_hex(32)} \
    } \
}; \
config.setdefault('tools', {}).update({'web': { \
        'search': { \
            'enabled': True, \
            'provider': 'brave', \
            **({'apiKey': web_config.get('apiKey', '')} if web_config.get('apiKey', '') else {}) \
        }, \
        'fetch': { \
            'enabled': bool(web_config.get('fetchEnabled', True)) \
        } \
    }} if web_config.get('provider') == 'brave' else {}); \
path = os.path.expanduser('~/.openclaw/openclaw.json'); \
json.dump(config, open(path, 'w'), indent=2); \
os.chmod(path, 0o600)"

# Install NemoClaw plugin into OpenClaw
RUN openclaw doctor --fix > /dev/null 2>&1 || true \
    && openclaw plugins install /opt/nemoclaw > /dev/null 2>&1 || true

# Lock openclaw.json via DAC: chown to root so the sandbox user cannot modify
# it at runtime.  This works regardless of Landlock enforcement status.
# The Landlock policy (/sandbox/.openclaw in read_only) provides defense-in-depth
# once OpenShell enables enforcement.
# Ref: https://github.com/NVIDIA/NemoClaw/issues/514
# Lock the entire .openclaw directory tree.
# SECURITY: chmod 755 (not 1777) — the sandbox user can READ but not WRITE
# to this directory. This prevents the agent from replacing symlinks
# (e.g., pointing /sandbox/.openclaw/hooks to an attacker-controlled path).
# The writable state lives in .openclaw-data, reached via the symlinks.
# hadolint ignore=DL3002
USER root
RUN chown root:root /sandbox/.openclaw \
    && find /sandbox/.openclaw -mindepth 1 -maxdepth 1 -exec chown -h root:root {} + \
    && chmod 1777 /sandbox/.openclaw \
    && chmod 444 /sandbox/.openclaw/openclaw.json
USER sandbox

# Pin config hash at build time so the entrypoint can verify integrity.
# Prevents the agent from creating a copy with a tampered config and
# restarting the gateway pointing at it.
USER root
RUN sha256sum /sandbox/.openclaw/openclaw.json > /sandbox/.openclaw/.config-hash \
    && chmod 444 /sandbox/.openclaw/.config-hash \
    && chown root:root /sandbox/.openclaw/.config-hash
USER sandbox

# Entrypoint runs as root to start the gateway as the gateway user,
# then drops to sandbox for agent commands. See nemoclaw-start.sh.
ENTRYPOINT ["/usr/local/bin/nemoclaw-start"]
CMD ["/bin/bash"]
