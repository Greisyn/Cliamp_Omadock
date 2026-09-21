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
#   $HOME/.cache/cliamp-dock/snapclient.target "host control-port"
#   $HOME/.cache/cliamp-dock/*.pid           daemon pids
#   $HOME/.cache/cliamp-dock/*.log           daemon logs
#
# Usage:
#   lan-share.sh check                    -> JSON {snapserver,snapclient,ffmpeg}
#   lan-share.sh status --json            -> JSON {sharing,listening,...}
#   lan-share.sh share-start [stream [control [web]]]
#                                         -> start snapserver + ffmpeg feeder
#   lan-share.sh share-stop               -> stop both
#   lan-share.sh listen-start <host> [control-port]
#                                         -> start snapclient to <host>
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

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

read_pid() { [ -f "$1" ] && cat "$1" 2>/dev/null | tr -d ' \n' || echo ""; }

port_open() {
  # $1 = port; true if something listens on 0.0.0.0:<port>
  (command -v ss >/dev/null && ss -tln 2>/dev/null | grep -qE "[:.]$1( |$)") || \
  (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null
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
  # if pidfile stale but ports actually serving, still report sharing.
  # shellcheck disable=SC2086
  set -- $(share_ports); local sp="$1" cp="$2"
  if [ "$sharing" = "false" ] && have snapserver; then
    if port_open "$sp" && port_open "$cp"; then sharing="true"; fi
  fi
  local ip; ip="$(lan_ip)"
  local chost="" cport="$DEF_CONTROL"
  if [ -f "$CLIENT_TARGET" ]; then
    # shellcheck disable=SC2086
    set -- $(cat "$CLIENT_TARGET" 2>/dev/null); chost="${1:-}"; cport="$(valid_port "${2:-}" "$DEF_CONTROL")"
  elif [ -f "$CACHE/snapclient.host" ]; then
    # legacy file (host only) from earlier dock versions
    chost="$(cat "$CACHE/snapclient.host" 2>/dev/null)"
  fi
  local hport="$DEF_HTTP"; [ -f "$CACHE/cliamp-http.port" ] && hport="$(cat "$CACHE/cliamp-http.port" 2>/dev/null)"
  local mon; mon="$(default_monitor)"
  # shellcheck disable=SC2086
  set -- $(share_ports)
  printf '{"sharing":%s,"feeder":%s,"listening":%s,"http":%s,"ip":"%s","client_host":"%s","client_port":%s,"http_port":"%s","monitor":"%s","stream_port":%s,"control_port":%s,"web_port":%s}\n' \
    "$sharing" "$feeder" "$listening" "$http" "$ip" "$chost" "$cport" "$hport" "$mon" "$1" "$2" "$3"
}

cmd_share_start() {
  # args: [stream_port [control_port [web_port]]]
  local stream control web
  stream="$(valid_port "${1:-}" "$DEF_STREAM")"
  control="$(valid_port "${2:-}" "$DEF_CONTROL")"
  web="$(valid_port "${3:-}" "$DEF_WEB")"
  have snapserver || { echo "missing: snapserver (yay -S snapcast)" | tee /dev/stderr; return 3; }
  have ffmpeg || { echo "missing: ffmpeg" | tee /dev/stderr; return 3; }
  local spid; spid="$(read_pid "$SERVER_PID")"
  if alive "$spid"; then echo "already sharing (snapserver pid $spid)"; return 0; fi
  local mon; mon="$(default_monitor)"
  [ -z "$mon" ] && { echo "no Pulse/PipeWire monitor source found" >&2; return 4; }

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
  echo "clients: snapclient -h $(lan_ip) -p $control"
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
  echo "share stopped"
  return $rc
}

cmd_listen_start() {
  local host="${1:-}"
  [ -z "$host" ] && { echo "usage: $0 listen-start <host-ip> [control-port]" >&2; return 2; }
  local cport; cport="$(valid_port "${2:-}" "$DEF_CONTROL")"
  have snapclient || { echo "missing: snapclient (yay -S snapcast)" | tee /dev/stderr; return 3; }
  local cpid; cpid="$(read_pid "$CLIENT_PID")"
  if alive "$cpid"; then echo "already listening (pid $cpid)"; return 0; fi
  printf '%s %s\n' "$host" "$cport" > "$CLIENT_TARGET"
  printf '%s' "$host" > "$CACHE/snapclient.host"
  nohup snapclient -h "$host" -p "$cport" --hostID "$(hostname)-dock" >"$CLIENT_LOG" 2>&1 &
  echo $! > "$CLIENT_PID"
  echo "listening to $host:$cport (pid $(cat "$CLIENT_PID"))"
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
  local mon; mon="$(default_monitor)"
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
  share-start) cmd_share_start "${2:-}" "${3:-}" "${4:-}" ;;
  share-stop) cmd_share_stop ;;
  listen-start) cmd_listen_start "${2:-}" "${3:-}" ;;
  listen-stop) cmd_listen_stop ;;
  http-start) cmd_http_start "${2:-8099}" ;;
  http-stop) cmd_http_stop ;;
  ip) lan_ip; echo ;;
  *) echo "usage: $0 {check|status --json|share-start [stream [control [web]]]|share-stop|listen-start <host> [control-port]|listen-stop|http-start [port]|http-stop|ip}" >&2; exit 2 ;;
esac
