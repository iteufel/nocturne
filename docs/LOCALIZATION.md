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
capabilities, CLI commands, internal gesture names and diagnostic logs are not translated. Stored values
such as `Match device`, tab IDs, appearance raw values and status comparisons stay
unchanged. Only their UI labels are localized. Provider-generated metadata and
external service prose remain provider-owned.

The integrated localization covers CallKit and local attention, chat activity
and approval controls, the Mac browser, simulator control, and the headless
display settings. Their labels, help text and owned errors share the same five
native language tables. Provider policy descriptions remain provider-owned;
only Nocturne's own policy choices and scope messages are translated. Saved
command prefixes remain literal arguments inside the translated explanation.

Browser frames optionally mark host-authored notices so the receiving client
can translate them. Website alerts and WebKit errors remain verbatim, even when
their text matches a Nocturne message. Older frames without this marker also
remain verbatim. Remote APNs payloads remain stable protocol content; only the
local presentation boundary translates them. Integrators should reuse
`L`/`LCount` for presentation text and keep protocol and storage values stable.
There is no in-app language selector.

## App Intents metadata

App Intents resolves its metadata from each executable's main bundle. The app
and Attention extension both include the dedicated `AppIntents.strings` table in
all five languages. Intent titles and parameter labels name that table and keep
the default main bundle; ordinary UI continues to use the shared SwiftPM bundle.
The Xcode metadata exporter rejects custom-bundle resources even when Swift
SDK typechecking succeeds. The native runtime check covers the main-table
lookup and English fallback, and the generator includes the same table in both
targets.

Apple documents [deferred App Intents string resolution](https://developer.apple.com/documentation/foundation/localizedstringresource)
and [main-bundle lookup by default](https://developer.apple.com/videos/play/wwdc2025/225/).
The main-bundle restriction is additionally enforced by the installed Apple
`appintentsmetadataprocessor`; it is reproduced by the regression probe below.

## Verification

Run `python3 scripts/check-localization.py --runtime` on macOS. With the existing
`xcodeproj` gem used by bootstrap, also run
`ruby scripts/test-attention-metadata.rb --verify-rejection`. This builds only the
production intent declaration with a compile-only app boundary, never launches
an app or sends a decision, and runs the real Xcode exporter for an app and an
extension. It verifies their five bundled tables and proves that the exporter
rejects the previous custom-bundle mistake. Full production builds remain CI
checks.

The localization runtime check covers:

- Identical key sets, nonempty translations, format-variable preservation and all
  grammatical plural categories across the five languages.
- Permission-key coverage, English development/fallback metadata, no app locale
  overrides, stable persisted/status values, and direct untranslated UI literals.
- Real Foundation lookup in temporary app/resource bundles for `en`, `de-AT`,
  `fr-CA`, `it-CH`, `es-MX`, unsupported Japanese, and ordered mixed preferences.
- English fallback, InfoPlist and streaming-table lookup, singular/zero/plural
  forms, literal percent signs/Unicode in arguments, remote error templates,
  browser titles, simulator states, approval scopes, unknown text and unknown
  protocol-state preservation.

The standalone Localization GitHub workflow runs this check without requiring
Rust, the streaming runtime, or simulator startup. The existing build workflow
continues to build/test both app targets with the project's pinned dependencies.

Local verification on 2026-11-09 used Xcode 27.1. All 1,157 strings, seven
plural keys, ten streaming overlays and permission resources passed validation.
Eight native language/preference/fallback cases passed. The actual App Intents
metadata exporter accepted the main-bundle resources in the app and extension,
including all five language tables, and rejected the former custom-bundle
regression. The integrated Mac app and iOS simulator test bundle build. The
combined feature suite passes 129 tests, with ten hardware/provider-dependent
tests skipped. A real WebKit fixture confirms that a website alert matching a
host warning remains website content, while the host warning is marked for
translation. The [PR checks](https://github.com/iteufel/nocturne/pull/30/checks)
record the complete iPhone/iPad, Mac and broker build/test results. The shared
runtime update now requires macOS 15+; see [Development](DEVELOPMENT.md).

The complete native client suite also passes on iPhone Duo in German (104 tests,
five skips) and iPad Pro in English (105 tests, four skips). The existing input
tests verify that internal gesture names stay stable under German, and host
status assertions use localized expectations. The voice-preflight cancellation
test passes in both suites and in 30 consecutive isolated runs.

Resource checks do not change system language, deliver notifications, grant
permissions, capture a screen or record microphone input. A final layout review on
real iPhone/iPad/Mac screens, including accessibility text sizes, remains a device
acceptance check; translated labels are generally longer than English.

Apple references: [Bundle language resolution](https://developer.apple.com/documentation/foundation/bundle/preferredlocalizations)
and [native plural dictionaries](https://help.apple.com/xcode/mac/current/en.lproj/devaf8b4090a.html).
