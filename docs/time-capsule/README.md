# Time Capsule for Telegram iOS

Native iOS source implementation with a separate trusted release service. This feature is **partially implemented / not yet verified in Xcode or between real Telegram accounts**. The working tree contains the changes; nothing was pushed or deployed. Android, Desktop and Web are outside this implementation.

The existing send menu offers Time Capsule in eligible direct human cloud chats. A native duration sheet accepts days/hours/minutes/seconds, from one second through 365 days. The encrypted payload is sealed at the service; only its signed `TCAP1` descriptor enters Telegram's normal message queue. The native bubble content node uses the existing shell and date/status component. Expiry changes its closed lock/countdown into an open lock and **Tap to open**. Release, verification, decryption and the original Unseal transition follow an explicit tap. Each device keeps its own encrypted released/opened state.

The service holds an escrowed content key and can decrypt the message. This is **not end-to-end encryption against that service**. Telegram receives safe descriptor metadata; existing Telegram cloud drafts may already contain the sender's text. Signed coarse layout samples and ciphertext padding buckets disclose approximate message size. Unmodified clients display an encoded carrier and cannot open it. Already released keys/content cannot be recalled.

## Configure independent testing

1. Use the companion checkout `developer6758/telegram-time-capsule` and its README to create persistent signing/wrapping keys, run migrations and start the service. Register your own Telegram Login OIDC client and the service's HTTPS callback. No credentials are included in either repository.
2. Provide a trusted HTTPS origin reachable from both Simulator instances or devices. The iOS client has no TLS bypass or HTTP development mode. System browser login is the only web flow.
3. Copy `docs/time-capsule/TimeCapsuleConfiguration.example.json` to `Telegram/Telegram-iOS/Resources/TimeCapsuleConfiguration.json`. Set the same service identifier as the backend, its HTTPS origin and signing key ID. Export the backend's P-256 public key as DER SubjectPublicKeyInfo and encode it with **standard base64** for `verification_keys`. Descriptor byte fields use unpadded **base64url**. This ignored resource is included by the existing `Telegram:AppResources` glob; regenerate the project after adding it. Keep old verification keys during rotation.
4. Copy `build-system/template_minimal_development_configuration.json` to the ignored `build-system/time_capsule_development_configuration.json`. Supply your own Telegram API ID/hash, bundle ID, URL scheme and signing identity. Never put backend OIDC secrets, signing keys or wrapping keys into the app.
5. On a compatible Mac, initialize the checkout's submodules and follow the official workflow below. Use a dedicated Simulator/app identity and controlled accounts. Each account must separately complete service login; the returned verified Telegram user ID must match the native account.

The action explains a missing configuration rather than silently using a public or test endpoint. Backend test identities cannot be activated from the shipping iOS app.

## Official Xcode workflow (requires macOS; not executed here)

The pinned source revision requires Xcode 27.1, macOS 27 and Bazel 9.2.0 (`versions.json`). From the iOS checkout:

```sh
git submodule update --init --recursive
python3 build-system/Make/Make.py \
  --cacheDir="$HOME/telegram-bazel-cache" \
  generateProject \
  --configurationPath=build-system/time_capsule_development_configuration.json \
  --xcodeManagedCodesigning
```

The official README also documents `--disableProvisioningProfiles` with a local `--codesigningInformationPath` for Simulator-only work. Inspect the generated workspace/project and use `xcodebuild -list` to discover its actual schemes. Open the generated project in Xcode, select the Telegram app scheme and a supported iPhone Simulator, then build and run. Do not replace your normal signed-in app. A full Make.py app build uses `build --configuration=debug_sim_arm64` plus the same local configuration and provisioning setup; see root `CLAUDE.md` for the current wrapper requirements.

Native tests are the new `//submodules/TimeCapsuleCore:TimeCapsuleCoreTests` target and existing affected targets. Run them with `Make.py test --target <label>` using your local configuration/signing arguments and an installed compatible test runner. The repository's default `Tests/AllTests` has a pre-existing dangling target, so run the named target. No native test or full app build has been performed on this Linux host.

## Implementation boundaries

| Module/path | Responsibility |
| --- | --- |
| `submodules/TimeCapsuleCore` | Bounded signed descriptor/payload codec, CryptoKit, HTTPS API, service time estimate, account store, sessions and outbox |
| `submodules/TimeCapsuleAuthorizationUI` | Foreground system authentication session and one-use completion proof |
| `submodules/TimeCapsuleSummary` | Credential-free safe preview resolver usable by extensions |
| `ChatSendMessageActionUI` and `TelegramUI/Sources/Chat/ChatTimeCapsule*` | Conditional send action, native duration selector and explicit sealing flow |
| `TelegramEngine.Messages.enqueueTimeCapsuleCarrier` | Safe carrier-only durable native enqueue with atomic stable-random-ID deduplication |
| `ChatMessageTimeCapsuleBubbleContentNode` | Native content geometry/status, shared visible ticking, manual opening and Unseal |
| `ChatMessageItemView`, `ChatInterfaceStateContextMenus` | Safe accessibility container and local opened-text Copy; capsule editing/forwarding/translation/quotes disabled |
| `ChatCapsuleDeletion`, `ChatControllerAdminBanUsers` | Backend-first hide/revoke before confirmed native deletion; capsules do not offer an irreversible service tombstone as undoable |
| `ChatListItemStrings`, `MessageContentKind`, notification generation | Safe summaries without release-key access |
| `AccountContextImpl` | Foreground sealed-outbox recovery, background cancellation and logout cleanup |

The transport remains an ordinary Telegram text message. No invented Telegram API constructors, server features or bot-authored chat messages are used. First-party adoption in stock clients would require Telegram protocol/server/authentication/synchronization support.

See [verification and remaining work](VERIFICATION.md) before treating this as a competition-ready build.
