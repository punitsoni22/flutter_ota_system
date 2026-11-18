// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Functions whose v2 versions use new helpers, a new class and a new file.

import 'extra/new_feature.dart';

String greetAll(List<String> ns) => ns.map(_wrap).join(',');

// NEW private top-level helper (Tier 2).
String _wrap(String s) => '<$s>';

// NEW class (Tier 2).
class Badge {
  final String t;

  Badge(this.t);

  String render() => '#$t!';
}

String badge(String t) => Badge(t).render();

String latest() => fresh();
