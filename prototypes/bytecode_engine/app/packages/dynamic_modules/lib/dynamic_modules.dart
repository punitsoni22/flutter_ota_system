// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Only a package named "dynamic_modules" (or "dart_internal") may import dart:_internal; see
// `allowPlatformPrivateLibraryAccess` in the Dart SDK's pkg/kernel/lib/target/targets.dart.
// The loader exists only in Dart VMs built with `dart_dynamic_modules = true`; elsewhere it throws
// UnsupportedError("Loading of dynamic modules is not supported.").

// The analyzer flags every dart:_internal import; the compiler allows it for this package name.
// ignore: import_internal_library
import 'dart:_internal' as internal;
import 'dart:typed_data';

/// Loads a bytecode module and returns the result of its entry point, a no-argument function
/// annotated with `@pragma('dyn-module:entry-point')`.
Future<Object?> loadModuleFromBytes(Uint8List bytes) => internal.loadDynamicModule(bytes: bytes);
