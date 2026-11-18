// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// async, async* and sync* bodies, plus a private async helper.

class Loader {
  Future<int> load(int x) async {
    await Future<void>.delayed(Duration.zero);
    return x + 1;
  }

  Stream<int> ticks(int n) async* {
    for (var i = 0; i < n; i++) {
      yield i;
    }
  }

  Iterable<String> names() sync* {
    yield 'a';
    yield 'b';
  }

  Future<String> fetch() async => 'v${await _get()}';

  Future<int> _get() async => 1;
}
