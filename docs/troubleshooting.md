# Troubleshooting

Each entry gives the message as the software shows it, what it means, and what to do. Messages are quoted exactly, so you
can search for them.

## Menu bar and popover

**"Waiting for the first sample."** The app has started and has not finished its first reading. It usually clears within a
few seconds. If it stays, Activity Monitor should show MacFleet using CPU; if it does not, quit and reopen the app.

**A menu bar value shows "–".** That metric could not be read. The popover says why under the metric. A dash is never a
zero.

**"History is kept for this session only: …"** The history file could not be opened, so history is kept in memory and is
lost when the app quits. Live values still work. The message includes the reason. Check that the Mac's disk is not full
and that the folder `~/Library/Application Support/MacFleet` is writable.

**"Saved settings could not be read, so the defaults are in use. The damaged data was kept under …"** The settings file was
damaged. The defaults are in use, and the damaged data was moved aside, not deleted. The key shown is in user defaults.

**"Settings could not be saved. They apply until the app quits."** The change works now but will not survive a restart.
Check the Mac's disk and try again.

## Processes

**Some processes show a reason instead of a number.** macOS did not allow the app to read that process, usually because it
belongs to another account or is protected. This is expected for a standard user. The name and process ID are still shown.

## Fleet (remote Macs)

**"The Mac did not answer at this address. Check that Tailscale is connected on both Macs and that its monitoring agent is
running."** The connection failed before a session started. Check that Tailscale is connected on both Macs, that the
agent is running (`macfleet-headless status`), and that the port matches. The app retries with growing gaps, up to five
minutes, and resets when a session connects.

**"The Mac rejected the client secret. Remove this Mac and pair it again with the secret from `macfleet-headless
credential add`."** Retrying does not help, and the app stops. The secret on the client does not match the one on the
monitored Mac. Run `macfleet-headless credential add --client <id> --replace` on that Mac, copy the new secret, remove
the Mac in the app, and pair it again.

**"The Mac did not prove that it holds the client secret, so it was not trusted."** The monitored Mac did not prove its
identity. Check that the address is the right Mac and not another host that happens to be listening there.

**An identity change, shown as a changed certificate.** The monitored Mac's certificate is not the one you pinned. This
happens after a certificate rotation, or if something else is answering at that address. Compare the fingerprint the
monitored Mac now shows (`macfleet-headless identity show`) with the fingerprint in the app, over a trusted channel. Only
when they match, choose **Review New Certificate** and trust it.

**A certificate that has expired.** The app reports the certificate as rejected and stops retrying. Issue a new identity
on the monitored Mac (see [headless-agent.md](headless-agent.md#provisioning)), re-pin, and save.

**"The Mac reported an error: …" or "The Mac sent a message this app cannot accept: …"** The two Macs may run different
protocol versions. The app shows the versions it can speak. Update the older Mac. Protocol rules are in
[remote-protocol.md](remote-protocol.md#negotiation-and-compatibility).

**"Public IP addresses are refused."** Use the Mac's Tailscale name or a private address. MacFleet refuses public
addresses by design.

**The agent refuses to start with an address error.** `listenAddress` must be numeric, assigned to this Mac, and inside
`allowedNetworks`. Wildcard addresses are refused. Run `macfleet-headless addresses` and copy one of those addresses.

## Installing the agent

**"`<binary>` does not run its version command"** or **"the configuration does not validate"** The installer checks both
before it writes anything. Run the binary by hand with the same arguments to read the full error.

**"the configuration already installed does not validate"** An earlier configuration is in place and no longer fits this
version. Fix it at the path the message names, or remove the agent and install again with a configuration you trust.

**"paths may not contain |, & or a backslash"** The installer writes paths into the launchd definition, and these
characters would corrupt it. Move the files to a path without them.

**"the files are installed, but launchd did not load …"** The installer wrote the files but launchd refused them. Read the
logs folder and check `launchctl print gui/$(id -u)/com.macfleet.headless`. Run `uninstall-agent.sh --apply --unload` to
remove what was installed.

**The agent exits with status 1 after login.** Tailscale was not connected when the user logged in, so the listen address
does not exist yet. launchd retries every 30 seconds. Connect Tailscale and wait.

## Logs and status

The agent writes JSON lines to `~/Library/Logs/MacFleet/headless.log`. Each record has `time`, `level`, `event`, and
`fields`. Useful events: `auth.failed` (with a reason, never a secret), `session.closed` (with the reason),
`connection.rejected` (an address outside the network policy), and `sample.failed`.

`macfleet-headless status --config <file>` exits 0 when healthy, 1 when unhealthy, and 2 when no report exists yet.

## Uninstalling

If `uninstall-agent.sh` says **"no install manifest"**, nothing was installed by the installer, or the manifest was moved.
Remove the files by hand, as [headless-agent.md](headless-agent.md#automatic-start-with-launchd) describes.

**"keeping …: the installer did not create it"** A purge found a configuration that was already in place. The installer
keeps it. Delete it yourself if you are sure.

**"refusing to remove … the logs directory must be a MacFleet directory"** The install manifest names a log folder that is
not a MacFleet folder. Nothing was removed. Check the manifest by hand.

## Reporting a problem

Include the exact message, the app or agent version (`macfleet-headless version`, or the About box), and the macOS version.
Do not include secrets, client secret files, or the passphrase. The logs contain no secrets.
