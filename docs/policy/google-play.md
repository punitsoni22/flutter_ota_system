# Google Play policy considerations

> [!WARNING]
> Flutter OTA System's experimental AotPatchRuntime modifies executable application code through
> an OTA patching mechanism. Its use in applications distributed through Google Play presents a
> significant policy risk under Google Play's Device and Network Abuse policy. Do not assume that
> the runtime is permitted for Play-distributed applications. Independently review the current
> policy and obtain appropriate guidance before using it in a distributed application.

> [!IMPORTANT]
> This documentation is provided for technical guidance and is not legal advice. Platform
> policies can change. Developers are responsible for independently reviewing the policies
> applicable to their applications and distribution channels.
>
> Google Play pages quoted here were checked on **2026-11-12**. Google has not reviewed, approved
> or ruled on Flutter OTA System.

## What the Android code-patch runtime actually does

`AotPatchRuntime` (format `aot-bidiff-android-v1`) changes the app's **compiled Dart code**. In
Flutter release builds that code is `libapp.so`: an ELF shared library of **native ARM machine
code** produced by Dart's ahead-of-time (AOT) compiler, one per CPU ABI. Step by step:

1. **Build machine** ([`cli/android.py`](https://github.com/punitsoni22/flutter_ota_system/blob/main/cli/android.py)):
   `ota patch android` rebuilds the app, extracts `lib/<abi>/libapp.so` from the new and the
   registered store build, refuses changes outside Dart code (native libraries, Java/Kotlin,
   manifest, resources, assets), and produces a **binary diff** per ABI
   ([`otadiff.py`](https://github.com/punitsoni22/flutter_ota_system/blob/main/cli/otadiff.py),
   bsdiff in an `OTADIF01` container). The server signs it.
2. **Device, download** ([`ota_client.dart`](https://github.com/punitsoni22/flutter_ota_system/blob/main/packages/ota_client/lib/src/ota_client.dart)):
   the app downloads the diff (not a whole `.so`) from the operator's server/CDN and verifies its
   size, SHA-256 and ES256 signature.
3. **Device, reconstruction** ([`aot_runtime.dart`](https://github.com/punitsoni22/flutter_ota_system/blob/main/packages/ota_client/lib/src/aot_runtime.dart),
   [`OtaClientPlugin.java`](https://github.com/punitsoni22/flutter_ota_system/blob/main/packages/ota_client/android/src/main/java/io/github/punitsoni22/flutter_ota_system/OtaClientPlugin.java)):
   the store `libapp.so` is copied out of the installed APK, the diff is applied, and the result,
   a **new `libapp.so`** whose hash matches the signed value, is written into the app's private
   files directory.
4. **Device, loading** ([`OtaBoot.java`](https://github.com/punitsoni22/flutter_ota_system/blob/main/packages/ota_client/android/src/main/java/io/github/punitsoni22/flutter_ota_system/OtaBoot.java)):
   at the next cold start a content provider runs before the app's code and passes
   `--aot-shared-library-name=<path>` to stock Flutter's `FlutterLoader`, so the Flutter engine
   loads and executes the new library instead of the one installed from the store.

In short: the app **downloads data that it turns into a native `.so` file and then executes**,
outside Google Play's update mechanism. The other runtime, `MockPatchRuntime` (`mock-v1`),
downloads an inert data file that the app reads; no code is downloaded or executed.

**Bytecode architecture (`dbc-v1`).** It never downloads a `.so` file or replaces `libapp.so`.
Patches are Dart bytecode run by the Dart VM interpreter in the custom engine of the store build.
Whether Google Play's interpreter provisions cover this has **not** been reviewed by Google or a
lawyer; no compatibility is claimed. The `public_store` policy approval is not required for
`dbc-v1` yet ([backend protocol §7](../architecture/phase-4-backend-protocol.md#7-known-limits)).

## Relevant Google Play provisions

From [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/16559646)
("Full Policy"; the older URL `answer/9888379` redirects there):

> "An app distributed via Google Play may not modify, replace, or update itself using any method
> other than Google Play's update mechanism. Likewise, an app may not download executable code
> (such as dex, JAR, .so files) from a source other than Google Play."

> "This restriction does not apply to code that runs in a virtual machine or an interpreter where
> either provides indirect access to Android APIs (such as JavaScript in a webview or browser)."

Listed as an example violation:

> "Apps or third party code (for example, SDKs) that download executable code, such as dex files
> or native code, from a source other than Google Play."

From [SDK Requirements](https://support.google.com/googleplay/android-developer/answer/13323374):

> "If you include an SDK in your app, you are responsible for ensuring that their third-party code
> and practices do not cause your app to violate Google Play Developer Program Policies."

with the example "Your app includes an SDK that downloads executable code, such as dex files or
native code, from a source other than Google Play."

## Why this is a significant concern

- The policy names **`.so` files** and **native code** explicitly, and code patches produce and
  run a new `libapp.so` that did not come from Google Play.
- It also forbids an app updating itself outside Google Play's update mechanism; a code patch
  changes the app's behaviour without a Play update.
- The exception covers code that runs **in a virtual machine or an interpreter** with **indirect**
  access to Android APIs. AOT-compiled Dart in `libapp.so` runs directly on the CPU. We do not
  consider it safe to treat it as covered by the exception.
- **Uncertain:** the policy text does not discuss binary diffs. Downloading a diff instead of a
  complete `.so` should not be assumed to make a difference, because the result that runs is
  native code obtained outside Google Play.

For these reasons Flutter OTA System **must not be advertised or treated as Google Play
compatible** for code patches.

## Who is responsible

The developer who integrates the SDK and publishes the app is responsible for the app's
compliance, including the behaviour of every SDK in it (see the SDK Requirements quote above).
The project gives you this analysis, not a compliance guarantee.

A successful local test, an internal test track or even a published update does **not** show that
Google Play permits the behaviour: policy enforcement can happen later, and policies change.

## The server's `public_store` gate

Each application on the server has a `distribution` field (`public_store` or `enterprise`, the
default). The server refuses to publish code patches for a `public_store` app until someone runs
`ota app approve-policy` with a reason
([`routers/admin.py`](https://github.com/punitsoni22/flutter_ota_system/blob/main/backend/app/routers/admin.py)).
This is an **operator-controlled switch** that records a decision; it is not a policy review, and
the label `enterprise` does not make anything compliant.

## Distribution channels and update types

| Update type | What changes | Consideration |
|---|---|---|
| Full store release (APK/AAB through Google Play) | Anything | Google Play's normal review and update mechanism |
| Experimental native AOT patch (`AotPatchRuntime`) | Compiled Dart code (`libapp.so`, native code) | The significant concern described above |
| Configuration-only change (`MockPatchRuntime`, inert data) | Data your app reads | Not executable code, so the provision above is not directly about it. Still review what the data can change (other policies, e.g. on deceptive behaviour or changes after review, may apply) and how your app uses it. **Not automatically compliant** |
| Other non-executable content (images, text) | Content | Depends on your app and the content policies |

**Other channels.** The quoted provision is written for apps distributed via Google Play. Private
apps distributed through managed Google Play remain subject to Google Play's policies. Enterprise
or MDM distribution outside Google Play, sideloading and other app stores have their own rules,
contracts and security implications (for example Google Play Protect scanning). None of these
channels makes the implementation automatically compliant; review the rules that apply to yours.

## Before you use `AotPatchRuntime` in a distributed app

- [ ] Read the current [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/16559646)
      and [SDK Requirements](https://support.google.com/googleplay/android-developer/answer/13323374) policies.
- [ ] Decide, with appropriate guidance, whether your distribution channel allows it.
- [ ] Record the decision (`ota app approve-policy` for `public_store` apps).
- [ ] Review the [security model](../security.md) and [signing keys](../security.md#developer-owned-signing).
- [ ] Declare the SDK's data handling ([privacy-and-data-handling.md](../privacy-and-data-handling.md)).

## Sources

| Title | Publisher | URL | Date shown | Section | Checked |
|---|---|---|---|---|---|
| Device and Network Abuse | Google (Play Console Help) | https://support.google.com/googleplay/android-developer/answer/16559646 | None shown | Full Policy; examples of violations; key considerations | 2026-11-12 |
| SDK Requirements | Google (Play Console Help) | https://support.google.com/googleplay/android-developer/answer/13323374 | None shown | Device and Network Abuse examples | 2026-11-12 |
| Provide information for Google Play's Data safety section | Google (Play Console Help) | https://support.google.com/googleplay/android-developer/answer/10787469 | Latest change-log entry: December 5, 2023 | Data collection; data types | 2026-11-12 |
| Managed Google Play Agreement Addendum | Google | https://play.google/work/developer-distribution-agreement-addendum/ | December 30, 2016 | Applicability of the Developer Program Policies | 2026-11-11 |
