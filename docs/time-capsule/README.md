# Time Capsule for Telegram

**Messages That Unlock Over Time**

Time Capsule is a native messaging feature for Telegram that allows users to send messages which remain sealed until a selected moment.

Instead of immediately revealing the message, Telegram displays a sealed message bubble with a live countdown. Once the countdown reaches zero, the recipient can tap **Unseal** to reveal the hidden content.

The feature is implemented directly in the Telegram iOS source code, using existing chat components and messaging infrastructure.

This repository contains the native iOS implementation, accompanied by an independent backend that provides timed release, authorization, and encrypted message storage.

## Overview

Time Capsule introduces a new way to communicate through time.

A user can write a message, select Time Capsule from the sending options, and choose how long it should remain sealed.

The recipient receives a message that displays a countdown instead of its contents.

When the specified time arrives, the capsule becomes available to open. The recipient must explicitly tap **Unseal** to reveal the message.

Time Capsule can be used for surprises, announcements, quiz answers, special occasions, and other messages intended to be discovered later.

## Features

### Native Telegram Integration

Time Capsule is integrated into Telegram's existing iOS application.

It uses the native sending interface, message bubbles, chat presentation components, and Telegram's existing message transport.

It is not a separate application, web interface, or static UI prototype.

### Customizable Countdown

Users can select a duration using days, hours, minutes, and seconds.

The supported range is from one second to 365 days.

A live countdown is displayed directly inside the message bubble. Days are shown only when applicable, while hours, minutes, and seconds remain visible.

### Sealed Messages

Before the selected deadline, the message contents remain unavailable to the recipient.

The sealed state is represented by a native message bubble containing a lock, countdown, and appropriate message status information.

### Unseal Interaction

Once the countdown reaches zero, the message transitions into a ready-to-open state.

The recipient can tap **Unseal** to request and reveal the hidden message.

The reveal interaction is implemented using native iOS UI components.

### Server-Enforced Release

The backend enforces the release deadline independently of the device's displayed countdown.

Changing the local device clock does not authorize an early release.

### Persistent Message State

The implementation includes local storage and recovery mechanisms for Time Capsule operations, including authorized opened content and supported interrupted sending flows.

## Source Code

Time Capsule consists of two complementary implementations.

### iOS Client

**[Telegram iOS — Time Capsule](https://github.com/developer6758/Telegram-iOS/tree/feature/time-capsule)**

Contains the native Telegram iOS integration, including:

- Message composer integration
- Duration selection
- Sealed message bubbles
- Live countdown rendering
- Unseal interaction
- Cryptographic verification
- Client authorization
- Local message state management

### Reference Backend

**[Time Capsule Backend](https://github.com/developer6758/telegram-time-capsule)**

Contains the independent server implementation, including:

- Time Capsule reservation and sealing
- Encrypted content storage
- Release deadline enforcement
- Authorization and session management
- Signed message descriptors
- Message release and revocation operations
- Persistent storage and automated tests

The reference backend is written in Go and uses PostgreSQL.

**Go and PostgreSQL are not requirements for adopting Time Capsule into Telegram's production infrastructure.** They are used to provide an independently runnable implementation of the necessary server-side behavior.

Telegram developers can adapt the protocol and release logic to Telegram's existing backend architecture.

## Architecture

Time Capsule uses a client-server design.

### 1. Message Creation

The sender composes a message and chooses a release duration.

The iOS client prepares the message, communicates with the release service, and creates a signed Time Capsule descriptor.

### 2. Sealed Transport

Telegram carries the signed `TCAP1` descriptor through its existing messaging infrastructure.

The descriptor identifies the capsule and contains the metadata required by compatible clients.

The protected content is stored separately by the release service.

### 3. Countdown

The recipient's iOS client recognizes the descriptor and displays the native Time Capsule bubble.

The countdown is calculated using the release information and a service-based time estimate.

### 4. Release Authorization

When the deadline has passed, the recipient can request the sealed content.

The backend verifies the request and enforces the release rules before returning the information required to open the capsule.

### 5. Message Reveal

The client verifies and decrypts the authorized payload, then displays the original message content using Telegram's native interface.

## Security Model

Time Capsule uses cryptographic mechanisms to protect sealed message contents and verify release information.

The implementation includes:

- AES-GCM encryption
- P-256 digital signatures
- Signed capsule descriptors
- HTTPS communication
- Telegram Login OIDC authorization
- Server-enforced release deadlines
- Controlled access to released content
- Account-specific local state

### Important Trust Boundary

The independent release service holds cryptographic material required to release message contents.

**Time Capsule is not end-to-end encrypted against the release service itself.**

The release service is a trusted component of this implementation.

An official Telegram integration could implement equivalent release controls within Telegram's own trusted infrastructure.

Unmodified Telegram clients do not natively recognize Time Capsule messages and may display the encoded descriptor instead.

The current implementation does not require changes to Telegram's official servers to operate with compatible modified iOS clients.

## iOS Implementation

The native implementation introduces several modules and extends selected existing Telegram components.

| Component | Responsibility |
|---|---|
| `TimeCapsuleCore` | Cryptographic operations, protocol validation, API communication, persistent client state |
| `TimeCapsuleAuthorizationUI` | Telegram Login authorization flow |
| `TimeCapsuleSummary` | Safe message preview representation |
| `ChatTimeCapsuleComposer` | Message creation and sealing workflow |
| `ChatTimeCapsuleDuration` | Native duration selection |
| `ChatMessageTimeCapsuleBubbleContentNode` | Countdown, sealed bubble, and message reveal |
| `TelegramEngine.Messages` | Integration with Telegram's message queue |
| `ChatListUI` | Time Capsule presentation in chat previews |

Additional changes integrate Time Capsule with chat interactions, notifications, accessibility, account state, and message deletion behavior.

The implementation follows Telegram's existing modular source structure.

## Building the iOS Client

### Requirements

- macOS and Xcode compatible with the checked-out Telegram iOS revision
- Required Bazel and build dependencies
- Telegram API application credentials
- A configured Time Capsule release service
- A trusted HTTPS connection to the release service

Refer to the repository's `versions.json` and main `README.md` for the exact build requirements.

### 1. Clone the Repository

```bash
git clone --recursive --branch feature/time-capsule https://github.com/developer6758/Telegram-iOS.git
cd Telegram-iOS
```

### 2. Configure Time Capsule

The example configuration is located at:

`docs/time-capsule/TimeCapsuleConfiguration.example.json`

Create the local configuration file:

`Telegram/Telegram-iOS/Resources/TimeCapsuleConfiguration.json`

Configure the service identifier, HTTPS backend URL, and public verification keys.

The corresponding public signing key can be exported from the backend's generated configuration.

Private backend signing keys, wrapping keys, and authorization client secrets must never be included in the iOS application.

### 3. Configure Telegram Development Settings

Use the existing Telegram iOS build system and development configuration template.

Create:

`build-system/time_capsule_development_configuration.json`

Provide the required Telegram application credentials, development bundle identifier, and signing settings.

This local configuration is excluded from Git.

### 4. Generate the Xcode Project

```bash
git submodule update --init --recursive

python3 build-system/Make/Make.py \
  --cacheDir="$HOME/telegram-bazel-cache" \
  generateProject \
  --configurationPath=build-system/time_capsule_development_configuration.json \
  --xcodeManagedCodesigning
```

Open the generated project in Xcode, select a supported iPhone Simulator, and build the Telegram application.

A separate development application identity is recommended to avoid replacing an existing Telegram installation.

The Time Capsule backend must be configured and reachable for the complete feature flow.

## Backend Setup

The independent backend is available at:

https://github.com/developer6758/telegram-time-capsule

It is implemented using Go, PostgreSQL, and HTTPS.

Follow that repository's README for instructions on:

1. Installing dependencies.
2. Generating persistent service keys.
3. Configuring PostgreSQL.
4. Registering Telegram Login credentials.
5. Configuring trusted HTTPS.
6. Running database migrations.
7. Starting the release service.
8. Running automated tests.

Backend configuration and credentials are intentionally separate from the iOS source code.

The backend is provided to demonstrate and reproduce the complete Time Capsule protocol and server-side behavior.

It is not a dependency that Telegram must preserve unchanged when integrating the feature into its infrastructure.

## Verification and Testing

The Time Capsule iOS application has been built and launched using Xcode and an iPhone Simulator.

The native creation, countdown, and Unseal interaction have been exercised locally.

The backend includes automated tests for:

- Protocol validation
- Cryptographic verification
- Authentication and session behavior
- PostgreSQL operations
- Release deadline enforcement
- Revocation and authorization rules
- Restart and failure scenarios

Independent end-to-end validation between separately configured Telegram accounts, full native test-suite execution, and production deployment testing remain outstanding.

The detailed initial verification record and additional test scenarios are documented in [VERIFICATION.md](VERIFICATION.md).

Backend testing details are available in the server repository.

## Compatibility and Limitations

The current implementation focuses on Telegram for iOS.

The following limitations apply:

- Android, Desktop, and Web implementations are not included.
- The feature currently targets eligible private Telegram cloud conversations.
- Media capsules, group chats, and secret chats are outside the current implementation.
- Both participating clients require compatible Time Capsule support for the intended native experience.
- The independent backend must be configured and available.
- Unmodified Telegram clients cannot natively open Time Capsule descriptors.
- Released cryptographic material cannot be recalled once delivered.
- Comprehensive multi-device, failure-recovery, and production security validation remains necessary.

The existing implementation provides a working foundation for further development and potential native integration into Telegram's official messaging infrastructure.

## Further Documentation

**iOS**

- [Verification and Remaining Work](VERIFICATION.md)
- [Example Configuration](TimeCapsuleConfiguration.example.json)

**Backend**

- [Backend Repository](https://github.com/developer6758/telegram-time-capsule)
- [Authentication](https://github.com/developer6758/telegram-time-capsule/blob/main/docs/AUTH.md)
- [Protocol](https://github.com/developer6758/telegram-time-capsule/blob/main/docs/PROTOCOL.md)
- [Security and Trust Model](https://github.com/developer6758/telegram-time-capsule/blob/main/docs/THREAT_MODEL.md)
- [Build and Testing](https://github.com/developer6758/telegram-time-capsule/blob/main/docs/BUILD_AND_TEST.md)

---

---

**Time Capsule — Messages That Unlock Over Time.**

Created by @vivapot
