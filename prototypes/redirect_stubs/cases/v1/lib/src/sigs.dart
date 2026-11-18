// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Signature changes (v2 adds a parameter / changes a default value).

String tagged(String s) => '#$s';

String tagAll() => tagged('a');

String hello({String who = 'you'}) => 'hello $who';

String helloAll() => hello();
