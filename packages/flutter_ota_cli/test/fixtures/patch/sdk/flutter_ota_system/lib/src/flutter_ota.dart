// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

abstract final class FlutterOta {
  static T feature<T extends Object>(String name, T Function() aotFactory) =>
      aotFactory();
}
