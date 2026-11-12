// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// The value a patch module's entry point returns (runtime contract, section 4, contract 3):
//
//   @pragma('dyn-module:entry-point')
//   Object? otaPatchEntry() => <String, Object?>{
//     'contract': 3,
//     'features': <String, Object? Function()>{'products': () => ProductsFeature()},
//     'assets': <String, Uint8List>{}, // optional
//   };

import 'dart:typed_data';

/// Loads Dart bytecode and returns the result of the module's entry point.
///
/// The Dart VM allows `dart:_internal` (where `loadDynamicModule` lives) only in packages named
/// `dynamic_modules` or `dart_internal`, so this SDK cannot call the loader itself. The app passes
/// `loadModuleFromBytes` from the toolchain's `dynamic_modules` package (normally through code
/// that the flutter_ota CLI generates). For the separate verifier process it must be a top-level
/// or static function annotated `@pragma('vm:entry-point')`.
typedef FlutterOtaModuleLoader = Future<Object?> Function(Uint8List moduleBytes);

/// A parsed contract-3 entry result.
class ModuleEntry {
  ModuleEntry(this.features, this.assets);

  /// Feature name -> factory.
  final Map<String, Object? Function()> features;
  final Map<String, Uint8List> assets;
}

final _featureName = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

/// Checks the shape of an entry-point result. Throws [FormatException] with a short reason.
ModuleEntry parseModuleEntry(Object? result, {int contract = 3}) {
  if (result is! Map) throw FormatException('entry point returned ${result.runtimeType}, not a map');
  for (final k in result.keys) {
    if (k != 'contract' && k != 'features' && k != 'assets') throw FormatException('unknown entry key "$k"');
  }
  if (result['contract'] != contract) {
    throw FormatException('entry contract ${result['contract']} is not $contract');
  }
  final features = result['features'];
  if (features is! Map || features.length > 256) throw const FormatException('"features" must be a map');
  final out = <String, Object? Function()>{};
  for (final e in features.entries) {
    final name = e.key;
    final factory = e.value;
    if (name is! String || !_featureName.hasMatch(name)) throw FormatException('invalid feature name "$name"');
    if (factory is! Object? Function()) throw FormatException('feature "$name" is not a factory function');
    out[name] = factory;
  }
  final assets = result['assets'] ?? const <String, Uint8List>{};
  if (assets is! Map) throw const FormatException('"assets" must be a map');
  final outAssets = <String, Uint8List>{};
  for (final e in assets.entries) {
    if (e.key is! String || e.value is! Uint8List) throw const FormatException('"assets" must map strings to bytes');
    outAssets[e.key as String] = e.value as Uint8List;
  }
  return ModuleEntry(out, outAssets);
}

/// The features of the loaded patch, as used by `FlutterOta.feature<T>()`.
class FeatureRegistry {
  FeatureRegistry(this._log);

  final void Function(String) _log;
  Map<String, Object? Function()> _features = const {};
  final Set<String> _reported = {};

  /// True once a patched implementation was handed to the app in this session.
  bool patchedFeatureUsed = false;

  /// True after a live fallback: every feature returns its store (AOT) implementation.
  bool get disabled => _disabled;
  bool _disabled = false;

  /// Called when a patch factory throws.
  void Function(String feature, Object error)? onFactoryError;

  void install(ModuleEntry entry) {
    _features = Map.unmodifiable(entry.features);
    _disabled = false;
  }

  /// Names provided by the patch.
  Set<String> get names => _features.keys.toSet();

  /// Every later call returns the store implementation (live fallback).
  void disable() => _disabled = true;

  /// The patch's `name` feature if it exists and is a [T], else `aotFactory()`. Never throws for
  /// patch problems (a throwing [aotFactory] throws as it would without OTA).
  T resolve<T extends Object>(String name, T Function() aotFactory) {
    final factory = _disabled ? null : _features[name];
    if (factory != null) {
      Object? value;
      var threw = false;
      try {
        value = factory();
      } catch (e) {
        threw = true;
        _logOnce('$name:throw', 'FEATURE_FAILED $name: the patch factory threw ${e.runtimeType}; store code used');
        onFactoryError?.call(name, e);
      }
      if (!threw) {
        if (value is T) {
          patchedFeatureUsed = true;
          return value;
        }
        _logOnce(
          '$name:type',
          'FEATURE_WRONG_TYPE $name: the patch returned ${value.runtimeType}, not the host-owned type $T; '
              'store code used',
        );
      }
    }
    return aotFactory();
  }

  void _logOnce(String key, String message) {
    if (_reported.add(key)) _log(message);
  }
}
