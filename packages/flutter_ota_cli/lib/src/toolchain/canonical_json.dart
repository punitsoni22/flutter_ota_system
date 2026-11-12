// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

/// Canonical JSON: UTF-8, object keys sorted, no insignificant whitespace, integers only, strings
/// escaped like `jsonEncode`. Identical to Python's
/// `json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)` for the allowed
/// value set (null, bool, int, String, List, Map with String keys). Same encoding as the
/// prototype `package:patch_security` and `prototypes/security_hardening/tools/toolchain.py`.
Uint8List canonicalJson(Object? value) => Uint8List.fromList(utf8.encode(canonicalJsonString(value)));

String canonicalJsonString(Object? v) {
  if (v == null || v is bool || v is String) return jsonEncode(v);
  if (v is int) return v.toString();
  if (v is List) return '[${v.map(canonicalJsonString).join(',')}]';
  if (v is Map) {
    final keys = v.keys.map((k) => k is String ? k : throw const FormatException('non-string key')).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonicalJsonString(v[k])}').join(',')}}';
  }
  throw FormatException('value of type ${v.runtimeType} is not allowed in canonical JSON');
}
