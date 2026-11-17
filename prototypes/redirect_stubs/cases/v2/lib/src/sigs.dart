// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Signature changes (v2 adds a parameter / changes a default value).

String tagged(String s, {String prefix = '>'}) => '$prefix$s';

String tagAll() => tagged('a', prefix: '@');

String hello({String who = 'friend'}) => 'hello $who';

String helloAll() => hello();
