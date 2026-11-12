// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Host functions a probe calls across the AOT/interpreter boundary (Part 6.4).

import 'dart:async';

import 'package:app_models/app_models.dart';

class HostError implements Exception {
  HostError(this.message);
  final String message;
  @override
  String toString() => 'HostError($message)';
}

/// A host interface that a module implements and the host then calls.
abstract class Greeter {
  String greet(String name);
}

int hostApply(int Function(int) f, int x) => f(x);
Future<int> hostFuture(int x) async => x * 2;
Stream<int> hostStream(int n) => Stream<int>.fromIterable(List<int>.generate(n, (i) => i));
void hostThrow() => throw HostError('from host');
String hostCatch(void Function() f) {
  try {
    f();
    return 'no error';
  } catch (e) {
    return 'host caught ${e.runtimeType}: $e';
  }
}

List<T> hostWrap<T>(T value) => <T>[value];
String hostTypeOf<T>(T value) => '$T/${value.runtimeType}';
String hostCallGreeter(Greeter g) => g.greet('host');
Future<String> hostAwait(Future<String> f) async => 'host awaited ${await f}';
Future<String> hostListen(Stream<int> s) async => 'host summed ${await s.fold<int>(0, (a, b) => a + b)}';

/// A const object created by AOT code (canonicalised in the host snapshot).
Object hostConstProduct() =>
    const Product(id: 'p1', title: 'Flutter Handbook', pricePaise: 49900, category: Category.books);
