// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

/// Canonical JSON used for the signed `dbc-v1` manifest (not the ADR-0002 message of the older
/// formats): UTF-8, object keys sorted by UTF-16 code units, no insignificant whitespace,
/// integers only (no floating point), strings escaped exactly like `jsonEncode`.
///
/// Only null, bool, int, String, List and `Map<String, …>` are allowed, so the encoding is
/// unambiguous and identical in Dart and Python (`json.dumps(sort_keys=True,
/// separators=(',', ':'), ensure_ascii=False)` for the same value set).
Uint8List canonicalJson(Object? value) => Uint8List.fromList(utf8.encode(_encode(value)));

String _encode(Object? v) {
  if (v == null || v is bool || v is String) return jsonEncode(v);
  if (v is int) return v.toString();
  if (v is List) return '[${v.map(_encode).join(',')}]';
  if (v is Map) {
    final keys = v.keys.map((k) => k is String ? k : throw const FormatException('non-string key')).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_encode(v[k])}').join(',')}}';
  }
  throw FormatException('value of type ${v.runtimeType} is not allowed in canonical JSON');
}

/// Parses [bytes] and requires them to be exactly the canonical encoding of the result
/// (rejects whitespace, unsorted or duplicate keys, floats, non-canonical escapes).
Map<String, Object?> parseCanonicalObject(Uint8List bytes) {
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    throw const FormatException('manifest is not UTF-8');
  }
  if (!_withinDepth(bytes)) throw const FormatException('manifest is nested more than $maxJsonDepth levels deep');
  final Object? value;
  try {
    value = jsonDecode(text);
  } on FormatException {
    throw const FormatException('manifest is not JSON');
  }
  if (value is! Map<String, Object?>) throw const FormatException('manifest is not a JSON object');
  final again = canonicalJson(value);
  if (again.length != bytes.length || !_equal(again, bytes)) {
    throw const FormatException('manifest is not in canonical form');
  }
  return value;
}

/// Signed documents are shallow (a few levels). Hostile input nested thousands of levels deep would
/// overflow the stack in the recursive decoder and encoder, so it is refused before parsing. The
/// server uses the same limit.
const maxJsonDepth = 32;

/// Counts `[`/`{` nesting without recursion, skipping string contents.
bool _withinDepth(Uint8List bytes) {
  var depth = 0, inString = false, escaped = false;
  for (final b in bytes) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (b == 0x5c) {
        escaped = true; // backslash
      } else if (b == 0x22) {
        inString = false;
      }
    } else if (b == 0x22) {
      inString = true;
    } else if (b == 0x5b || b == 0x7b) {
      if (++depth > maxJsonDepth) return false;
    } else if (b == 0x5d || b == 0x7d) {
      depth--;
    }
  }
  return true;
}

bool _equal(Uint8List a, Uint8List b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
