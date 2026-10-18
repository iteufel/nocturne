# Builds and TestFlight

The [Build and TestFlight workflow](https://github.com/iteufel/nocturne/actions/workflows/build.yml)
tests both apps on GitHub's Apple Silicon Xcode 27 runners. Pull requests run the
checks without release credentials. Code changes pushed to `main` run the checks,
then archive, sign, export, and upload the iOS app to App Store Connect. A manual
run can disable the upload with **publish_testflight**.

The store listing is **Nocturne Remote**, app ID `6824278979`, bundle ID
`app.nocturne.client`. The installed app is named **Nocturne**. The shorter store
name was already taken. TestFlight is at
<https://appstoreconnect.apple.com/apps/6824278979/testflight>.

## Verification and artifacts

The first job runs the Swift package tests, the client regression tests on an
iPhone and iPad simulator, and a build of the unified Mac server. Tests that
change physical displays or launch the real streaming engine are disabled.
It retains client test results and a zipped **development** Mac build for seven
days. This Mac artifact is ad-hoc signed, not notarized, and is not a public
release installer. The Mac app's private display APIs require direct distribution;
the TestFlight job is for iOS/iPadOS.

The upload job waits for Apple to finish processing. The build number is
`github.run_number.github.run_attempt`, so rerunning a failed release gets a new
number. Release builds use the marketing version in `scripts/generate-project.rb`.
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
Git credentials, and the workflow has read-only repository permissions.

The distribution identity is imported into a temporary keychain and removed by
the signing action's cleanup. The current **Nocturne App Store** provisioning
profile is downloaded for each release; profiles are removed at the end of the
job. No signed IPA or private signing material is published as a GitHub artifact.

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
Build scripts never start Nocturne Server or change the Mac's display layout.
