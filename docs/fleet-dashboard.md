# Multi-Mac fleet dashboard

The **Fleet** window shows this Mac and every remote Mac you have registered, side by side. Each remote Mac runs `macfleet-headless` (see [headless-agent.md](headless-agent.md)). The app connects to each one over TLS and keeps its connection, snapshot, and retry clock separately from the others.

## Adding a Mac

1. On the Mac to add, create a client secret for this app and copy the printed value:
   ```sh
   macfleet-headless credential add --config headless.json --client laptop-1 > laptop-1.secret
   ```
2. In the app, open **Windows > Fleet** and fill in the form:
   - **Name.** Any label, up to 64 characters.
   - **Address.** The Mac's Tailscale name (such as `studio.tailnet.ts.net`) or a private IP address. Public IP addresses are refused. A name is not resolved, so a name that resolves to a public address is not refused.
   - **Port.** The agent's port, 21440 by default.
   - **Client ID.** The ID the secret was created for.
   - **Client secret.** The value from step 1.
3. Choose **Check Identity**. The app connects and shows the certificate fingerprint the Mac presents.
4. On that Mac, run `macfleet-headless identity show --config headless.json` and compare the two fingerprints character for character.
5. Choose **Trust and Save** only if they match. Nothing is saved before this step.

Trust is on first use. A fingerprint you have not checked is not trusted, and a Mac whose fingerprint you did not compare is not protected against a substitute at the first pairing. The comparison in step 4 is the protection.

## What is stored, and where

| Item | Where | Notes |
| --- | --- | --- |
| Label, address, port, client ID, pinned fingerprint, date added | User defaults, key `MacFleet.remoteHosts` | Holds no secret. Damaged data is moved aside, not deleted. |
| Client secret | Login keychain, service `com.macfleet.app.remote`, account `remote.<id>` | Removed with the Mac. |
| Draft form, including the secret you type | Memory only | Cleared when the pairing is confirmed or cancelled. |

## Connection states

Each Mac shows one of these states, with the reason in words:

| State | Indicator | What happens next |
| --- | --- | --- |
| Connecting | Yellow | The first attempt, or a reconnect that has just started. |
| Online | Green | Snapshots arrive about every five seconds. |
| Offline | Orange | A transient failure. The next try is scheduled, with the time shown. |
| Stopped | Red | A failure that retries cannot fix. Nothing is retried until you act. |

Transient failures are retried with backoff: the first retry waits 2 seconds, each later one waits twice as long, and the wait never exceeds 300 seconds. A failure counter restarts when a session connects, so a host that comes back is retried promptly the next time it drops.

Transient failures: the address did not answer, the connection timed out, the connection closed, the host is restarting, or the host reported a transient error.

Stopped until you act:

| Failure | Why it is not retried | What you do |
| --- | --- | --- |
| Client secret rejected | Retrying a wrong secret only adds failed attempts. | Remove the Mac and pair it again with the current secret. |
| Certificate changed | The new identity is untrusted until you check it. | **Review New Certificate**, compare the fingerprint, then trust it. |
| Certificate rejected (expired or otherwise invalid) | Retrying does not renew it. | Replace or renew the certificate on that Mac, then **Reconnect**. A new certificate has a new fingerprint, so it must be reviewed as above. |
| No common protocol version, protocol error, invalid address, missing secret | Retrying cannot fix them. | Follow the message on the card. |

## Certificate changes

When a Mac's certificate changes, the card says so and shows the new fingerprint. The saved pin does not change. **Review New Certificate** probes the Mac again, shows the new fingerprint for comparison, and replaces the pin only when you confirm. The saved secret is kept. If you confirm a certificate identical to the one already trusted, nothing changes.

## Removing a Mac

**Remove** on a card forgets the Mac's record and its secret, stops its connection, and deletes its stored history and alert settings. Pair it again to monitor it. See [multi-host-history.md](multi-host-history.md) for how history is kept per Mac.

## Limits

- At most 16 remote Macs are monitored, because each holds a connection and a retry clock.
- The local card and each remote card are built from the same projection, so the metrics mean the same thing on both.
- A Mac that is offline keeps its last snapshot, labelled as not current, rather than showing zero or hiding the card.
- The app does not sample remote Macs itself. Each Mac reports its own readings through its agent.
- The client secret is in memory while the form is open. It is never shown on a card and never written into a record.
- The Mac's name is the one it reports. The label is yours.

## Verification

Automated tests run under `scripts/swiftc-verify.sh`:

- **Probes over TLS.** A probe learns the Mac's name and certificate without sending a proof. The agent records no authentication attempt. A certificate replaced at the same address is visible on the next probe. An unreachable address is reported as such.
- **Certificates.** A client that pinned another certificate reports an identity change with the certificate shown. An expired certificate is rejected by name, not as unreachable.
- **Failed authentication.** A wrong secret stops after one attempt, with no retry scheduled.
- **Reconnection.** Transient failures retry at 2, 4, and 8 seconds, and a host that comes back is connected on the next try. A dropped session reconnects after the base delay.
- **Unavailable hosts.** A host that is down is retried with growing delays and is connected once it answers.
- **Simultaneous connections.** Two Macs connect at once, report their own names, and one going offline leaves the other online.
- **Removal and launch.** Removing a Mac forgets its secret and stops its connection. Every saved Mac reconnects when the app starts. A Mac with no saved secret is stopped without an attempt.
- **Storage.** Unreadable saved data blocks saving, so nothing is overwritten. A failed save leaves no secret behind.
- **Presentation.** Every state has its wording and actions, and an offline Mac's data is labelled as not current.

Loopback ports used: 21441 to 21453. The integration suites are serialized.

## Not verified

- The Fleet window was typechecked as part of the app target, not run. Layout, the form, and the confirmation sheet were not seen on screen.
- The keychain store for the app's secrets compiles, but the automated tests do not write to the keychain.
- A real tailnet, two physical Macs, and sleep and wake on either side.
- Long-running connections and the reconnect behaviour over hours.
- The project has no App Sandbox setting and no entitlements file, so outgoing connections need no entitlement. If sandboxing is enabled later, add `com.apple.security.network.client`.
