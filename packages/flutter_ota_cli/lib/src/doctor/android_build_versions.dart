// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// The Android build tool versions of a Flutter app (Gradle wrapper, Android Gradle plugin, Kotlin
/// Gradle plugin) and the minimums a Flutter version enforces.
///
/// Flutter 3.50's Gradle plugin refuses to build below Gradle 9.3.1, AGP 9.1.1 and KGP 2.4.10
/// (official breaking change "build tool minimums"). Older Flutter versions only warn, so they have
/// no entry here.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Minimum build tool versions enforced by one Flutter version.
class AndroidBuildMinimums {
  const AndroidBuildMinimums({required this.gradle, required this.agp, required this.kgp});

  final String gradle;
  final String agp;
  final String kgp;
}

/// Enforced minimums by Flutter `major.minor`.
const enforcedAndroidMinimums = <String, AndroidBuildMinimums>{
  '3.50': AndroidBuildMinimums(gradle: '9.3.1', agp: '9.1.1', kgp: '2.4.10'),
};

/// The minimums [flutterVersion] (for example `3.50.0`) enforces, or null.
AndroidBuildMinimums? minimumsFor(String flutterVersion) {
  final parts = flutterVersion.split('.');
  if (parts.length < 2) return null;
  return enforcedAndroidMinimums['${parts[0]}.${parts[1]}'];
}

/// Versions found in an app's `android/` folder (null when not found).
class AndroidBuildVersions {
  const AndroidBuildVersions({this.gradle, this.agp, this.kgp});

  final String? gradle;
  final String? agp;
  final String? kgp;

  /// Reads `android/gradle/wrapper/gradle-wrapper.properties` and `android/settings.gradle(.kts)`.
  static AndroidBuildVersions read(String appDir) {
    String? text(String rel) {
      final f = File(p.join(appDir, rel));
      return f.existsSync() ? f.readAsStringSync() : null;
    }

    final wrapper = text(p.join('android', 'gradle', 'wrapper', 'gradle-wrapper.properties')) ?? '';
    final settings = text(p.join('android', 'settings.gradle.kts')) ?? text(p.join('android', 'settings.gradle')) ?? '';
    String? plugin(String id) => RegExp(
      'id[ (]*["\']${RegExp.escape(id)}["\'][ )]*version[ (]*["\']([0-9][^"\']*)["\']',
    ).firstMatch(settings)?.group(1);
    return AndroidBuildVersions(
      gradle: RegExp(
        r'distributionUrl=.*gradle-([0-9][0-9A-Za-z.\-]*?)-(?:all|bin)\.zip',
      ).firstMatch(wrapper)?.group(1),
      agp: plugin('com.android.application'),
      kgp: plugin('org.jetbrains.kotlin.android'),
    );
  }

  /// Human-readable problems against [min] (empty when every found version is high enough).
  /// A version that cannot be found is not reported: the Flutter build checks it again.
  List<String> problemsAgainst(AndroidBuildMinimums min) => [
    if (gradle != null && compareVersions(gradle!, min.gradle) < 0) 'Gradle $gradle < ${min.gradle}',
    if (agp != null && compareVersions(agp!, min.agp) < 0) 'Android Gradle plugin $agp < ${min.agp}',
    if (kgp != null && compareVersions(kgp!, min.kgp) < 0) 'Kotlin Gradle plugin $kgp < ${min.kgp}',
  ];
}

/// Compares dotted version numbers numerically (`9.10.0` > `9.3.1`); pre-release suffixes after a
/// `-` are ignored.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v.split('-').first.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}
