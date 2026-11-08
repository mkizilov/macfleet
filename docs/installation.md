# Installing MacFleet

This guide covers building MacFleet, installing the menu bar app, and installing the headless agent on each Mac. It needs
no signing credential for local use. Distribution signing and notarization are in [distribution.md](distribution.md).

Requirements: macOS 14 or later on Apple silicon (`arm64`), and the Command Line Tools for the Swift 6 toolchain. The
project has no third-party dependencies.

## Build from source

```sh
sh scripts/check-release.sh        # scripts, property lists, and version settings
sh scripts/swiftc-verify.sh        # compiles every module and runs the test suites
sh scripts/package-app.sh          # writes dist/ with the app and the agent package
```

`package-app.sh` writes `dist/MacFleet-<version>.zip`, `dist/macfleet-headless-<version>.tar.gz`, a signing report, and
`SHA256SUMS`. Without a credential it signs ad hoc, which runs on the Mac that built it. Another Mac may refuse it.

## Install the menu bar app

Unzip `dist/MacFleet-<version>.zip` and drag `MacFleet.app` to `/Applications`. Open it once. Then turn on **Open MacFleet
at Login** in Settings > General if you want it to start at login.

An ad hoc build is blocked by Gatekeeper on another Mac. Open it from the Finder with the context menu, Open, or sign and
notarize it as [distribution.md](distribution.md) describes.

## Install the headless agent

The agent is for a Mac you want to monitor from another Mac. It runs as your user, not as root, and it listens only if you
give it an address.

Unpack the package, then run the installer. It plans first and writes nothing until you add `--apply`:

```sh
tar -xzf dist/macfleet-headless-<version>.tar.gz
cd macfleet-headless-<version>
sh scripts/install-agent.sh --binary bin/macfleet-headless --config /path/to/headless.json
sh scripts/install-agent.sh --binary bin/macfleet-headless --config /path/to/headless.json --apply
sh scripts/install-agent.sh --binary bin/macfleet-headless --config /path/to/headless.json --apply --load
```

- The first command prints the plan: the binary, the configuration, the launchd definition, and the log folder.
- `--apply` copies the binary to `~/Library/Application Support/MacFleet/bin`, writes the configuration there with mode
  600, and writes the launchd definition to `~/Library/LaunchAgents`.
- `--load` starts the agent under launchd. Without it the agent is installed but not running.

The installer runs the binary's own `version` and `check` commands first. It refuses to install a binary that does not run,
and a configuration that does not validate. If an installed configuration already exists, the installer keeps it and
validates that too.

Create the configuration and its secrets as described in [headless-agent.md](headless-agent.md#provisioning). The
configuration names where the secrets live. It never holds a secret.

### Remove the agent

```sh
sh scripts/uninstall-agent.sh                       # plans; removes nothing
sh scripts/uninstall-agent.sh --apply --unload      # stops the agent and removes the binary and launchd definition
```

Removal keeps the configuration (with the pinned identity and client secrets) and the logs. `--purge-config` removes the
configuration, but only when the installer created it. `--purge-logs` removes the logs, but only from a `MacFleet` folder.
Secrets in the Keychain are not touched by either. Remove them with `macfleet-headless credential remove` first.

## Local installation and Tailscale installation

**Local (one Mac, testing).** Set `listenAddress` to `127.0.0.1` and pair the app with the same Mac. The address is
loopback, so nothing outside the Mac can reach it. Use this to check the setup before going further.

**Tailscale (between Macs).** Connect both Macs to the same tailnet. On the monitored Mac, run
`macfleet-headless addresses` and set `listenAddress` to its Tailscale address (the `100.64.0.0/10` or `fd7a:115c:a1e0::/48`
address). Wildcard addresses such as `0.0.0.0` are refused, and the address must be assigned to this Mac.

On the monitoring Mac, add the Mac in **Windows > Fleet** with its Tailscale name or its Tailscale address and the port.
Then:

1. Choose **Check Identity**. The app connects and shows the fingerprint the monitored Mac presents.
2. Compare that fingerprint with the output of `macfleet-headless identity show --config headless.json` on the monitored
   Mac. Read it over a channel you trust. This comparison is the only protection against a substitute at first pairing.
3. Choose **Trust and Save**. Nothing is saved before this.

A certificate change later shows as an identity change, and the app will not trust the new certificate until you review it.

Tailscale provides reachability and encryption between tailnet nodes. MacFleet does not depend on it for security: trust
comes from the pinned certificate and the per-client secret.

## Certificate pairing, in short

- The monitored Mac holds an RSA-2048 identity, a self-signed certificate, and its fingerprint.
- The monitoring Mac pins that fingerprint when you trust it.
- Each client has a 256-bit secret. The secret is never sent. Both sides prove they hold it, bound to the TLS session.

The provisioning commands and the threat model are in [remote-protocol.md](remote-protocol.md).

## Verify the installation

```sh
~/Library/Application\ Support/MacFleet/bin/macfleet-headless version
~/Library/Application\ Support/MacFleet/bin/macfleet-headless status --config ~/Library/Application\ Support/MacFleet/config/headless.json
```

`status` exits 0 when the agent is healthy, 1 when it is not, and 2 when it has not reported yet.

## Not verified here

- Installing into a real user account with `launchctl`. The installer's tests run against a scratch folder and never load
  an agent.
- Signing with a Developer ID, notarization, and Gatekeeper on another Mac. See [distribution.md](distribution.md).
- A real tailnet. The Tailscale address ranges are tested; the Mac's address on a live tailnet is not.
