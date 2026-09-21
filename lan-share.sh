#!/usr/bin/env bash
# cliamp-dock LAN share helper — low-latency synced multiroom via Snapcast,
# plus an HTTP MP3 fallback via ffmpeg.
#
# No root required. LAN-only by design (binds 0.0.0.0 on RFC1918 interface;
# open the Snapcast ports + HTTP fallback port in your firewall).
# Ports are configurable: defaults are Snapcast stream 1704 / control 1705 /
# web 1780, HTTP fallback 8099.
#
# Layout (per-user, no sticky-dir FIFO issues):
#   $HOME/.cache/cliamp-dock/snapfifo        PCM pipe snapserver reads
#   $HOME/.cache/cliamp-dock/snapserver.conf generated config
#   $HOME/.cache/cliamp-dock/snapserver.ports  chosen ports "stream control web"
#   $HOME/.cache/cliamp-dock/snapclient.target "host stream-port web-port"
#   $HOME/.cache/cliamp-dock/*.pid           daemon pids
#   $HOME/.cache/cliamp-dock/*.log           daemon logs
#
# Single-mode: share (server) and listen (client) are mutually exclusive;
# starting one stops the other. snapclient always dials the STREAM port
# (default 1704); the control port (default 1705) is JSON-RPC only.
#
# Usage:
#   lan-share.sh check                    -> JSON {snapserver,snapclient,ffmpeg}
#   lan-share.sh status --json            -> JSON {sharing,listening,...}
#   lan-share.sh share-start [stream [control [web [monitor]]]]
#                                         -> start snapserver + ffmpeg feeder
#                                            (empty monitor = default sink)
#   lan-share.sh share-stop               -> stop both
#   lan-share.sh silent-sink              -> create null sink, route cliamp
#                                            into it (silent room, full
#                                            stream). Prints {"monitor":...}
#   lan-share.sh silent-toggle            -> flip room silent <-> speakers
#                                            (stream unaffected).
#                                            Prints {"silent":..,"monitor":..}
#   lan-share.sh listen-start <host> [stream-port [web-port]]
#                                         -> start snapclient to <host>
#   lan-share.sh listen-volume <host> <web-port> [percent]
#                                         -> get/set this dock's listen volume
#                                            (per-client volume on the sharer,
#                                            independent of the server's player
#                                            volume). Prints {"volume":N}.
#   lan-share.sh listen-stop
#   lan-share.sh http-start [port]        -> ffmpeg MP3 listen-mode fallback
#   lan-share.sh http-stop
#   lan-share.sh ip                       -> first non-loopback IPv4
set -u

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/cliamp-dock"
FIFO="$CACHE/snapfifo"
CONF="$CACHE/snapserver.conf"
SERVER_PID="$CACHE/snapserver.pid"
FEEDER_PID="$CACHE/snap-feeder.pid"
CLIENT_PID="$CACHE/snapclient.pid"
HTTP_PID="$CACHE/cliamp-http.pid"
SERVER_LOG="$CACHE/snapserver.log"
FEEDER_LOG="$CACHE/snap-feeder.log"
CLIENT_LOG="$CACHE/snapclient.log"
HTTP_LOG="$CACHE/cliamp-http.log"
PORTS_FILE="$CACHE/snapserver.ports"
CLIENT_TARGET="$CACHE/snapclient.target"
SHARE_MON_FILE="$CACHE/share.monitor"
SILENT_SINK="cliamp-silent"

DEF_STREAM=1704
DEF_CONTROL=1705
DEF_WEB=1780
DEF_HTTP=8099

mkdir -p "$CACHE"

have() { command -v "$1" >/dev/null 2>&1; }

# Prints a sanitized port (fallback to $2 when out of range/non-numeric).
valid_port() {
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2"; return ;;
  esac
  if [ "$1" -ge 1024 ] && [ "$1" -le 65535 ] 2>/dev/null; then printf '%s' "$1";
  else printf '%s' "$2"; fi
}

# Current share ports as "stream control web" (defaults when never started).
share_ports() {
  if [ -f "$PORTS_FILE" ]; then
    cat "$PORTS_FILE" 2>/dev/null
  else
    printf '%s %s %s' "$DEF_STREAM" "$DEF_CONTROL" "$DEF_WEB"
  fi
}

lan_ip() {
  local ip=""
  ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -n1) || true
  if [ -z "$ip" ] && have ip; then
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oE '(10\.[0-9.]+|192\.168\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+)' | head -n1 | cut -d/ -f1) || true
  fi
  printf '%s' "$ip"
}

default_monitor() {
  local sink=""
  if have pactl; then
    sink="$(pactl get-default-sink 2>/dev/null || true)"
    if [ -n "$sink" ]; then echo "${sink}.monitor"; return; fi
    # fallback: first monitor source
    pactl list short sources 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 ~ /monitor$/ {print $2; exit}'
    return
  fi
  echo ""
}

# Monitor actually being shared (persisted at share-start), else default.
active_monitor() {
  local spid; spid="$(read_pid "$SERVER_PID")"
  if alive "$spid" && [ -f "$SHARE_MON_FILE" ]; then
    cat "$SHARE_MON_FILE" 2>/dev/null
  else
    default_monitor
  fi
}

monitor_exists() {
  # $1 = monitor source name; true if Pulse/PipeWire has it right now.
  pactl list short sources 2>/dev/null | awk -v m="$1" '$2 == m {found=1} END {exit !found}'
}

# Ensure our silent sink exists (stream without local playback) and
# print its monitor name.
silent_sink_ensure() {
  have pactl || { echo "missing: pactl" >&2; return 3; }
  if ! monitor_exists "${SILENT_SINK}.monitor"; then
    pactl load-module module-null-sink "sink_name=$SILENT_SINK" "sink_properties=device.description=$SILENT_SINK" >/dev/null || return 4
    sleep 1
  fi
  monitor_exists "${SILENT_SINK}.monitor" || { echo "silent sink failed to appear" >&2; return 4; }
  printf '%s.monitor' "$SILENT_SINK"
}

cmd_silent_sink() {
  # Route cliamp into a null sink so the room stays silent while the
  # stream keeps full audio. Idempotent. Prints {"monitor":...}.
  have pactl || { echo "missing: pactl" >&2; return 3; }
  local mon; mon="$(silent_sink_ensure)" || return $?
  if have cliamp; then
    cliamp device "$SILENT_SINK" >/dev/null 2>&1 || true
  fi
  printf '{"monitor":"%s","sink":"%s"}\n' "$mon" "$SILENT_SINK"
}

# True when cliamp currently plays into the silent sink (room is quiet
# while streaming). False when silent sink missing / cliamp elsewhere.
room_silent() {
  have pactl || return 1
  local idx
  idx="$(pactl list short sinks 2>/dev/null | awk -v s="$SILENT_SINK" '$2 == s {print $1; exit}')"
  [ -n "$idx" ] || return 1
  pactl list sink-inputs 2>/dev/null | awk -v want="$idx" '
    BEGIN { RS=""; FS="\n" }
    {
      sink=""; app=0
      for (i=1; i<=NF; i++) {
        if ($i ~ /^\tSink: /) { sink=$i; sub(/^\tSink: /, "", sink) }
        if ($i ~ /application\.name = / && tolower($i) ~ /cliamp/) { app=1 }
      }
      if (app && sink == want) { found=1 }
    }
    END { exit !found }'
}

cmd_silent_toggle() {
  # Flip the room between silent (cliamp in null sink) and speakers
  # (cliamp on default sink). Stream keeps full audio either way.
  # Prints {"silent":true/false,"monitor":"..."}.
  have pactl || { echo "missing: pactl" >&2; return 3; }
  if room_silent; then
    local def; def="$(pactl get-default-sink 2>/dev/null || true)"
    [ -z "$def" ] && { echo "no default sink" >&2; return 4; }
    have cliamp || { echo "missing: cliamp" >&2; return 3; }
    cliamp device "$def" >/dev/null 2>&1 || { echo "cliamp would not switch to $def" >&2; return 4; }
    printf '{"silent":false,"monitor":"%s.monitor","sink":"%s"}\n' "$def" "$def"
  else
    local mon; mon="$(silent_sink_ensure)" || return $?
    have cliamp || { echo "missing: cliamp" >&2; return 3; }
    cliamp device "$SILENT_SINK" >/dev/null 2>&1 || { echo "cliamp would not switch to $SILENT_SINK" >&2; return 4; }
    printf '{"silent":true,"monitor":"%s","sink":"%s"}\n' "$mon" "$SILENT_SINK"
  fi
}

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

read_pid() { [ -f "$1" ] && cat "$1" 2>/dev/null | tr -d ' \n' || echo ""; }

port_open() {
  # $1 = port; true if something listens on 0.0.0.0:<port>
  (command -v ss >/dev/null && ss -tln 2>/dev/null | grep -qE "[:.]$1( |$)") || \
  (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null
}

tcp_reachable() {
  # $1 = host, $2 = port; true if TCP connects within ~3s
  local host="$1" port="$2"
  timeout 3 bash -c "</dev/tcp/$host/$port" 2>/dev/null
}

cmd_check() {
  local s="false" c="false" f="false"
  have snapserver && s="true"
  have snapclient && c="true"
  have ffmpeg && f="true"
  printf '{"snapserver":%s,"snapclient":%s,"ffmpeg":%s}\n' "$s" "$c" "$f"
}

cmd_status() {
  local spid fpid cpid hpid
  spid="$(read_pid "$SERVER_PID")"; fpid="$(read_pid "$FEEDER_PID")"
  cpid="$(read_pid "$CLIENT_PID")"; hpid="$(read_pid "$HTTP_PID")"
  local sharing="false" listening="false" http="false"
  alive "$spid" && sharing="true"
  # feeder dying while server lives = degraded but still "sharing"
  local feeder="false"; alive "$fpid" && feeder="true"
  alive "$cpid" && listening="true"
  alive "$hpid" && http="true"
  # Dock-owned sharing only. A foreign server (e.g. system snapserver.service
  # on the same ports) is reported separately as ports_busy so the UI does
  # not misread it as dock sharing.
  # shellcheck disable=SC2086
  set -- $(share_ports); local sp="$1" cp="$2"
  local ports_busy="false"
  if [ "$sharing" = "false" ] && have snapserver; then
    if port_open "$sp" && port_open "$cp"; then ports_busy="true"; fi
  fi
  # client_ok: pid alive AND handshake completed (ServerSettings seen).
  local client_ok="false"
  if [ "$listening" = "true" ] && [ -f "$CLIENT_LOG" ]; then
    grep -q "ServerSettings" "$CLIENT_LOG" 2>/dev/null && client_ok="true"
  fi
  local ip; ip="$(lan_ip)"
  local chost="" cport="$DEF_STREAM" cweb="$DEF_WEB"
  if [ -f "$CLIENT_TARGET" ]; then
    # shellcheck disable=SC2086
    set -- $(cat "$CLIENT_TARGET" 2>/dev/null); chost="${1:-}"; cport="$(valid_port "${2:-}" "$DEF_STREAM")"; cweb="$(valid_port "${3:-}" "$DEF_WEB")"
  elif [ -f "$CACHE/snapclient.host" ]; then
    # legacy file (host only) from earlier dock versions
    chost="$(cat "$CACHE/snapclient.host" 2>/dev/null)"
  fi
  local hport="$DEF_HTTP"; [ -f "$CACHE/cliamp-http.port" ] && hport="$(cat "$CACHE/cliamp-http.port" 2>/dev/null)"
  local mon; mon="$(active_monitor)"
  # Per-dock listen volume (this machine's client volume on the sharer).
  # -1 when not listening / unreachable; queried with a short timeout so
  # a dead sharer never stalls status.
  local lvol="-1"
  if [ "$listening" = "true" ] && [ -n "$chost" ]; then
    lvol="$(listen_volume_get "$chost" "$cweb" 2>/dev/null)" || lvol="-1"
    [ -z "$lvol" ] && lvol="-1"
  fi
  # shellcheck disable=SC2086
  set -- $(share_ports)
  local room="false"; room_silent 2>/dev/null && room="true"
  printf '{"sharing":%s,"feeder":%s,"listening":%s,"http":%s,"ip":"%s","client_host":"%s","client_port":%s,"http_port":"%s","monitor":"%s","stream_port":%s,"control_port":%s,"web_port":%s,"ports_busy":%s,"client_ok":%s,"listen_volume":%s,"room_silent":%s}\n' \
    "$sharing" "$feeder" "$listening" "$http" "$ip" "$chost" "$cport" "$hport" "$mon" "$1" "$2" "$3" "$ports_busy" "$client_ok" "$lvol" "$room"
}

# --- Per-dock listen volume (Snapcast per-client volume) ---
# Each listener's loudness lives on the sharer as that client's own
# volume, independent of the server's player volume and of every other
# listener. These helpers speak the sharer's JSON-RPC (port 1780 by
# default) with curl+jq.

# POST a JSON-RPC body to the sharer; prints the response.
snap_rpc() {
  # $1 = host, $2 = web port, $3 = request body
  curl -s -m 5 -X POST "http://$1:$2/jsonrpc" \
    -H 'Content-Type: application/json' -d "$3"
}

# Print our client id on the sharer (matches the --hostID we connect
# with, falling back to hostname matches for foreign clients).
find_client_id() {
  # $1 = host, $2 = web port
  local st hid hname cid
  st="$(snap_rpc "$1" "$2" '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}')" || return 5
  hid="$(hostname)-dock"; hname="$(hostname)"
  cid="$(printf '%s' "$st" | jq -r --arg hid "$hid" --arg hname "$hname" '
    [.result.server.groups[]?.clients[]?
     | select(.id == $hid
              or ((.config.name // "") | contains($hname))
              or ((.host.name // "") | contains($hname)))]
    | .[0].id // empty' 2>/dev/null)"
  [ -z "$cid" ] && return 6
  printf '%s' "$cid"
}

# Print this dock's listen volume percent on the sharer (for status).
listen_volume_get() {
  # $1 = host, $2 = web port
  local st cid
  st="$(snap_rpc "$1" "$2" '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}')" || return 5
  cid="$(printf '%s' "$st" | jq -r --arg hid "$(hostname)-dock" --arg hname "$(hostname)" '
    [.result.server.groups[]?.clients[]?
     | select(.id == $hid
              or ((.config.name // "") | contains($hname))
              or ((.host.name // "") | contains($hname)))]
    | .[0] // empty' 2>/dev/null)"
  [ -z "$cid" ] && return 6
  printf '%s' "$cid" | jq -r '.config.volume.percent // 100'
}

cmd_listen_volume() {
  # $1 = host, $2 = web port, $3 = percent (empty = get only)
  local host="${1:-}" web pct
  web="$(valid_port "${2:-}" "$DEF_WEB")"
  pct="${3:-}"
  [ -z "$host" ] && { echo "usage: $0 listen-volume <host> <web-port> [percent]" >&2; return 2; }
  have curl || { echo "missing: curl" >&2; return 3; }
  have jq || { echo "missing: jq" >&2; return 3; }
  local cid req vol
  cid="$(find_client_id "$host" "$web")" || { echo "client not on $host (start Listen first)" >&2; return 6; }
  if [ -n "$pct" ]; then
    case "$pct" in ''|*[!0-9]*) pct="100" ;; esac
    [ "$pct" -gt 100 ] && pct="100"
    req="$(jq -n --arg id "$cid" --argjson pct "$pct" \
      '{id:1, jsonrpc:"2.0", method:"Client.SetVolume", params:{id:$id, volume:{percent:$pct, muted:false}}}')"
    snap_rpc "$host" "$web" "$req" >/dev/null || return 5
  fi
  vol="$(listen_volume_get "$host" "$web")" || return 6
  printf '{"volume":%s}\n' "$vol"
}

cmd_share_start() {
  # args: [stream_port [control_port [web_port [monitor]]]]
  # Empty monitor = default sink monitor. A missing silent-sink monitor
  # is auto-created; any other missing monitor is an error.
  local stream control web
  stream="$(valid_port "${1:-}" "$DEF_STREAM")"
  control="$(valid_port "${2:-}" "$DEF_CONTROL")"
  web="$(valid_port "${3:-}" "$DEF_WEB")"
  have snapserver || { echo "missing: snapserver (yay -S snapcast)" | tee /dev/stderr; return 3; }
  have ffmpeg || { echo "missing: ffmpeg" | tee /dev/stderr; return 3; }
  local spid; spid="$(read_pid "$SERVER_PID")"
  if alive "$spid"; then echo "already sharing (snapserver pid $spid)"; return 0; fi
  # Single-mode: listening and sharing fight over audio focus; stop listener.
  local cpid0; cpid0="$(read_pid "$CLIENT_PID")"
  if alive "$cpid0"; then echo "stopping listen to share (single mode)"; cmd_listen_stop >/dev/null 2>&1 || true; fi
  # Fail fast if something else (e.g. system snapserver.service) owns the ports.
  if port_open "$stream" || port_open "$control" || port_open "$web"; then
    echo "ERROR: ports busy (:$stream/:$control/:$web). Stop the other server first:" >&2
    echo "  sudo systemctl disable --now snapserver" >&2
    echo "  $0 share-stop" >&2
    return 6
  fi
  local mon; mon="${4:-}"
  if [ -z "$mon" ]; then mon="$(default_monitor)"; fi
  if ! monitor_exists "$mon"; then
    if [ "$mon" = "${SILENT_SINK}.monitor" ]; then
      mon="$(silent_sink_ensure)" || return $?
    else
      echo "monitor not found: $mon (run Silent setup, or clear Share monitor)" >&2
      return 4
    fi
  fi
  printf '%s' "$mon" > "$SHARE_MON_FILE"

  # Let snapserver create the FIFO itself (mode=create is the default);
  # pre-remove any stale pipe/file so creation succeeds. FIFO lives in
  # ~/.cache (not /tmp) to dodge fs.protected_fifos on sticky dirs.
  rm -f "$FIFO"

  # Section names follow current snapcast (0.33+): [tcp-control] = 1705,
  # [tcp-streaming] = 1704, [http] = 1780.
  cat > "$CONF" <<EOF
# Generated by cliamp-dock lan-share.sh — safe to delete.
[tcp-control]
bind_to_address = 0.0.0.0
port = $control
[tcp-streaming]
bind_to_address = 0.0.0.0
port = $stream
[stream]
source = pipe://$FIFO?name=Cliamp&sampleformat=48000:16:2&codec=flac
[http]
enabled = true
bind_to_address = 0.0.0.0
port = $web
EOF
  printf '%s %s %s\n' "$stream" "$control" "$web" > "$PORTS_FILE"

  # shellcheck disable=SC2094
  nohup snapserver -c "$CONF" >"$SERVER_LOG" 2>&1 &
  echo $! > "$SERVER_PID"
  sleep 1
  # snapserver should have created the fifo by now; wait briefly
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -p "$FIFO" ] && break
    sleep 0.5
  done
  if [ ! -p "$FIFO" ]; then
    echo "snapserver did not create $FIFO — check $SERVER_LOG" >&2
    # keep server running; user can inspect log
  fi
  # Feeder: monitor -> raw s16le 48k stereo into the fifo.
  # -vn not needed (audio only); -nostdin so shell stays usable.
  nohup ffmpeg -hide_banner -loglevel warning -nostdin \
    -f pulse -i "$mon" \
    -ac 2 -ar 48000 -f s16le -acodec pcm_s16le "pipe:1" \
    >"$FIFO" 2>"$FEEDER_LOG" &
  echo $! > "$FEEDER_PID"
  echo "sharing: snapserver pid $(cat "$SERVER_PID"), feeder pid $(cat "$FEEDER_PID"), monitor $mon"
  echo "sharing: stream :$stream control :$control web :$web"
  echo "clients: snapclient tcp://$(lan_ip):$stream"
}

cmd_share_stop() {
  local rc=0
  for pf in "$SERVER_PID" "$FEEDER_PID"; do
    local pid; pid="$(read_pid "$pf")"
    if alive "$pid"; then kill "$pid" 2>/dev/null || rc=$?; fi
    rm -f "$pf"
  done
  # belt & suspenders: catch orphans by name. Bracket-trick ([f]) so pkill
  # never matches its own command line when run from a shell whose
  # history/cmdline contains the pattern.
  pkill -f "[f]fmpeg.*snapfifo" 2>/dev/null || true
  rm -f "$SHARE_MON_FILE"
  echo "share stopped"
  return $rc
}

cmd_listen_start() {
  # Single-mode client: snapclient ALWAYS talks to the STREAM port (default
  # 1704), never the control port (default 1705). Control is JSON-RPC;
  # dialing it fails with hello timeout / unknown message type.
  local host="${1:-}"
  [ -z "$host" ] && { echo "usage: $0 listen-start <host-ip> [stream-port [web-port]]" >&2; return 2; }
  local req_port="${2:-}"
  local cport; cport="$(valid_port "$req_port" "$DEF_STREAM")"
  # Auto-heal legacy callers/configs that saved 1705 (control) for listening.
  # shellcheck disable=SC2086
  set -- $(share_ports); local cfg_stream="$1" cfg_control="$2"
  if [ -n "$req_port" ] && [ "$cport" = "$cfg_control" ] && [ "$cport" != "$cfg_stream" ]; then
    echo "note: remapping legacy control port $cport -> stream port $cfg_stream" >&2
    cport="$cfg_stream"
  fi
  # Web port (sharer's JSON-RPC, for listen-volume); stored for status.
  local cweb; cweb="$(valid_port "${3:-}" "$DEF_WEB")"
  have snapclient || { echo "missing: snapclient (yay -S snapcast)" | tee /dev/stderr; return 3; }
  # Preflight BEFORE touching the current session: fail fast with a clear
  # error instead of killing a good listener then reconnect-looping.
  if ! tcp_reachable "$host" "$cport"; then
    echo "ERROR: cannot reach $host:$cport. Is the sharer sharing? Open TCP $cport on the sharer." >&2
    return 5
  fi
  # Single-mode: stop dock-owned sharing before listening (avoids loop/feedback).
  local spid; spid="$(read_pid "$SERVER_PID")"
  if alive "$spid"; then echo "stopping share to listen (single mode)"; cmd_share_stop >/dev/null 2>&1 || true; fi
  # Reuse if already on the same target and healthy.
  local cpid; cpid="$(read_pid "$CLIENT_PID")"
  if alive "$cpid"; then
    local cur=""; [ -f "$CLIENT_TARGET" ] && cur="$(cat "$CLIENT_TARGET" 2>/dev/null)"
    if [ "$cur" = "$host $cport $cweb" ] && grep -q "ServerSettings" "$CLIENT_LOG" 2>/dev/null; then
      echo "already listening to $host:$cport (pid $cpid)"; return 0
    fi
    echo "restarting stale listener (was: $cur)"
    cmd_listen_stop >/dev/null 2>&1 || true
    pkill -x snapclient 2>/dev/null || true
    sleep 1
  else
    rm -f "$CLIENT_PID"
    pkill -x snapclient 2>/dev/null || true
  fi
  printf '%s %s %s\n' "$host" "$cport" "$cweb" > "$CLIENT_TARGET"
  printf '%s' "$host" > "$CACHE/snapclient.host"
  : > "$CLIENT_LOG"
  # Modern URI form (snapclient 0.33+); -h/-p are deprecated.
  # shellcheck disable=SC2094
  nohup snapclient "tcp://$host:$cport" --hostID "$(hostname)-dock" >"$CLIENT_LOG" 2>&1 &
  echo $! > "$CLIENT_PID"
  # Wait for handshake (ServerSettings) so callers know it really connected.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 0.5
    grep -q "ServerSettings" "$CLIENT_LOG" 2>/dev/null && break
    grep -qE "ERROR|Failed to send hello|unknown message type|Connection refused" "$CLIENT_LOG" 2>/dev/null && break
  done
  if grep -q "ServerSettings" "$CLIENT_LOG" 2>/dev/null; then
    echo "listening to $host:$cport (pid $(cat "$CLIENT_PID"))"
    return 0
  fi
  echo "ERROR: listen to $host:$cport failed — see $CLIENT_LOG:" >&2
  tail -n 8 "$CLIENT_LOG" >&2 || true
  kill "$(read_pid "$CLIENT_PID")" 2>/dev/null || true
  rm -f "$CLIENT_PID"
  pkill -x snapclient 2>/dev/null || true
  return 6
}

cmd_listen_stop() {
  local cpid; cpid="$(read_pid "$CLIENT_PID")"
  alive "$cpid" && kill "$cpid" 2>/dev/null || true
  rm -f "$CLIENT_PID"
  pkill -x snapclient 2>/dev/null || true
  echo "listen stopped"
}

cmd_http_start() {
  local port; port="$(valid_port "${1:-}" "$DEF_HTTP")"
  have ffmpeg || { echo "missing: ffmpeg" | tee /dev/stderr; return 3; }
  local hpid; hpid="$(read_pid "$HTTP_PID")"
  if alive "$hpid"; then echo "http already on :$port (pid $hpid)"; return 0; fi
  local mon; mon="$(active_monitor)"
  [ -z "$mon" ] && { echo "no monitor source found" >&2; return 4; }
  printf '%s' "$port" > "$CACHE/cliamp-http.port"
  # ffmpeg built-in listen-mode HTTP server (single-threaded, LAN fine).
  nohup ffmpeg -hide_banner -loglevel warning -nostdin \
    -f pulse -i "$mon" \
    -codec:a libmp3lame -b:a 192k -content_type audio/mpeg \
    -listen 1 "http://0.0.0.0:${port}/cliamp.mp3" \
    >"$HTTP_LOG" 2>&1 &
  echo $! > "$HTTP_PID"
  echo "http: http://$(lan_ip):${port}/cliamp.mp3 (pid $(cat "$HTTP_PID"))"
}

cmd_http_stop() {
  local hpid; hpid="$(read_pid "$HTTP_PID")"
  alive "$hpid" && kill "$hpid" 2>/dev/null || true
  rm -f "$HTTP_PID"
  pkill -f "[c]liamp\.mp3" 2>/dev/null || true
  echo "http stopped"
}

case "${1:-}" in
  check) cmd_check ;;
  status) shift; [ "${1:-}" = "--json" ] && cmd_status || cmd_status ;;
  share-start) cmd_share_start "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
  share-stop) cmd_share_stop ;;
  silent-sink) cmd_silent_sink ;;
  silent-toggle) cmd_silent_toggle ;;
  listen-start) cmd_listen_start "${2:-}" "${3:-}" "${4:-}" ;;
  listen-stop) cmd_listen_stop ;;
  listen-volume) cmd_listen_volume "${2:-}" "${3:-}" "${4:-}" ;;
  http-start) cmd_http_start "${2:-8099}" ;;
  http-stop) cmd_http_stop ;;
  ip) lan_ip; echo ;;
  *) echo "usage: $0 {check|status --json|share-start [stream [control [web [monitor]]]]|share-stop|silent-sink|silent-toggle|listen-start <host> [stream-port [web-port]]|listen-stop|listen-volume <host> <web-port> [percent]|http-start [port]|http-stop|ip}" >&2; exit 2 ;;
esac
