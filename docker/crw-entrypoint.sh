#!/usr/bin/env bash
#
# Entrypoint for the self-contained crw image (`--target runtime-js`).
#
# The lean image (`--target runtime`, the default build target, and what
# docker-compose.yml builds) ships no JS renderer: it expects a CDP sidecar,
# which is what Compose wires up. `--target runtime-js` bakes Chromium in
# instead, so a plain `docker run` can render JS with no sidecar. This script
# starts whatever the build included, points the engine's config at it, waits
# for the CDP endpoint to actually answer, and only then hands off to the
# container's CMD.
#
# Two rules it never breaks:
#   - an operator-set CDP endpoint always wins (a Compose sidecar or a remote
#     browser must never be shadowed by a local one);
#   - a missing or dead backend degrades to "no renderer", it does not take the
#     server down. The engine already reports the renderer as unavailable and
#     falls back per its ladder.
#
# Backends are selected by CRW_JS_BACKENDS (`lightpanda`, `chrome`, or both),
# baked in as an ENV by the image stage that built them. Only `chrome` is
# shipped today: upstream's LightPanda Linux binaries need GLIBC_2.38 and the
# base image has 2.36. The LightPanda branch below is live code, not dead
# weight — add `lightpanda` to CRW_JS_BACKENDS in a derived image built on a
# newer base and it starts.
set -euo pipefail

LIGHTPANDA_PORT=9222
CHROME_PORT=9223
READY_ATTEMPTS=100
READY_INTERVAL_SECS=0.2

# Mirrors the CIDRs docker-compose.yml passes to the LightPanda sidecar. The
# engine validates every intercepted CDP request, but it cannot see websockets
# or worker targets, so the browser enforces the same boundary itself.
LIGHTPANDA_BLOCK_CIDRS="0.0.0.0/8,10.0.0.0/8,127.0.0.0/8,169.254.0.0/16,\
172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,224.0.0.0/4,240.0.0.0/4,\
192.0.0.0/24,192.0.2.0/24,198.18.0.0/15,198.51.100.0/24,203.0.113.0/24,\
fc00::/7,fe80::/10,fec0::/10,ff00::/8,::/96,64:ff9b:1::/48,2002::/16"

pids=()

log() {
  printf '[entrypoint] %s\n' "$*" >&2
}

# `case` rather than a loop so an empty CRW_JS_BACKENDS means "none" instead of
# matching everything.
wants_backend() {
  case ",${CRW_JS_BACKENDS:-}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# TCP connect is exactly what the Compose healthchecks use, so it needs no
# extra package in the runtime image (no curl/wget there).
wait_for_port() {
  local port="$1" label="$2" attempt=1
  while [ "$attempt" -le "$READY_ATTEMPTS" ]; do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      log "${label} is accepting connections on 127.0.0.1:${port}"
      return 0
    fi
    sleep "$READY_INTERVAL_SECS"
    attempt=$((attempt + 1))
  done
  log "WARNING: ${label} did not open 127.0.0.1:${port} within $((READY_ATTEMPTS / 5))s"
  log "WARNING: continuing without it — JS requests will report this renderer as unavailable"
  return 0
}

start_lightpanda() {
  local bin=/usr/local/bin/lightpanda
  if [ ! -x "$bin" ]; then
    log "no LightPanda in this image; skipping"
    return 0
  fi
  if [ -n "${CRW_RENDERER__LIGHTPANDA__WS_URL:-}" ]; then
    log "CRW_RENDERER__LIGHTPANDA__WS_URL='${CRW_RENDERER__LIGHTPANDA__WS_URL}' is already set; leaving the bundled LightPanda stopped"
    return 0
  fi
  log "starting LightPanda on 127.0.0.1:${LIGHTPANDA_PORT}"
  "$bin" serve \
    --host 127.0.0.1 \
    --port "$LIGHTPANDA_PORT" \
    --log-level info \
    --block-private-networks \
    --block-cidrs "$LIGHTPANDA_BLOCK_CIDRS" &
  pids+=("$!")
  # Exported before the CMD starts so the engine's config (config.default.toml
  # already points at this port, but a CRW_CONFIG override may not) sees it.
  export CRW_RENDERER__LIGHTPANDA__WS_URL="ws://127.0.0.1:${LIGHTPANDA_PORT}/"
  wait_for_port "$LIGHTPANDA_PORT" LightPanda
}

start_chrome() {
  local bin=""
  local candidate
  for candidate in /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome; do
    if [ -x "$candidate" ]; then
      bin="$candidate"
      break
    fi
  done
  if [ -z "$bin" ]; then
    log "no Chromium in this image; skipping"
    return 0
  fi
  if [ -n "${CRW_RENDERER__CHROME__WS_URL:-}" ]; then
    log "CRW_RENDERER__CHROME__WS_URL='${CRW_RENDERER__CHROME__WS_URL}' is already set; leaving the bundled Chromium stopped"
    return 0
  fi
  log "starting Chromium (headless) on 127.0.0.1:${CHROME_PORT}"
  # --no-sandbox: the container is the sandbox; Chromium's own sandbox needs
  #   privileges this image deliberately does not carry.
  # --disable-dev-shm-usage: /dev/shm defaults to 64MB in Docker, which crashes
  #   renderers on heavy pages.
  # --ignore-certificate-errors / --disable-http2: same two anti-bot dodges the
  #   Compose chrome tier passes (expired-cert sites, JA4-mismatch hosts).
  # --disable-background-networking / --disable-component-update: the Compose
  #   tier inherits chromedp/headless-shell's own entrypoint defaults; this
  #   image starts the distro binary directly, so it has to opt into the same
  #   quiet behaviour (no component updates, no background service traffic).
  #   Chromium can still log a one-shot GCM registration line at startup — that
  #   is the browser, not crw, and it is the same line the Compose tier emits.
  # --remote-debugging-address=127.0.0.1: the CDP port stays inside the
  #   container; never publish it.
  "$bin" \
    --headless=new \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --disable-background-networking \
    --disable-component-update \
    --no-first-run \
    --no-default-browser-check \
    --remote-debugging-address=127.0.0.1 \
    --remote-debugging-port="$CHROME_PORT" \
    --remote-allow-origins='*' \
    --ignore-certificate-errors \
    --disable-http2 \
    --disable-blink-features=AutomationControlled \
    --user-data-dir=/tmp/crw-chrome \
    about:blank &
  pids+=("$!")
  export CRW_RENDERER__CHROME__WS_URL="ws://127.0.0.1:${CHROME_PORT}/"
  wait_for_port "$CHROME_PORT" Chromium
}

stop_backends() {
  local pid
  if [ "${#pids[@]}" -eq 0 ]; then
    return 0
  fi
  log "stopping bundled backends"
  for pid in "${pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

main_pid=""
on_signal() {
  log "received SIG${1}; shutting down"
  # Forward first so the engine can finish in-flight work, then reap backends.
  if [ -n "$main_pid" ]; then
    kill "-${1}" "$main_pid" 2>/dev/null || true
  fi
  stop_backends
  exit 0
}
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT

if wants_backend lightpanda; then
  start_lightpanda
fi
if wants_backend chrome; then
  start_chrome
fi

if [ "${#pids[@]}" -eq 0 ]; then
  log "CRW_JS_BACKENDS='${CRW_JS_BACKENDS:-}' started no backend; running '$*' with a sidecar/remote renderer (or none)"
fi

# config.default.toml configures LightPanda at ws://127.0.0.1:9222, so an image
# that does not ship it still advertises the tier and burns a discovery attempt
# on every JS request before the ladder falls through. Say so once, with the way
# out, instead of leaving the operator with a bare "CDP discovery failed".
if wants_backend lightpanda && [ ! -x /usr/local/bin/lightpanda ] \
   && [ -z "${CRW_RENDERER__LIGHTPANDA__WS_URL:-}" ]; then
  log "NOTE: config.default.toml points LightPanda at 127.0.0.1:9222 but no LightPanda is bundled."
  log "      JS requests fall through to Chromium; to drop the wasted hop, run the Compose"
  log "      LightPanda sidecar and set CRW_RENDERER__LIGHTPANDA__WS_URL=ws://<host>:9222, or pin renderer=chrome per request."
fi

"$@" &
main_pid="$!"

# Not `exec`: the backends are this script's children and would be orphaned by
# an exec, leaving them running until the container's kill grace period.
# `|| status=$?` keeps `set -e` from treating a non-zero CMD exit as a failure
# of the entrypoint itself.
status=0
wait "$main_pid" || status=$?

stop_backends
exit "$status"
