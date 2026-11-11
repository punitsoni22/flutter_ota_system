// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Network timeouts of the client (SEC-15). Internal; not part of the public API.
class OtaTimeouts {
  const OtaTimeouts({
    this.connect = const Duration(seconds: 15),
    this.request = const Duration(seconds: 15),
    this.downloadResponse = const Duration(seconds: 30),
    this.downloadIdle = const Duration(seconds: 30),
    this.downloadTotal = const Duration(minutes: 10),
  });

  /// Opening the TCP/TLS connection (default HTTP client only).
  final Duration connect;

  /// A whole API call: register, update check, events.
  final Duration request;

  /// Until the patch download's response headers arrive.
  final Duration downloadResponse;

  /// Longest pause between two chunks of the patch download.
  final Duration downloadIdle;

  /// The whole patch download.
  final Duration downloadTotal;
}

OtaTimeouts _timeouts = const OtaTimeouts();

OtaTimeouts get otaTimeouts => _timeouts;

/// Tests use short timeouts; null restores the defaults.
@visibleForTesting
set debugOtaTimeouts(OtaTimeouts? value) => _timeouts = value ?? const OtaTimeouts();

/// Tests set this to check release-build behaviour (flutter test always runs in debug mode).
@visibleForTesting
bool? debugReleaseModeOverride;

/// Release and profile builds both count as "release": only debug builds get the emulator exception.
bool get _isDebugBuild => !(debugReleaseModeOverride ?? !kDebugMode);

/// The dart:io client behind the default HTTP client, with a connect timeout.
HttpClient createIoHttpClient() => HttpClient()..connectionTimeout = otaTimeouts.connect;

http.Client createDefaultHttpClient() => IOClient(createIoHttpClient());

/// Why [url] may not be used, or null if it may (SEC-02).
///
/// - `https://` is always allowed.
/// - `http://` to loopback (`localhost`, 127.0.0.0/8, `[::1]`) is allowed in every build: that
///   traffic never leaves the device (local testing of release builds through `adb reverse`).
/// - `http://10.0.2.2` (the Android emulator's address for the host computer) only in debug builds.
/// - Any other `http://`, and every other scheme, is refused.
String? insecureUrlProblem(Uri url) {
  if (url.scheme != 'https' && url.scheme != 'http') {
    return 'unsupported URL scheme "${url.scheme}": use https://';
  }
  if (url.host.isEmpty) return 'URL has no host: $url';
  if (url.scheme == 'https') return null;
  if (_isLoopback(url.host)) return null;
  if (_isDebugBuild && url.host == '10.0.2.2') return null;
  final origin = '${url.scheme}://${url.authority}'; // never the path or query
  return _isDebugBuild
      ? 'insecure URL $origin: http:// is only allowed for localhost or the Android emulator (10.0.2.2) '
          'in debug builds; use https://'
      : 'insecure URL $origin: release builds require https:// (http:// only for localhost)';
}

/// Thrown for a refused URL; its text is the reason only (no "Bad state:" prefix).
class InsecureUrlException implements Exception {
  const InsecureUrlException(this.message);
  final String message;

  @override
  String toString() => message;
}

bool _isLoopback(String host) {
  if (host == 'localhost') return true;
  return InternetAddress.tryParse(host)?.isLoopback ?? false;
}
