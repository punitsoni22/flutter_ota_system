// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';

// pkg_rename:keep
import 'package:app_core/app_core.dart';
// pkg_rename:keep
import 'package:app_models/app_models.dart';
import 'package:app_models/app_models.dart' as copy;
// pkg_rename:keep
import 'package:compat_suites/compat_suites.dart';
// pkg_rename:keep
import 'package:shared_state/shared_state.dart';
import 'package:shared_state/shared_state.dart' as copy_state;
// pkg_rename:keep
import 'package:user_service/user_service.dart';

@pragma('dyn-module:entry-point')
Object? probeEntry() => <String, Object?>{'probe': 'state', 'run': run};

class ModuleGreeter extends Greeter {
  @override
  String greet(String name) => 'module greets $name';
}

class ModuleThing {}

Stream<int> moduleStream() async* {
  yield 1;
  yield 2;
  yield 3;
}

Future<Map<String, Object?>> run() async {
  final r = <String, Object?>{};
  Future<void> check(String name, FutureOr<Object?> Function() f) async {
    try {
      r[name] = await f();
    } catch (e) {
      r[name] = 'THREW ${e.runtimeType}: $e';
    }
  }

  // --- 6.1 shared model objects (host-created User) ---------------------------------------------
  final hostUser = AppState.instance.currentUser!;
  await check('6.1 host user runtimeType', () => '${hostUser.runtimeType}');
  await check('6.1 host user is User (host type)', () => hostUser is User);
  await check('6.1 module-created User has the host runtimeType', () => User('u2', 'B').runtimeType == hostUser.runtimeType);
  await check('6.1 field access', () => '${hostUser.id}/${hostUser.name}');
  await check('6.1 mutation seen by host AOT code (UserService.currentUser)', () {
    hostUser.name = 'Asha K';
    final seen = UserService().currentUser!.name;
    hostUser.name = 'Asha';
    return seen;
  });
  await check('6.1 equality (==, hashCode)', () => hostUser == User('u1', 'Asha') && hostUser.hashCode == User('u1', 'Asha').hashCode);
  await check('6.1 cast Object -> User', () => ((hostUser as Object) as User).id);
  await check('6.1 serialization round trip', () => User.fromJson(jsonDecode(jsonEncode(hostUser)) as Map<String, Object?>) == hostUser);
  await check('6.1 host enum identity', () => identical(Category.books, Category.values.first));
  await check('6.1 const Product canonicalised across boundary', () {
    const mine = Product(id: 'p1', title: 'Flutter Handbook', pricePaise: 49900, category: Category.books);
    final host = hostConstProduct();
    return 'identical=${identical(mine, host)} equal=${mine == host}';
  });
  // A COPY of the model package (what renaming app_models would do).
  await check('6.1 COPY: copied User is host User?', () => (copy.User('u1', 'Asha') as Object) is User);
  await check('6.1 COPY: copied User == host user', () => copy.User('u1', 'Asha') == (hostUser as Object));
  await check('6.1 COPY: cast copied User to host User', () => ((copy.User('u1', 'Asha') as Object) as User).id);
  await check('6.1 COPY: same JSON', () => jsonEncode(copy.User('u1', 'Asha')) == jsonEncode(hostUser));
  await check('6.1 COPY: copied enum == host enum', () => (copy.Category.books as Object) == Category.books);

  // --- 6.2 globals / statics / singletons / lazy ------------------------------------------------
  await check('6.2 singleton identical across boundary', () => identical(AppState.instance, AppState.instance) && AppState.instance.currentUser == hostUser);
  await check('6.2 host token / createdAt (compare with host START log)', () => '${AppState.instance.token} ${AppState.instance.createdAt}');
  await check('6.2 top-level var write visible (host list written by AOT listener)', () async {
    final before = globalLog.length;
    eventBus.emit('from-module');
    await Future<void>.delayed(Duration.zero);
    return 'globalLog grew by ${globalLog.length - before}: ${globalLog.last}';
  });
  await check('6.2 static field', () {
    AppState.staticCounter += 3;
    return AppState.staticCounter;
  });
  await check('6.2 COPY: singleton is a different object', () => identical(copy_state.AppState.instance, AppState.instance as Object));
  await check('6.2 COPY: separate state (currentUser in copy)', () => '${copy_state.AppState.instance.currentUser}');
  await check('6.2 COPY: separate top-level var', () {
    copy_state.globalCounter += 100;
    return 'copy=${copy_state.globalCounter} host=$globalCounter';
  });
  await check('6.2 COPY: different token', () => copy_state.AppState.instance.token == AppState.instance.token);

  // --- 6.3 shared services -------------------------------------------------------------------------
  final locator = ServiceLocator.instance;
  await check('6.3 DI container: same instance, host services visible', () => '${locator.count} ${locator.get<AppConfig>().environment}');
  await check('6.3 logger shared', () {
    final logger = locator.get<Logger>();
    final before = logger.lines.length;
    logger.info('hello from probe_state');
    return logger.lines.length - before;
  });
  await check('6.3 auth service: login from module updates host session + host AOT listener', () async {
    final users = locator.get<UserService>();
    users.login('u7', 'Neha');
    await Future<void>.delayed(Duration.zero);
    final seen = '${AppState.instance.currentUser} / ${globalLog.last}';
    users.login('u1', 'Asha');
    return seen;
  });
  await check('6.3 event bus: module listener receives host event', () async {
    final got = <String>[];
    final sub = eventBus.events.listen(got.add);
    UserService().logout();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    UserService().login('u1', 'Asha');
    return got;
  });
  await check('6.3 COPY: event on the copied bus is NOT seen by host', () async {
    await Future<void>.delayed(const Duration(milliseconds: 50)); // drain earlier host events
    copy_state.eventBus.emit('copy-event');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return 'host entries mentioning copy-event: ${globalLog.where((e) => e.contains('copy-event')).length}';
  });
  await check('6.3 module registers a service the host can resolve', () {
    locator.register<Greeter>(ModuleGreeter());
    return hostCallGreeter(locator.get<Greeter>());
  });

  // --- 6.4 cross-boundary communication ----------------------------------------------------------
  await check('6.4 callback (module closure called by AOT)', () => hostApply((x) => x * 3, 7));
  await check('6.4 Future from host', () => hostFuture(4));
  await check('6.4 Stream from host', () => hostStream(4).toList());
  await check('6.4 host exception caught in module', () {
    try {
      hostThrow();
      return 'no error';
    } on HostError catch (e) {
      return 'caught $e';
    }
  });
  await check('6.4 module exception caught by host', () => hostCatch(() => throw StateError('module error')));
  await check('6.4 generics reified across boundary', () => '${hostWrap<int>(1) is List<int>} ${hostTypeOf<String>('x')} ${hostTypeOf<ModuleThing>(ModuleThing())}');
  await check('6.4 interface implemented in module, called by host', () => hostCallGreeter(ModuleGreeter()));
  await check('6.4 module Future awaited by host', () => hostAwait(Future<String>.value('module future')));
  await check('6.4 module async* stream consumed by host', () => hostListen(moduleStream()));
  return r;
}
