// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Dart language feature suite. Every feature returns a deterministic string; the probe compares
// the interpreted result with the AOT result of the same source.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:app_models/app_models.dart';

part 'lang_part.dart';

// --- object-oriented ---------------------------------------------------------------------------
abstract class Shape {
  double area();
  String describe() => '$runtimeType:${area().toStringAsFixed(1)}';
}

class Rect extends Shape {
  Rect(this.w, this.h);
  Rect.square(double s) : this(s, s); // redirecting generative constructor
  final double w, h;
  @override
  double area() => w * h;
}

class Circle extends Shape {
  Circle(this.r);
  final double r;
  @override
  double area() => 3.14159 * r * r;
}

abstract interface class Named {
  String get name;
}

mixin Loud on Shape {
  String shout() => describe().toUpperCase();
}

class LoudRect extends Rect with Loud implements Named {
  LoudRect(super.w, super.h);
  @override
  String get name => 'loud';
}

extension on int {
  int get doubled => this * 2;
}

extension StringX on String {
  String get reversed => split('').reversed.join();
}

class Box<T extends Comparable<Object?>> {
  Box(this.items);
  final List<T> items;
  T get max => items.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
}

enum Level {
  low(1),
  high(10);

  const Level(this.weight);
  final int weight;
  bool get isHigh => this == high;
}

sealed class Result {}

class Ok extends Result {
  Ok(this.value);
  final int value;
}

class Err extends Result {
  Err(this.message);
  final String message;
}

String describeResult(Result r) => switch (r) {
      Ok(value: final v) when v > 10 => 'big ok $v',
      Ok(:final value) => 'ok $value',
      Err(:final message) => 'err $message',
    };

// --- constructors ------------------------------------------------------------------------------
class Money {
  const Money(this.paise);
  const Money.zero() : paise = 0;
  factory Money.parse(String s) => _cache.putIfAbsent(s, () => Money(int.parse(s)));
  factory Money.redirect(int p) = Money;
  static final Map<String, Money> _cache = {};
  final int paise;
  Money operator +(Money o) => Money(paise + o.paise);
  @override
  bool operator ==(Object o) => o is Money && o.paise == paise;
  @override
  int get hashCode => paise.hashCode;
  @override
  String toString() => 'Money($paise)';
}

abstract class Animal {
  factory Animal(String kind) => kind == 'dog' ? Dog() : Cat(); // factory returning subtypes
  String sound();
}

class Dog implements Animal {
  @override
  String sound() => 'woof';
}

class Cat implements Animal {
  @override
  String sound() => 'meow';
}

// --- functions and state -----------------------------------------------------------------------
int topLevel(int x) => x + 1;

class Counter {
  static int created = 0;
  static int next() => ++created;
  int value = 0;
  void inc() => value++;
}

int lazyInits = 0;
late final String lazyValue = () {
  lazyInits++;
  return 'computed';
}();

class Lazy {
  late final int expensive = _compute();
  int computed = 0;
  int _compute() => ++computed * 100;
}

// --- async ---------------------------------------------------------------------------------------
Future<int> asyncAdd(int a, int b) async {
  await Future<void>.delayed(Duration.zero);
  return a + b;
}

Stream<int> countTo(int n) async* {
  for (var i = 1; i <= n; i++) {
    yield i;
  }
}

Iterable<int> evens(int n) sync* {
  for (var i = 0; i < n; i += 2) {
    yield i;
  }
}

class MyError implements Exception {
  MyError(this.code);
  final int code;
  @override
  String toString() => 'MyError($code)';
}

Future<void> failLater() async {
  await Future<void>.delayed(Duration.zero);
  throw MyError(7);
}

@pragma('vm:never-inline')
class Annotated {
  @Deprecated('test')
  int old() => 1;
}

extension type const UserId(String value) {
  bool get isValid => value.startsWith('u');
}

/// name -> test. Async tests return a Future<String>.
Map<String, FutureOr<String> Function()> languageFeatures() => {
      'class + inheritance': () => [Rect(2, 3), Circle(1)].map((s) => s.describe()).join(','),
      'abstract class': () => (Rect(1, 1) as Shape).area().toString(),
      'interface (implements)': () => (LoudRect(1, 2) as Named).name,
      'mixin': () => LoudRect(2, 2).shout(),
      'extension method (unnamed)': () => 21.doubled.toString(),
      'extension method (named)': () => 'abc'.reversed,
      'generics (bounded)': () => '${Box<int>([3, 9, 4]).max} ${Box<String>(['b', 'z', 'a']).max}',
      'generics (reified)': () => '${<int>[1] is List<num>} ${<num>[1] is List<int>} ${Box<int>([1]).runtimeType}',
      'enhanced enum': () => Level.values.map((l) => '${l.name}:${l.weight}:${l.isHigh}').join(','),
      'sealed class + switch patterns': () => [Ok(3), Ok(30), Err('x')].map(describeResult).join(','),
      'records': () {
        (int, {String label}) pair = (5, label: 'five');
        final (a, b) = (1, 2);
        return '${pair.$1} ${pair.label} ${a + b} ${(1, 'x') == (1, 'x')}';
      },
      'destructuring (map/list patterns)': () {
        final {'id': id as String, 'n': [first, ...]} = <String, dynamic>{'id': 'p1', 'n': [7, 8]};
        return '$id $first';
      },
      'default constructor': () => Rect(1, 2).area().toString(),
      'named constructor': () => Rect.square(3).area().toString(),
      'const constructor + canonicalisation': () =>
          '${identical(const Money(5), const Money(5))} ${const Money.zero()}',
      'factory constructor (cache)': () => '${identical(Money.parse('10'), Money.parse('10'))} ${Money.parse('10')}',
      'factory constructor (subtype)': () => '${Animal('dog').sound()} ${Animal('cat').sound()}',
      'redirecting factory': () => Money.redirect(4).toString(),
      'operator overloading': () => (const Money(2) + const Money(3)).toString(),
      'top-level function': () => topLevel(41).toString(),
      'static method + static field': () {
        final before = Counter.created;
        Counter.next();
        Counter.next();
        return (Counter.created - before).toString();
      },
      'instance method': () => (Counter()..inc()..inc()).value.toString(),
      'closures (captured state)': () {
        var n = 0;
        final add = () => ++n;
        add();
        add();
        return n.toString();
      },
      'higher-order functions': () => [1, 2, 3, 4].where((x) => x.isEven).map((x) => x * 10).fold(0, (a, b) => a + b).toString(),
      'tear-offs + generic function': () {
        T id<T>(T x) => x;
        final f = id<int>;
        return '${f(3)} ${[1, 2].map(topLevel).toList()}';
      },
      'late top-level (lazy)': () {
        final a = lazyValue;
        final b = lazyValue;
        return '$a $b inits=$lazyInits';
      },
      'late final field (lazy)': () {
        final l = Lazy();
        return '${l.expensive} ${l.expensive} computed=${l.computed}';
      },
      'sync* generator': () => evens(7).join(','),
      'Future + async/await': () async => (await asyncAdd(2, 3)).toString(),
      'Future.wait': () async => (await Future.wait([asyncAdd(1, 1), asyncAdd(2, 2)])).toString(),
      'async* stream': () async => (await countTo(4).toList()).toString(),
      'StreamController (broadcast)': () async {
        final c = StreamController<String>.broadcast();
        final got = <String>[];
        final sub = c.stream.listen(got.add);
        c..add('a')..add('b');
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        await c.close();
        return got.join();
      },
      'error propagation (async)': () async {
        try {
          await failLater();
          return 'no error';
        } on MyError catch (e) {
          return 'caught $e';
        }
      },
      'try/finally + rethrow': () {
        final log = <String>[];
        try {
          try {
            throw StateError('x');
          } finally {
            log.add('finally');
          }
        } on StateError catch (e) {
          log.add(e.message);
        }
        return log.join(',');
      },
      'Timer': () async {
        final c = Completer<String>();
        Timer(const Duration(milliseconds: 20), () => c.complete('fired'));
        return c.future;
      },
      'Timer.periodic': () async {
        var n = 0;
        final c = Completer<String>();
        Timer.periodic(const Duration(milliseconds: 5), (t) {
          if (++n == 3) {
            t.cancel();
            c.complete('ticks=$n');
          }
        });
        return c.future;
      },
      'microtask ordering': () async {
        final order = <int>[];
        scheduleMicrotask(() => order.add(2));
        Future<void>(() => order.add(3));
        order.add(1);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return order.join();
      },
      'zones': () => runZoned(() => Zone.current[#k] as String, zoneValues: {#k: 'zoned'}),
      'part file': () => partFunction(),
      'annotations (metadata)': () => Annotated().old().toString(),
      'extension type': () => '${const UserId('u1').isValid} ${const UserId('x').isValid}',
      'JSON serialization (toJson/fromJson)': () {
        final u = User.fromJson(jsonDecode(jsonEncode(User('u9', 'Ravi'))) as Map<String, Object?>);
        return '${u.id} ${u.name} ${u == User('u9', 'Ravi')}';
      },
      'host model enum + sealed (app_models)': () {
        final PaymentState s = PaymentDone('r1');
        return '${Category.books.name} ${switch (s) { PaymentPending() => 'pending', PaymentDone(:final reference) => 'done $reference' }}';
      },
      'runtimeType / toString (no mirrors)': () => '${Rect(1, 1).runtimeType} ${const Money(1).runtimeType}',
      'Function.apply': () => Function.apply(topLevel, [1]).toString(),
      'string interpolation + unicode': () => '₹${499} ${'नमस्ते'.length} ${'😀'.runes.length}',
      'int/double arithmetic': () => '${1 << 40} ${7 ~/ 2} ${-7 % 3} ${0.1 + 0.2} ${double.nan.isNaN}',
      'BigInt': () => (BigInt.two.pow(100)).toString(),
      'Isolate.run (closure)': () async => (await Isolate.run(() => 6 * 7)).toString(),
    };

Future<Map<String, String>> runLanguageSuite() async {
  final out = <String, String>{};
  for (final MapEntry(:key, :value) in languageFeatures().entries) {
    try {
      out[key] = await Future.sync(value).timeout(const Duration(seconds: 5));
    } catch (e) {
      out[key] = 'ERROR ${e.runtimeType}: $e';
    }
  }
  return out;
}
