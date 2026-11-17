// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Test driver: identical in v1 and v2. It plays the role of unchanged app code
// that calls into changed code. Each case returns a value that is printed.

import 'dart:async';

import 'src/additions.dart';
import 'src/async_gen.dart';
import 'src/basics.dart';
import 'src/ext_enum.dart';
import 'src/generics.dart';
import 'src/iso.dart';
import 'src/misc.dart';
import 'src/models.dart';
import 'src/oop.dart';
import 'src/privates.dart';
import 'src/refuse.dart';
import 'src/sigs.dart';
import 'src/sigs_user.dart';
import 'src/ui.dart';

typedef Case = FutureOr<Object?> Function();

final Map<String, Case> cases = {
  // ---- Tier 1: changed bodies
  'c01_top_level_function': () => addTax(100),
  'c02_method_with_fields': () {
    final c = Cart()
      ..add(5)
      ..add(-3)
      ..add(10);
    c.discount = 2;
    return c.total();
  },
  'c03_getter': () => (Cart()
        ..add(1)
        ..add(2)
        ..add(3))
      .count,
  'c04_setter_private_field': () {
    final c = Cart()..add(10);
    c.discount = 80;
    return c.total();
  },
  'c05_static_method': () => Cart.label(3),
  'c06_operator': () => (Cart()..add(4))[0],
  'c07_async': () => Loader().load(1),
  'c08_async_star': () async => (await Loader().ticks(3).toList()).join(','),
  'c09_sync_star': () => Loader().names().join(','),
  'c10_generic_function': () => '${firstOr([1, 2, 3], 0)}/${firstOr(<String>[], 'x')}',
  'c11_generic_class': () {
    final b = Box<int>()
      ..put(1)
      ..put(2)
      ..put(3);
    return '${b.peek()}/${b.mapAll((e) => 'n$e').join(',')}';
  },
  'c12_super_call': () => Square(2).describe(),
  'c13_mixin': () => Person('Ann').greet(),
  'c14_extension': () => '${5.doubled()}/${50.isBig}',
  'c15_enum_getter': () => Level.high.tag,
  'c16_private_method': () => Cart().reveal(),
  'c18_private_toplevel_and_class': () => compute(1),
  'c19_closure': () => scaled([1, 2, 3], 2).join(','),
  'c20_named_optional_params': () => '${fmt('ab', upper: true, pad: 4)}|${opt('a')}',
  'c21_virtual_dispatch': () {
    final Shape s = Circle(1);
    return s.area();
  },
  'c22_const_value_static': () => isFull(4),
  'c22b_const_value_toplevel': () => greeting(),
  'c23_patterns_records': () =>
      '${classify(5)},${classify(20)},${classify('x')},${classify((1, 2))}|${pair(3)}',
  'c24_ui_text': () => title(),
  'c25_exceptions': () => '${parseOr('x')}/${parseOr('12')}',
  'c26_late_field': () => Config().read(),
  'c29_recursion': () => fib(10),
  'c44_private_statics': () {
    Hits.hit();
    Hits.hit();
    return Hits.report();
  },
  'c45_private_enum': () => mode(),
  'c48_private_async_helper': () => Loader().fetch(),
  'c49_interface_dispatch': () {
    final Repo r = MemRepo();
    return r.count();
  },
  // ---- Tier 2: additions
  'c31_new_toplevel_function': () => greetAll(['a', 'b']),
  'c32_new_class': () => badge('x'),
  'c33_34_new_members_on_class': () => '${Cart().summary()}|${(Cart()..add(3)).summary()}',
  'c35_new_static_const': () => isTooSmall(1),
  'c36_new_file': () => latest(),
  // ---- Tier 3w: widget copies
  'c37_widget_new_param': () => screen(),
  'c37b_stateful_widget_new_param': () => counterScreen(),
  // ---- must be refused (patched app keeps v1 behaviour)
  'c38_signature_change': () => tagAll(),
  'c39_default_value_change': () => helloAll(),
  'c40_new_field_non_widget': () {
    final a = Account();
    return '${a.deposit(5)}/${a.deposit(5)}';
  },
  'c41_enum_value_added': () => plans(),
  'c42_class_header_change': () => Dog().bark(),
  'c51_global_initializer': () => fmtNum(3),
  // ---- Shot 1b: structure changes that ship as small patches
  'c52_side_field_ctor_param': () => '${makeProfile().label()}|${const Profile('bob').label()}',
  'c54_repointed_unchanged_caller': () => tagTwice(),
  'c56_instance_field_initializer': () => Settings().r,
  'c57_static_final_initializer': () => tagsText(),
  'c59_field_type_change': () => temp(),
  // ---- known limit: background isolate
  'c43_isolate': () => inIsolate(3),
  'c43b_same_fn_main_isolate': () => heavy(3),
};

Future<List<String>> runAll() async {
  final out = <String>[];
  for (final e in cases.entries) {
    String v;
    try {
      v = '${await e.value()}';
    } catch (err) {
      v = 'ERROR:${err.runtimeType}';
    }
    out.add('${e.key}\t$v');
  }
  return out;
}
