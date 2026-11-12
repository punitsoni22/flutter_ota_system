# Apple App Store considerations

> [!IMPORTANT]
> This documentation is provided for technical guidance and is not legal advice. Platform
> policies can change. Developers are responsible for independently reviewing the policies
> applicable to their applications and distribution channels.
>
> Apple pages quoted here were checked on **2026-11-12**. Apple has not reviewed or approved
> Flutter OTA System. **No App Store compatibility is claimed.**

## Current status: no iOS support

| | Status |
|---|---|
| iOS plugin implementation | **Not implemented.** The package's `pubspec.yaml` declares the Android platform only |
| iOS code patches | **Not implemented** |
| iOS testing | **Not tested at all** |
| `MockPatchRuntime` (inert data) on iOS | Not supported or tested |

## Why the Android implementation cannot be assumed to work on iOS

The Android code-patch runtime depends on Android-specific mechanisms: an Android content
provider that runs before the app, Android's `FlutterLoader`, and loading a rebuilt `libapp.so`
from the app's private files directory ([google-play.md](google-play.md#what-the-android-code-patch-runtime-actually-does)).
iOS apps are built differently (the compiled Dart code is part of the signed app bundle), and the
plugin has no iOS code at all. Nothing in the Android implementation carries over.

## Guideline 2.5.2

From the [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
(page "Last Updated: October 16, 2026"), 2.5.2:

> "Apps should be self-contained in their bundles, and may not read or write data outside the
> designated container area, nor may they download, install, or execute code which introduces or
> changes features or functionality of the app, including other apps. Educational apps designed
> to teach, develop, or allow students to test executable code may, in limited circumstances,
> download code provided that such code is not used for other purposes. Such apps must make the
> source code provided by the app completely viewable and editable by the user."

Any future iOS OTA patching that downloads, installs or executes code changing an app's features
or functionality is directly relevant to this guideline. The educational exception is narrow
(apps that teach or let students test code, with the code viewable and editable) and does not
describe an OTA system for general apps.

Guideline 4.7 allows certain software that is not embedded in the binary (HTML5 and JavaScript
mini apps and mini games, streaming games, chatbots and plug-ins) with conditions, including
4.7.2: "Your app may not extend or expose native platform APIs or technologies to the software
without prior permission from Apple." It is not a basis for native code patches.

## What future iOS support would need

- **Separate engineering:** a different technical approach than Android (iOS does not allow the
  Android mechanism), designed and tested on iOS.
- **Separate policy review** of that approach against the guidelines and the Apple Developer
  Program License Agreement in force at the time. Enterprise or other non-App Store distribution
  is governed by its own Apple agreements and is **not automatically exempt**.
- **Privacy and SDK requirements:** Apple's [third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
  make the app developer "responsible for all the code the SDK includes in your app". A
  [privacy manifest](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
  (`PrivacyInfo.xcprivacy`) describes "the data your app or third-party SDK collects and the
  required reasons APIs it uses". A manifest must describe a real implementation, so none is
  included today.

The project adds no iOS implementation, platform declaration or privacy manifest until such work
is done and reviewed.

## Sources

| Title | Publisher | URL | Date shown | Section | Checked |
|---|---|---|---|---|---|
| App Review Guidelines | Apple | https://developer.apple.com/app-store/review/guidelines/ | Last Updated: October 16, 2026 | 2.5.2; 4.7, 4.7.2 | 2026-11-12 |
| Third-party SDK requirements | Apple | https://developer.apple.com/support/third-party-SDK-requirements/ | None shown | Whole page | 2026-11-12 |
| Privacy manifest files | Apple | https://developer.apple.com/documentation/bundleresources/privacy-manifest-files | None shown | Overview | 2026-11-12 |
| Developing packages & plugins | Flutter | https://docs.flutter.dev/packages-and-plugins/developing-packages | Last updated 2026-11-03 | Specifying a plugin's supported platforms | 2026-11-12 |
