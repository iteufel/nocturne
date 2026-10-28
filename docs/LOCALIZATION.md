# Localization

The iPhone/iPad app, Mac app, and Files extension support English, German,
French, Italian, and Spanish. Apple resolves the user's normal device/app language
preferences, including regional variants and preference order. English is the
explicit development language and fallback. There is no language control in
Nocturne, persisted language preference, `AppleLanguages` mutation, or injected
SwiftUI locale. Number, byte-count and relative-date formatting use Foundation's
normal user preferences.

## Resources and boundaries

- `Sources/Shared/Resources/*/Localizable.strings` contains shared English keys
  and complete translations. `Localization.swift` looks them up in SwiftPM's
  resource bundle. `Localizable.stringsdict` supplies native plural rules.
- `Resources/Localization/{Client,Server,Files}/*/InfoPlist.strings` contains all
  repository permission descriptions in each product's main bundle. Bundle
  metadata explicitly declares the five supported languages and English fallback.
- `scripts/generate-project.rb` adds those resources to both generated app
  projects and the Files extension, removing the inherited empty InfoPlist table
  before adding the client's replacement. SwiftPM packages its own shared bundle.
- The iOS client's `Streaming.strings` localizes the reachable statistics, startup
  and connection-warning overlays of the pinned Moonlight dependency. The
  reviewed `scripts/streaming-localization.json` manifest is matched exactly
  during overlay generation; upstream source files stay untouched. The existing
  left-edge hint now describes Nocturne's existing controls gesture accurately.
- Known Nocturne error messages are translated at the receiving presentation
  boundary. The host's protocol error payloads remain canonical English. Anchored
  templates preserve substituted commands, identifiers, names and paths. Unknown
  external errors remain verbatim, rather than being sent to a translation service.

User text, agent replies/history, PR content, repository names/branches, model
values, terminal output, filenames, discovery names, machine/protocol keys,
capabilities, CLI commands and diagnostic logs are not translated. Stored values
such as `Match device`, tab IDs, appearance raw values and status comparisons stay
unchanged. Only their UI labels are localized. Provider-generated metadata and
external service prose remain provider-owned.

This is an isolated localization change based on `main` commit
`49ee687583adb5b82617cdc024f4bbdcf92cb861`, implemented in the separate clone
`/private/tmp/nocturne-localization`, branch `codex/localization-five-languages`.
No commits or features from the CallKit/push, chat-status/approvals, or
headless-lockscreen branches are included. Existing baseline chat/approval and
headless text is localized without importing those branches' new behavior.
Integrators should reuse the shared English keys and `L`/`LCount` APIs for new
presentation text, keep protocol/storage values stable, and add translations in
all five languages when those independent features land. Changes to nearby UI or
project generation may require ordinary textual conflict resolution.

## Verification

Run `python3 scripts/check-localization.py --runtime` on macOS. It checks:

- Identical key sets, nonempty translations, format-variable preservation and all
  grammatical plural categories across the five languages.
- Permission-key coverage, English development/fallback metadata, no app locale
  overrides, stable persisted/status values, and direct untranslated UI literals.
- Real Foundation lookup in temporary app/resource bundles for `en`, `de-AT`,
  `fr-CA`, `it-CH`, `es-MX`, unsupported Japanese, and ordered mixed preferences.
- English fallback, InfoPlist and streaming-table lookup, singular/zero/plural
  forms, literal percent signs/Unicode in arguments, remote error templates,
  unknown text and unknown protocol-state preservation.

The standalone Localization GitHub workflow runs this check without requiring
Rust, the streaming runtime, or simulator startup. The existing build workflow
continues to build/test both app targets with the project's pinned dependencies.

Local verification on 2026-10-28 used Xcode 27.0. Shared modules, Mac client and
host modules were compiled against the actual repository C bridge headers, and
all Mac SwiftUI surfaces passed source type checking. The iOS shared, voice and
SwiftTerm modules also compiled against the simulator SDK. iOS UI type checking
stops at the unchanged `toolbarVerticalEdge` API, absent from the local 27.0 SDK. Native resource tests and
project generation/variant-reference checks passed. Full app builds were
attempted: bootstrap is blocked by the absent Rust toolchain; package resolution
cannot supply `Vendor/NocturneRemote.xcframework` without it. The documented
product build uses Xcode 27.1 or newer. These source checks do not establish
linked-app, simulator, screenshot/layout or physical-device acceptance.

No system language, real notification, permission grant, screen capture or
microphone recording was used for localization tests. A final layout review on
real iPhone/iPad/Mac screens, including accessibility text sizes, remains a device
acceptance check; translated labels are generally longer than English.

Apple references: [Bundle language resolution](https://developer.apple.com/documentation/foundation/bundle/preferredlocalizations)
and [native plural dictionaries](https://help.apple.com/xcode/mac/current/en.lproj/devaf8b4090a.html).
