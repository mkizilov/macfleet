# MacFleet remote metrics protocol

Version 1.0. The implementation is in `Sources/MacFleetKit/Remote`, and the tests are in `Tests/MacFleetKitTests/Remote*.swift`.

The protocol lets an authenticated client read a host's metric snapshots over TLS. It is transport-independent of SwiftUI and of the menu bar app. It runs over any IP path that reaches the host, and it is designed for private networks such as Tailscale.

## Security model

- **No unauthenticated metrics.** A host sends nothing about its metrics, including capabilities, until the client's proof verifies. The first message from a client must be `hello`. A connection that sends anything else gets an error and is closed.
- **Pinned host identity.** A client trusts a host only when the host's certificate has the fingerprint the client was given. No certificate authority and no system trust store are involved, and there is no trust on first use.
- **Per-client secrets.** Each client holds a 256-bit secret. Both sides prove possession with HMAC-SHA256 over a transcript that covers the session. The secret is never sent.
- **Channel binding.** The transcript includes the TLS exporter for the connection, so a proof is valid only in the TLS session it was made in.
- **Mutual authentication.** The host sends its own proof. The client verifies it before it accepts a snapshot, so a host that does not hold the secret is rejected.
- **Bounded resources.** Frames are capped at 1 MiB and are refused from their header. At most 8 sessions run at once. Handshake steps, the idle timeout, and each TLS start have deadlines.

## Host identity

A host has one identity: an RSA-2048 key and a self-signed X.509 certificate.

- The certificate has `basicConstraints=CA:FALSE`, `keyUsage=digitalSignature`, and `extendedKeyUsage=serverAuth`.
- The operator supplies the identity as a PKCS#12 bundle. The host imports it with `kSecImportToMemoryOnly`, so the keychain is never written. That option needs macOS 15. On macOS 14 the host refuses to start rather than touch the keychain.
- The **fingerprint** is the SHA-256 of the certificate's DER encoding, written `SHA256:` followed by 64 lowercase hexadecimal digits.
- A client pins the fingerprint. The verify block accepts the TLS peer only when its leaf certificate matches the pin and passes a basic X.509 evaluation anchored on that certificate alone. That evaluation checks the signature and the validity dates. The SSL server policy is not used, because it rejects a self-signed leaf.
- Rotating the certificate changes the fingerprint, so every client must be re-pinned. Revoking a host means stopping it and re-pinning clients to a new identity.

Provisioning, with openssl (tested with LibreSSL 3.3.6, the system tool at `/usr/bin/openssl`):

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout host-key.pem -out host-cert.pem -days 365 \
  -subj "/CN=macfleet-host" -addext "extendedKeyUsage=serverAuth" \
  -addext "keyUsage=digitalSignature" -addext "basicConstraints=CA:FALSE"
openssl pkcs12 -export -inkey host-key.pem -in host-cert.pem -out host-identity.p12 \
  -passout pass:CHOOSE-A-PASSPHRASE -name host
openssl x509 -in host-cert.pem -outform DER | openssl dgst -sha256
```

Delete `host-key.pem` once the bundle is made, and keep the bundle readable only by the account that runs the host. The last command prints `SHA2-256(stdin)= ...`. The hex after the equals sign is the fingerprint's digest, so the fingerprint is `SHA256:` followed by that hex.

Only RSA identities were imported in testing. An EC identity produced by this openssl build did not import, so EC is not supported by this implementation yet.

## Client credentials

A credential is a client ID and a 32-byte secret.

- The client ID is 1 to 64 characters from ASCII letters, digits, `.`, `_`, and `-`. It is sent in clear text during the handshake, so it must not carry anything private.
- The secret is generated with `RemoteCredential.generate(clientID:)`, which uses the system's secure random source. Give it to the client once, through a channel you trust.
- The host holds the credentials it accepts. Rotating a secret means replacing the credential on both sides.

## Transport and network policy

- TLS 1.3 over TCP, through Network.framework.
- Frames are a 4-byte big-endian length followed by a UTF-8 JSON envelope. Empty frames are rejected, and a frame over 1 MiB is refused from its header before its body is read.
- The default port is 21440. The port is not registered with IANA.
- The host checks each accepted connection's address against its network policy before reading a byte. The default policy allows loopback and the Tailscale ranges: `100.64.0.0/10` and `fd7a:115c:a1e0::/48`. A connection from anywhere else is closed with no TLS exchange.
- The listener binds all interfaces. The policy is the gate, and a host firewall is a sensible second layer.
- Tailscale provides reachability and encryption between tailnet nodes. This protocol does not depend on it for security. Trust still comes from the pin and the secret.

## Envelope

Every message is a JSON object with three members:

```json
{"version": "1.0", "type": "heartbeat", "body": {"sequence": 4, "sentAt": 1700000000.25}}
```

- `version` is the protocol version of the envelope, written `major.minor`.
- `type` names the message. An unknown type decodes as an unknown message, which is ignored after the handshake.
- `body` holds the message's fields. Unknown fields are ignored.
- Dates are numbers of seconds since 1970-01-01 UTC, with fractions kept.
- Byte fields, such as nonces and proofs, are base64.

## Messages

| Type | Direction | Body | Purpose |
| --- | --- | --- | --- |
| `hello` | client to host | `clientID`, `supportedVersions`, `clientNonce` | Start a session and offer versions. The envelope carries the highest offered version. |
| `helloAccepted` | host to client | `host` (display name and fingerprint), `serverNonce` | Negotiated version and host identity. The envelope carries the negotiated version. |
| `authenticate` | client to host | `proof` | The client's proof. |
| `authenticated` | host to client | `proof` | The host's proof. The client checks it before it accepts anything else. |
| `capabilities` | host to client | `capabilities` (metric and state) | Which metrics this host can report, with the reason for each one it cannot. |
| `subscribe` | client to host | `intervalSeconds` | Ask for snapshots at this interval. It is clamped to 0.5 to 3,600 seconds. |
| `snapshot` | host to client | the metric snapshot | Readings for capture time, CPU, memory, pressure, storage, network, thermal state, and load. |
| `heartbeat` | both | `sequence`, `sentAt` | Keeps an idle session alive. |
| `error` | both | `code`, `message`, `retryable`, optional `supportedVersions` | Why a peer refused or failed. |

### Session flow

1. TLS 1.3 completes. The client's verify block checks the pin.
2. Client sends `hello`. The host selects the highest version both sides support, and answers `helloAccepted`. If there is none, it answers `error` with code `unsupportedVersion` and lists the versions it speaks.
3. Client computes its proof and sends `authenticate`. The host verifies it. On failure the host answers `error` with code `authenticationFailed`, and the message is the same for an unknown client ID and for a wrong secret.
4. Host sends `authenticated` with its own proof, then `capabilities`, which are derived from one sample.
5. Client sends `subscribe`. Then both sides exchange `snapshot` and `heartbeat` messages until either side closes or times out.

Each handshake step must arrive within 10 seconds. Once streaming, a side that receives nothing for 15 seconds closes the session, and both sides send a heartbeat every 5 seconds.

### Errors

| Code | Meaning | Retryable |
| --- | --- | --- |
| `unsupportedVersion` | No common version. `supportedVersions` lists the host's versions. | no |
| `authenticationFailed` | The proof did not verify, or the client is unknown. | no |
| `malformedMessage` | The message could not be decoded or was out of place. | no |
| `unexpectedMessage` | A message arrived at a point where it is not allowed. | no |
| `frameTooLarge` | A frame exceeded the limit. | no |
| `snapshotUnavailable` | The host could not take a sample. The session continues. | yes |
| `timedOut` | The peer stopped responding. | no |
| `internalError` | The host could not finish a step. | no |
| `unrecognized` | A code from a newer peer. Clients treat it as a non-fatal report. | depends |

## Authentication

For each side, the proof is HMAC-SHA256 with the client's secret over a transcript. The transcript is the concatenation of these fields, each preceded by its 4-byte big-endian length:

1. The label `MacFleet remote authentication v1`.
2. The role, `client` or `host`. The labels differ, so the host's proof cannot be replayed as the client's.
3. The protocol version.
4. The client ID.
5. The client nonce.
6. The server nonce.
7. The host fingerprint.
8. The channel binding, which is the 32-byte TLS exporter with the label `EXPORTER-MacFleet-remote-v1`.

Each side verifies the other's proof with a constant-time comparison. Both nonces are 32 random bytes, and the channel binding ties the proofs to the TLS session.

## Negotiation and compatibility

- Versions are compared as `major.minor`. The session uses the highest version that both peers list. A peer's major version differs from the other's, and then the two cannot negotiate.
- A minor version can add messages, fields, and error codes. A peer that does not know a message type ignores it after the handshake. A peer that does not know a field ignores the field. A peer that does not know an error code treats it as `unrecognized`.
- A new major version is a new protocol. It cannot be negotiated with 1.x.
- After the handshake, each envelope must carry the negotiated version. Any other version is refused.
- A snapshot is a projection, `RemoteSnapshot`, with its own schema. It does not expose the host's internal model, so a change to that model does not change the wire format.

## Snapshot and capabilities

A snapshot carries these readings: `cpuTotal`, `memory`, `memoryPressure`, `storage`, `network`, `thermal`, and `loadAverage`. Each one is a `MetricReading`, so a value that cannot be read arrives with its reason and never as zero.

The capabilities list has one entry per metric, with a state:

- `supported`: the host read the measurement in this sample.
- `unavailable(reason)`: no public interface reports it on this host.
- `permissionRestricted(reason)`: the measurement exists, but macOS refuses it to this process.

## Threat model

| Threat | Protection | Remaining gap |
| --- | --- | --- |
| Passive observer reads metrics | TLS 1.3 encryption | Observers see that a connection exists, its addresses and timing, and its size. |
| Impostor host | Pinned fingerprint and a basic X.509 check in the verify block | A stolen identity bundle with its passphrase is an impostor. Protect the bundle. |
| Impostor client | HMAC proof with a 256-bit secret | No revocation list. Remove the credential and restart the host. |
| Replay of a proof | Nonces from both sides and the TLS channel binding | None known. |
| Relay to another host | The host's proof and the pin | None known. |
| Metrics from an unauthenticated peer | Nothing is sent before the client proof verifies | None known. |
| Peers outside the private networks | Network policy closes them before TLS | A peer inside an allowed network can still open connections. |
| Oversized or endless input | Frame cap, decoder limits, session cap, deadlines | No per-address rate limit. Connections are capped at 8 sessions in total, and connections that stall before authenticating count against that cap until their handshake deadline passes. |
| Brute force of a secret | The secret is 256 bits | Failed attempts are not rate-limited or logged. |
| Compromised client secret | Secrets are per client | The secret is kept in memory by the caller. No keychain storage is implemented. |

## Verification status

Verified on the development Mac with `scripts/swiftc-verify.sh`:

- Encoding and decoding of every message, with the envelope and date format checked on the wire.
- Compatibility: unknown types, unknown fields, unknown error codes, a newer snapshot schema, and malformed input.
- Framing across every chunk size, and the frame limits.
- Negotiation: the highest common version, an older host, and a missing common version.
- Authentication: proofs, role separation, a changed field of the transcript, credential validation, and fingerprints.
- The network policy, including the Tailscale ranges and IPv4-mapped addresses.
- The identity import, a wrong passphrase, and pin acceptance.
- Loopback TLS sessions: a complete session, a wrong secret, an unknown client, a wrong pin, a refused network, a version mismatch, a client that sends `subscribe` before authenticating, a client that waits without a proof, an idle client, heartbeats keeping a quiet session open, and session teardown when the client stops.

Not verified:

- A real tailnet. The Tailscale ranges are unit-tested, and loopback is tested end to end, but no tailnet peer was used.
- Certificate expiry. The basic X.509 check should reject an expired certificate, but no expired certificate was tested.
- EC identities and identities from other tools.
- macOS 14. Identity import needs macOS 15, so the identity tests are skipped there.
- The host as a running app or command. This turn adds the library only, with no entry point and no persisted configuration.
