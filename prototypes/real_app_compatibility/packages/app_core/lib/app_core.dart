// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Host-owned contracts. The app reaches every patchable feature through a slot typed by one of
/// these interfaces; a bytecode patch registers replacement implementations. These contracts, and
/// the state they expose, stay in the host: changing them requires a full store release.
library;

import 'dart:typed_data';

import 'package:app_models/app_models.dart';
import 'package:flutter/widgets.dart';

abstract interface class CatalogFeature {
  String get version;
  Widget buildScreen(BuildContext context);
  String priceLabel(Product product);

  /// One row of the long scrolling feed (used by the frame-timing benchmark).
  Widget buildRow(BuildContext context, int index);
}

abstract interface class ProfileFeature {
  String get version;
  Widget buildScreen(BuildContext context);
  String? validateName(String value);
}

/// Wraps a native plugin; patches call the plugin only through this host service.
abstract interface class KeyValueStore {
  Future<void> setString(String key, String value);
  Future<String?> getString(String key);
}

class Logger {
  Logger(this.tag);
  final String tag;
  final List<String> lines = [];
  void info(String message) {
    lines.add(message);
    print('[compat] $tag: $message');
  }
}

/// Minimal dependency-injection container (host-owned singletons).
class ServiceLocator {
  ServiceLocator._();
  static final ServiceLocator instance = ServiceLocator._();
  final Map<Type, Object> _services = {};
  void register<T extends Object>(T service) => _services[T] = service;
  T get<T extends Object>() => _services[T]! as T;
  bool has<T extends Object>() => _services.containsKey(T);
  int get count => _services.length;
}

class AppConfig {
  const AppConfig({required this.environment, required this.apiBase});
  final String environment;
  final String apiBase;
}

/// Named objects that modules publish for other modules (modules cannot import each other).
class PatchRegistry {
  PatchRegistry._();
  static final Map<String, Object> _objects = {};
  static void register(String name, Object value) => _objects[name] = value;
  static Object? lookup(String name) => _objects[name];
  static Iterable<String> get names => _objects.keys;
}

/// Feature slots: default (AOT) implementations, replaceable by a patch at start-up.
class FeatureSlots {
  FeatureSlots._();
  static late CatalogFeature catalog;
  static late ProfileFeature profile;
  static final Map<String, String> sources = {'catalog': 'aot', 'profile': 'aot'};

  /// Asset bytes provided by a patch; served by the host's overlay asset bundle.
  static final Map<String, Uint8List> assetOverrides = {};

  /// Applies the slots a module offers. Values of the wrong type are ignored (and reported).
  static List<String> apply(Map<Object?, Object?> overrides, String source) {
    final applied = <String>[];
    final c = overrides['catalog'];
    if (c is CatalogFeature) {
      catalog = c;
      sources['catalog'] = source;
      applied.add('catalog');
    } else if (c != null) {
      applied.add('catalog:IGNORED(${c.runtimeType} is not CatalogFeature)');
    }
    final p = overrides['profile'];
    if (p is ProfileFeature) {
      profile = p;
      sources['profile'] = source;
      applied.add('profile');
    } else if (p != null) {
      applied.add('profile:IGNORED(${p.runtimeType} is not ProfileFeature)');
    }
    final a = overrides['assets'];
    if (a is Map<String, Uint8List>) {
      assetOverrides.addAll(a);
      applied.add('assets(${a.length})');
    }
    return applied;
  }
}

/// Host navigation, shared with modules (patched features push routes through the host Navigator).
class HostNavigation {
  HostNavigation._();
  static final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
}
