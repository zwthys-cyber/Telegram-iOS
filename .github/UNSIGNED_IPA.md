# Personal unsigned IPA

Branch `ci/unsigned-ipa` builds a release arm64 device IPA with the Xcode version pinned by `versions.json` on GitHub's macOS 26 runner. Actions artifacts contain the IPA, SHA256SUMS and a verification report. No Apple certificate is needed to build. Install only after signing using your own signing service or certificate.

The workflow requires your own Telegram API credentials. Obtain them at https://my.telegram.org/apps and set both repository Actions secrets `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` before rebuilding. It stops early if credentials are missing and rejects the official/example API IDs; it never silently falls back to the upstream CI credentials. These credentials are embedded in the application, as required by the client protocol.

## Included changes

- All bundled alternate home screen icons can be selected in Settings > Appearance without an icon subscription gate. Selection changes only after iOS reports success.
- Interface controls already available under Settings > Swiftgram include hiding stories, contacts/calls tabs, and the bottom bar. They remain individually configurable.
- Message JSON and timestamps with seconds are enabled by default for new installations. The message context menu also provides Copy ID and Copy timestamp (ISO 8601 in UTC) for messages permitting copying. JSON provides message IDs, timestamps and media metadata; the existing document viewer provides export for messages permitting sharing. Profile IDs are already enabled upstream.
- The existing translation service picker and language settings remain available; the quick translation button is enabled by default for new installations.
- The existing Save to Files context menu action remains enabled. Existing copy/save actions and message JSON provide media shortcuts and information, subject to the source's existing protection rules.

Existing saved preferences take precedence over new defaults. No server-side Premium account status is changed.

## Verification scope

The workflow checks ZIP integrity, the main executable, iPhoneOS platform, minimum OS <= 26.6, arm64 architecture and iOS device platform for every Mach-O, absence of binary signatures, and records SHA256. This is build/package validation, not a physical iPhone 17 Pro Max runtime test. Notifications, app groups and extension behavior also depend on the entitlements provided by the eventual signing method.

## Self-signing and App Groups

Non-App-Store builds can initialize main-app storage in their private Application Support directory when the signer has not provided the required App Group. Builds with a valid App Group continue to use it. Background URL sessions only request shared-container access when that group is available. Extensions and shared notifications still need correctly provisioned App Groups. Signing again with different group access may select a different data container; neither container is deleted or migrated automatically.

## SMS Fee during login

The SMS Fee screen corresponds to Telegram's server-side `auth.sentCodePaymentRequired` response. Removing its UI does not authorize the account. The payment screen uses App Store products, which may be unavailable in a self-signed build. Correct personal API credentials are required, but do not guarantee SMS delivery or exemption from server-side fees. See https://core.telegram.org/api/auth and https://core.telegram.org/api/obtaining_api_id. If an account still has an active session, Telegram may offer a code delivered to that session; available methods are selected by the server.
