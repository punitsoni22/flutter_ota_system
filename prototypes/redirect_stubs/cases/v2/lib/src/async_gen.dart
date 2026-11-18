// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// async, async* and sync* bodies, plus a private async helper.

class Loader {
  Future<int> load(int x) async {
    await Future<void>.delayed(Duration.zero);
    return x + 2;
  }

  Stream<int> ticks(int n) async* {
    for (var i = 0; i < n; i++) {
      yield i * 10;
    }
  }

  Iterable<String> names() sync* {
    yield 'a';
    yield 'c';
    yield 'd';
  }

  Future<String> fetch() async => 'value=${await _get()}';

  Future<int> _get() async => 2;
}
