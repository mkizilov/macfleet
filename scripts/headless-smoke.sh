#!/bin/sh
# Process-level check of the headless agent. It starts the built macfleet-headless binary as its own process, connects a
# real client over TLS on loopback, refuses a wrong secret, then stops the agent with SIGTERM and checks the clean stop.
# Everything it writes lives under .agent-local/headless-smoke and is removed when the script exits.
set -eu
cd "$(dirname "$0")/.."

HEADLESS="$PWD/.agent-local/swiftc-build/macfleet-headless"
WORK="$PWD/.agent-local/headless-smoke"
PORT=21498
AGENT_PID=""

cleanup() {
  if [ -n "$AGENT_PID" ] && kill -0 "$AGENT_PID" 2>/dev/null; then
    kill -TERM "$AGENT_PID" 2>/dev/null || true
    wait "$AGENT_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"
CONFIG="$WORK/headless.json"

PASSPHRASE=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 30 \
  -subj "/CN=macfleet-smoke" -addext "extendedKeyUsage=serverAuth" -addext "keyUsage=digitalSignature" \
  -addext "basicConstraints=CA:FALSE" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" \
  -passout "pass:$PASSPHRASE" -name host >/dev/null 2>&1
rm -f "$WORK/key.pem"
chmod 600 "$WORK/identity.p12"

cat > "$CONFIG" <<EOF
{
  "displayName": "smoke-agent",
  "listenAddress": "127.0.0.1",
  "port": $PORT,
  "identityPath": "$WORK/identity.p12",
  "clientIDs": ["smoke-client"],
  "secretStore": {"kind": "file", "path": "$WORK/secrets.json"},
  "samplingIntervalSeconds": 1,
  "statusPath": "$WORK/status.json",
  "logPath": "$WORK/headless.log"
}
EOF

printf '%s' "$PASSPHRASE" | "$HEADLESS" identity passphrase --config "$CONFIG"
"$HEADLESS" credential add --config "$CONFIG" --client smoke-client > "$WORK/client-secret.b64" 2>/dev/null
SECRET=$(cat "$WORK/client-secret.b64")
chmod 600 "$WORK/client-secret.b64"
PIN=$("$HEADLESS" identity show --config "$CONFIG")
echo "fingerprint $PIN"

"$HEADLESS" run --config "$CONFIG" > "$WORK/agent.out" 2> "$WORK/agent.err" &
AGENT_PID=$!

ready=0
for _ in $(seq 1 60); do
  if "$HEADLESS" status --config "$CONFIG" > /dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done
if [ "$ready" -ne 1 ]; then
  echo "the agent never reported healthy" >&2
  cat "$WORK/agent.err" >&2 || true
  exit 1
fi
echo "agent healthy"

"$HEADLESS" fetch --host 127.0.0.1 --port "$PORT" --client smoke-client --pin "$PIN" \
  --secret-file "$WORK/client-secret.b64" --count 2 > "$WORK/snapshots.jsonl" 2> "$WORK/client.err"
snapshots=$(grep -c '"capturedAt"' "$WORK/snapshots.jsonl" || true)
if [ "$snapshots" -ne 2 ]; then
  echo "expected 2 snapshots, got $snapshots" >&2
  cat "$WORK/client.err" >&2
  exit 1
fi
echo "client received 2 snapshots over TLS"

WRONG="$WORK/wrong-secret.b64"
/usr/bin/openssl rand -base64 32 > "$WRONG"
chmod 600 "$WRONG"
if "$HEADLESS" fetch --host 127.0.0.1 --port "$PORT" --client smoke-client --pin "$PIN" \
  --secret-file "$WRONG" --count 1 > "$WORK/wrong.jsonl" 2> "$WORK/wrong.err"; then
  echo "a wrong secret received metrics" >&2
  exit 1
fi
if [ -s "$WORK/wrong.jsonl" ]; then
  echo "a wrong secret received output" >&2
  exit 1
fi
echo "wrong secret refused"

kill -TERM "$AGENT_PID"
stop_status=0
wait "$AGENT_PID" || stop_status=$?
AGENT_PID=""
if [ "$stop_status" -ne 0 ]; then
  echo "the agent exited with status $stop_status on SIGTERM" >&2
  cat "$WORK/agent.err" >&2
  exit 1
fi
grep -q '"state" : "stopped"' "$WORK/status.json" || { echo "the status file does not show a stop" >&2; exit 1; }
for event in agent.stopping agent.stopped; do
  grep -q "\"event\":\"$event\"" "$WORK/headless.log" || { echo "the log lacks $event" >&2; exit 1; }
done
if grep -q "$SECRET" "$WORK/headless.log" "$WORK/agent.err" "$WORK/agent.out" "$WORK/status.json"; then
  echo "a secret appeared in the agent's output" >&2
  exit 1
fi
echo "agent stopped cleanly on SIGTERM and kept the secret out of its output"
echo "headless process smoke passed"
