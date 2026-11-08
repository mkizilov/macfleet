# MacFleet headless agent

`macfleet-headless` is a separate command-line executable. It samples this Mac in the background, serves its metrics to authenticated clients over TLS, reports its health in a status file, and writes a structured log. It has no window and no menu bar. The protocol it speaks is in [remote-protocol.md](remote-protocol.md).

## Defaults

- **No listener by default.** With no `listenAddress`, the agent samples and reports health, and it accepts no connection.
- **An explicit address.** A listener needs one numeric address, and it must be assigned to this Mac. Wildcards (`0.0.0.0`, `::`) are refused. Use the Tailscale address, which `macfleet-headless addresses` lists.
- **Private networks only.** Clients must come from loopback or the Tailscale ranges (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`), unless `allowedNetworks` says otherwise.
- **Authenticated only.** Each client needs its own secret. Nothing about the metrics is sent before the proof verifies.

## Build

The verification script builds the binary to `.agent-local/swiftc-build/macfleet-headless`:

```sh
scripts/swiftc-verify.sh
```

The expected SwiftPM build is `swift build -c release --product macfleet-headless`. It was not run here, because SwiftPM's build service fails in this sandbox (see the README).

## Configuration

The configuration file holds no secrets. A minimal example:

```json
{
  "displayName": "studio",
  "listenAddress": "100.100.20.30",
  "port": 21440,
  "identityPath": "/Users/you/Library/Application Support/MacFleet/headless/identity.p12",
  "clientIDs": ["laptop-1"],
  "secretStore": {"kind": "keychain"},
  "samplingIntervalSeconds": 10,
  "statusPath": "/Users/you/Library/Application Support/MacFleet/headless/status.json",
  "logPath": "/Users/you/Library/Logs/MacFleet/headless.log"
}
```

| Field | Meaning | Default |
| --- | --- | --- |
| `displayName` | Shown to clients. 1 to 64 characters. | required |
| `listenAddress` | The one address to listen on. Omit to listen nowhere. | none |
| `port` | TCP port. | 21440 |
| `identityPath` | PKCS#12 identity. Must be owner-only. Required with `listenAddress`. | none |
| `clientIDs` | The clients allowed to connect. Required with `listenAddress`. | `[]` |
| `secretStore` | `{"kind": "keychain"}` or `{"kind": "file", "path": ...}`. | required |
| `samplingIntervalSeconds` | How often the machine is sampled, 0.5 to 3600. Out-of-range values are refused, not clamped. | 10 |
| `allowedNetworks` | CIDR blocks the listener and clients may use. | loopback and Tailscale |
| `statusPath` | The health report. | `~/Library/Application Support/MacFleet/headless/status.json` |
| `logPath` | The structured log. | `~/Library/Logs/MacFleet/headless.log` |

A problem in the file is reported with the field it concerns, and the agent does not start.

## Secrets

Secrets are the identity passphrase and one secret per client. They are kept in one of two places:

- **Keychain** (`{"kind": "keychain"}`). Recommended for the LaunchAgent. Items are generic passwords under the service `com.macfleet.headless`. The keychain may ask for access the first time an item is used.
- **Owner-only file** (`{"kind": "file", "path": ...}`). A JSON map of account to base64 value. The agent refuses to read it unless its owner is the current account and no other account has any access, the way ssh treats private keys.

The passphrase is read from standard input, so it does not appear in the command line or the shell history:

```sh
printf '%s' "$PASSPHRASE" | macfleet-headless identity passphrase --config headless.json
```

## Provisioning

1. **Create the identity.** Use the commands in [remote-protocol.md](remote-protocol.md#host-identity). Store the `.p12` bundle at `identityPath` and run `chmod 600` on it. Delete the key PEM file.
2. **Store the passphrase** with the command above.
3. **Show the fingerprint** that clients must pin:
   ```sh
   macfleet-headless identity show --config headless.json
   ```
4. **Create a client secret.** Add the client ID to `clientIDs`, then:
   ```sh
   macfleet-headless credential add --config headless.json --client laptop-1 > laptop-1.secret
   ```
   The command stores the secret and prints it once, to standard output, which is why the example redirects it into a file. Give the file to the client over a channel you trust, and keep it owner-only (`chmod 600`). Rotate with `credential add --replace`. Revoke with `credential remove`, and then take the ID out of `clientIDs`.
5. **Choose the address.** Run `macfleet-headless addresses`, and set `listenAddress` to the Tailscale address.

## Running and checking

```sh
macfleet-headless run --config headless.json         # runs until SIGTERM or SIGINT
macfleet-headless status --config headless.json      # prints the report; exit 0 healthy, 1 unhealthy, 2 none yet
macfleet-headless fetch --host 100.100.20.30 --port 21440 --client laptop-1 \
  --pin SHA256:... --secret-file laptop-1.secret --count 5
```

`fetch` is a reference client. It prints one JSON snapshot per line.

## Health

The agent rewrites its status file on every change and every sample. The report has the state (`starting`, `running`, `stopping`, `stopped`, or `failed`), the listener (`disabled`, `listening`, or `failed`), the session counts, the sample count and failures, the last sample time, the process ID, and the version. A report older than 30 seconds, or older than three sampling intervals, counts as unhealthy, so a dead agent is noticed.

`status` applies the same rules, so it works as a health check for a supervisor or a script.

## Logs

The log is JSON lines, one record per line, with `time` (ISO 8601 with milliseconds), `level`, `event`, and `fields`. Events include `agent.starting`, `listener.listening`, `session.opened`, `session.authenticated`, `auth.failed` (with a reason, never a secret), `session.closed` (with the reason), `connection.rejected`, `sample.failed`, `agent.stopping`, and `agent.stopped`. The file is owner-only. At 5 MB it moves to `headless.log.1` and a new file starts.

## Shutdown

On SIGTERM or SIGINT the agent tells each connected client that it is shutting down (`shuttingDown`, retryable), waits half a second so the notice is sent, closes the sessions, stops sampling, writes `stopped` to the status file, and exits 0. A failure exits 1 with the reason in the log.

## Automatic start with launchd

`Support/launchd/com.macfleet.headless.plist` is a user LaunchAgent template. It restarts the agent after a failure but not after a clean stop. The repository does not install it. Follow this checklist on the Mac that will run the agent:

1. Copy the binary to a fixed location, such as `~/Library/MacFleet/bin/macfleet-headless`.
2. Copy the plist to a temporary file. Replace each placeholder with an absolute path: `__MACFLEET_HEADLESS_BINARY__`, `__MACFLEET_HEADLESS_CONFIG__`, and `__MACFLEET_LOG_DIRECTORY__`. Use `sed` to write the result.
3. Lint the result: `plutil -lint <temporary file>`.
4. Copy it to `~/Library/LaunchAgents/com.macfleet.headless.plist`, with owner-only permissions.
5. Load it: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.macfleet.headless.plist`.
6. Check it: `launchctl print gui/$(id -u)/com.macfleet.headless`, and `macfleet-headless status --config ...`.
7. To remove it: `launchctl bootout gui/$(id -u)/com.macfleet.headless`, then delete the plist.

If Tailscale is not connected when the user logs in, the listener address is not assigned. The agent records the failure, exits 1, and launchd retries every 30 seconds until the address appears.

## Verification

- **Automated, run here.** `scripts/headless-smoke.sh` runs as part of `scripts/swiftc-verify.sh`. It builds an identity and secrets in a temporary directory, starts the real binary, takes two snapshots through the real client over TLS on loopback, refuses a wrong secret, stops the agent with SIGTERM, and checks the exit code, the status file, the log, and that the secret appears in no output.
- **In-process integration tests.** `HeadlessAgentIntegrationTests` run a real agent and real TLS clients on loopback ports 21421 to 21432. They cover snapshots, the status report, a disabled listener, a wrong secret and its log record, a disconnecting client, graceful shutdown with the notice, a failed sample, a listener that cannot bind, a missing secret, a second run, and an untrusted pin.
- **Unit tests.** Configuration validation, secret store permissions, the log format and rotation, health rules, and local address classification.

## Not verified

- A real tailnet, and a client on another Mac.
- The launchd installation. The plist lints, but it was not loaded.
- The keychain store. Automated tests do not change the keychain, so `KeychainSecretStore` compiles but was not exercised.
- Login behaviour: whether the agent starts at login, and whether the listener is ready before Tailscale connects.
- Long-running stability and log rotation under real load.
- A signal sent while sessions are in the handshake.
