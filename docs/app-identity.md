# App Identity

What to change to publish Gwardian under your own Apple and Google accounts.
The visible name is already Gwardian; these are the identifiers the stores
and push notifications use.

## One setting per platform

| Platform | Setting | Current value |
|---|---|---|
| iOS | `GWARDIAN_BUNDLE_ID` in `apps/ios/Ash/Ash.xcodeproj/project.pbxproj` (project build settings, Debug and Release) | `com.monadial.ash.protocol` |
| Android | `gwardian.applicationId` in `apps/android/gradle.properties` | `com.monadial.ash` |

The identifier is a domain you own, reversed: `gwardian.ch` gives
`ch.gwardian.app`. The test targets follow (`<id>.tests`, `<id>.uitests`),
and the Google Play upload reads the Android value.

Unchanged on purpose: the Kotlin package `com.monadial.ash`, the Xcode
target `Ash`, the Rust crates and internal storage names. Users never see
them, and storage is per app anyway.

## Accounts and secrets

- **Apple**: set your team in Xcode (the project carries none) and the
  `APPLE_TEAM_ID`, certificate, provisioning profile and App Store Connect
  secrets used by `.github/workflows/deploy-ios.yml`.
- **Google Play**: a new app with the new package name, its upload keystore
  and the `ANDROID_KEYSTORE_*` and `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`
  secrets used by `.github/workflows/deploy-android.yml`.
- **Push notifications**: an APNs key from your Apple account, and the relay
  started with `APNS_BUNDLE_ID` set to the iOS identifier
  (`infra/scaleway/terraform.tfvars.example`).

## What happens on a phone

A new identifier is a new app: it does not see the old app's conversations,
pads or app code. Phones that had a test build start from scratch.
