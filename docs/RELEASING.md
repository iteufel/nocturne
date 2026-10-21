# Builds and TestFlight

The [Build and Release workflow](https://github.com/iteufel/nocturne/actions/workflows/build.yml)
tests both apps on GitHub's Apple Silicon Xcode 27 runners. Pull requests run the
checks without release credentials. Code changes pushed to `main` run the checks,
then archive, sign, export, and upload the iOS app to App Store Connect. It also
builds a Developer ID-signed Mac server, notarizes it with Apple, and publishes
the verified ZIP as a GitHub preview release. A manual run can disable either
release with **publish_testflight** or **publish_macos**.

The iOS jobs install Xcode's Metal Toolchain, which the SwiftTerm renderer needs and
the runner image does not include. Bootstrap generates pixel-exact, opaque RGB
icons. The iOS bundle includes required-reason privacy declarations for app
preferences, local/user-selected file metadata, and media timers.

The store listing is **Nocturne Remote**, app ID `6824278979`, bundle ID
`app.nocturne.client`. The installed app is named **Nocturne**. The shorter store
name was already taken. TestFlight is at
<https://appstoreconnect.apple.com/apps/6824278979/testflight>.

## Verification and artifacts

Mac verification runs the Swift package tests and builds the unified server.
A separate job runs the client regression tests on an iPhone and iPad simulator.
Mac releases require Mac verification; TestFlight requires both verification jobs.
This keeps simulator delays from blocking a verified Mac release. Tests that
change physical displays or launch the real streaming engine are disabled.
CI boots one temporary simulator at a time and waits for startup before testing,
then shuts down and deletes that simulator. This avoids concurrent startup
timeouts on the hosted runner and does not affect local development simulators.
It retains client test results for seven days. The ad-hoc development Mac
build is a compilation check and is no longer offered as a download. Mac
downloads come from the signed release job, which signs all nested binaries,
checks their signing team and secure timestamps, notarizes the app, staples
Apple's ticket, and requires Gatekeeper to accept it before publication. The Mac
app's private display APIs require direct distribution; TestFlight is for iOS/iPadOS.

The upload job waits for Apple to finish processing. The build number is
`github.run_number.github.run_attempt`, so rerunning a failed release gets a new
number. Both app bundles use Xcode's build and marketing version settings; the
Mac release script rejects a bundle whose build number does not match the request.
Release builds use the marketing version in `scripts/generate-project.rb`.
An upload does not submit an App Store release or automatically request external
beta review. Internal groups can automatically receive processed builds; external
testing requires Apple's beta review and its own tester group.

## Signing configuration

The `testflight` GitHub environment allows deployments from `main` only. It stores
these values; private keys and signing files must never be committed:

| Kind | Name | Purpose |
| --- | --- | --- |
| Variable | `APPLE_TEAM_ID` | Developer team used for code signing |
| Variable | `APPSTORE_APP_ID` | Numeric App Store Connect app ID |
| Variable | `APPSTORE_ISSUER_ID` | API issuer ID |
| Variable | `APPSTORE_API_KEY_ID` | Dedicated Nocturne API key ID |
| Secret | `APPSTORE_API_PRIVATE_KEY` | Downloaded API `.p8` contents |
| Secret | `APPSTORE_CERTIFICATES_FILE_BASE64` | Base64 distribution `.p12` |
| Secret | `APPSTORE_CERTIFICATES_PASSWORD` | Password for that `.p12` |

The dedicated API key is named **Nocturne GitHub TestFlight**, with App Manager
access. Apple team API keys apply to all apps on the team; keep this credential
limited to the protected release environment. The API key is not used in pull
request builds. All actions are pinned to commit hashes, checkout does not retain
Git credentials, and the workflow has read-only repository permissions by default.

The distribution identity is imported into a temporary keychain and removed by
the signing action's cleanup. The current **Nocturne App Store** provisioning
profile is downloaded for each release; profiles are removed at the end of the
job. No signed IPA or private signing material is published as a GitHub artifact.
Archive signing overrides are scoped to the iOS application target so SwiftPM
build tools and resource bundles do not receive the application's provisioning
profile.

Apple Files adds the extension bundle ID `app.nocturne.client.files`. Before a signed device build or TestFlight release, register that explicit App ID and the App Group `group.app.nocturne.client`, assign the group to both the app and extension, and regenerate the containing app’s **Nocturne App Store** profile with that entitlement. Create an `IOS_APP_STORE` profile named **Nocturne Files App Store** for the extension. Its Keychain entitlement shares the containing app’s existing `$(AppIdentifierPrefix)app.nocturne.client` access group. The archive script selects a separate provisioning profile for each target, the export options include both bundle IDs, and CI downloads both profiles. Simulator builds do not validate these Apple Developer portal assignments.

The initial distribution certificate and provisioning profile expire on
**18 October 2027**. Before expiry, create a new distribution identity and an
`IOS_APP_STORE` profile named **Nocturne App Store** for `app.nocturne.client`,
replace the two certificate secrets, and run the workflow. Never revoke identities
used by other apps. Revoke and replace the dedicated API key if it is compromised.

For a local archive with the distribution identity and profile already installed:

```sh
NOCTURNE_DEVELOPMENT_TEAM='<team ID>' \
NOCTURNE_BUILD_NUMBER='<unused numeric build number>' scripts/archive-ios.sh
```

The archive and exported IPA stay in the ignored `.build/TestFlight` directory.
Build scripts never start Nocturne or change the Mac's display layout.

## Signed Mac downloads

Use the ZIP attached to a [Mac release](https://github.com/iteufel/nocturne/releases).
Quit any running copy of Nocturne, unzip the download, and move Nocturne.app to Applications.
The ZIP includes the stapled notarization ticket; `SHA256SUMS.txt` accompanies it.
Builds target Apple Silicon and macOS 14 or later. They remain previews, with the
display limitations described in [VERIFICATION.md](VERIFICATION.md).

The `macos-release` environment also permits `main` only. It stores:

| Kind | Name | Purpose |
| --- | --- | --- |
| Variable | `APPLE_TEAM_ID` | Expected team for every nested binary |
| Variable | `MACOS_SIGNING_IDENTITY` | Developer ID Application certificate fingerprint |
| Variable | `NOTARY_KEY_ID` | App Store Connect API key ID |
| Variable | `NOTARY_ISSUER_ID` | API issuer ID |
| Secret | `MACOS_CERTIFICATES_FILE_BASE64` | Base64 Developer ID `.p12`, including its certificate chain |
| Secret | `MACOS_CERTIFICATES_PASSWORD` | Password for that `.p12` |
| Secret | `NOTARY_API_PRIVATE_KEY` | Existing Nocturne API `.p8` for notarization |

The initial Developer ID certificate expires on **17 November 2027**. Renew it
before then and update the signing identity and certificate secrets. The signing
keychain and temporary API key are removed after each job. Only this protected
release job has repository write permission, to create the GitHub release.

`scripts/release-macos.sh` builds and signs the app, saves the notarization request
and result under `.build/MacRelease`, and publishes a ZIP only after Apple accepts
it and local Gatekeeper verification succeeds. CI retains signing diagnostics for
seven days. The script never starts the streaming engine or changes display state.

`python3 scripts/verify-macos-release.py '/path/Nocturne.app' '<team ID>'`
checks every Mach-O binary. This catches the Team ID mismatch that made the old
ad-hoc runtime abort during library loading, as well as missing Developer ID
signatures or secure timestamps. Keep Gatekeeper enabled; a downloadable release
must pass `spctl --assess --type execute --verbose=4 '/path/Nocturne.app'`.
