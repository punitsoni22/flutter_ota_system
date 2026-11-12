// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
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

/// Release and profile builds both count as "release": only debug builds may use http://.
bool get _isDebugBuild => !(debugReleaseModeOverride ?? !kDebugMode);

/// The dart:io client behind the default HTTP client, with a connect timeout.
HttpClient createIoHttpClient() => HttpClient()..connectionTimeout = otaTimeouts.connect;

http.Client createDefaultHttpClient() => IOClient(createIoHttpClient());

/// Why [url] may not be used, or null if it may (SEC-02).
///
/// - `https://` is always allowed.
/// - Release and profile builds: nothing else. Every `http://` URL is refused, localhost included.
/// - Debug builds: also `http://` to loopback (`localhost`, 127.0.0.0/8, `[::1]`) and to
///   `10.0.2.2` (the Android emulator's address for the host computer), for local development.
/// - Every other scheme is refused.
String? insecureUrlProblem(Uri url) {
  if (url.scheme != 'https' && url.scheme != 'http') {
    return 'unsupported URL scheme "${url.scheme}": use https://';
  }
  if (url.host.isEmpty) return 'URL has no host: $url';
  if (url.scheme == 'https') return null;
  final origin = '${url.scheme}://${url.authority}'; // never the path or query
  if (!_isDebugBuild) return 'insecure URL $origin: release builds require https://';
  if (_isLoopback(url.host) || url.host == '10.0.2.2') return null;
  return 'insecure URL $origin: http:// is only allowed for localhost or the Android emulator '
      '(10.0.2.2) in debug builds; use https://';
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

/// Wraps every HTTP client the OTA client uses, so no request can reach a URL that
/// [insecureUrlProblem] refuses, not even through a redirect.
///
/// The inner client never follows redirects itself. This client follows them for GET and HEAD
/// only, at most [maxRedirects] times, and checks every destination first:
/// - each destination must pass [insecureUrlProblem] (release: https only);
/// - an `https://` URL may never redirect to `http://`, in any build (no downgrade);
/// - `Authorization` and `Cookie` headers are dropped when the redirect changes the origin.
///
/// Other methods (POST) get the 3xx response back unchanged; the caller treats it as an error.
class SecureRedirectClient extends http.BaseClient {
  SecureRedirectClient(this._inner, {this.maxRedirects = 5});

  final http.Client _inner;
  final int maxRedirects;

  static const _redirectCodes = {301, 302, 303, 307, 308};
  static const _originBoundHeaders = {'authorization', 'cookie'};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _check(request.url);
    request.followRedirects = false;
    var response = await _inner.send(request);
    final follows = request.method == 'GET' || request.method == 'HEAD';
    var url = request.url;
    var headers = Map.of(request.headers);
    for (var hops = 0; follows && _redirectCodes.contains(response.statusCode); hops++) {
      unawaited(response.stream.listen(null).cancel()); // the redirect's own body is not needed
      if (hops == maxRedirects) throw http.ClientException('too many redirects', url);
      final location = response.headers['location'];
      if (location == null || location.isEmpty) throw http.ClientException('redirect without Location', url);
      final next = url.resolve(location);
      if (url.scheme == 'https' && next.scheme == 'http') {
        throw InsecureUrlException(
          'insecure redirect from https://${url.authority} to http://${next.authority}: '
          'downgrades are never followed',
        );
      }
      _check(next);
      if (next.origin != url.origin) headers.removeWhere((k, _) => _originBoundHeaders.contains(k.toLowerCase()));
      url = next;
      final hop = http.Request(request.method, url)
        ..headers.addAll(headers)
        ..followRedirects = false;
      response = await _inner.send(hop);
    }
    return response;
  }

  static void _check(Uri url) {
    final problem = insecureUrlProblem(url);
    if (problem != null) throw InsecureUrlException(problem);
  }

  @override
  void close() => _inner.close();
}
