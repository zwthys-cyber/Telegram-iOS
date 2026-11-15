# BYPlugin contributor instructions

All builds and tests run in GitHub Actions, never the current assistant server. Read README.md and migration.json first.

Keep ABI 1 function signatures stable. The plugin only exports its own C symbols; do not resolve Telegram/Swift internal symbols, swizzle unrelated objects, or mutate server subscription/authentication state. Missing, disabled, and incompatible plugins must preserve upstream behavior. Keep saved user preferences and existing data containers intact.

When upstream moves, port adapter call sites onto its complete tree, including new download-engine behavior. The owner authorizes opt-in local copying/saving for protected, disappearing and view-once content through BYPlugin settings. Preserve paid-content restrictions, server forwarding, consumption/expiry semantics, and upstream behavior when off. Export only accessible resources; release temporary hard links after the viewer/export closes. Keep hash checks, flood waits, and sequential probing for unknown-size V1 resources. Run the plugin loader cases, storage and alignment tests, then the full release app build in CI. Report simulator/device verification separately from successful compilation.
