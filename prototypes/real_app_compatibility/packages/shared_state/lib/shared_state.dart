// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Shared, host-owned application state: a singleton, statics, a top-level variable, a lazy field
/// and an event bus. Patches must use THESE instances (by importing this host package), or they
/// would create duplicates.
library;

import 'dart:async';

import 'package:app_models/app_models.dart';

/// Top-level mutable variable.
int globalCounter = 0;

/// Lazily initialised top-level value.
final List<String> globalLog = <String>[];

class AppState {
  AppState._();

  static final AppState instance = AppState._();
  static int staticCounter = 0;

  User? currentUser;
  final List<Product> cart = <Product>[];
  late final DateTime createdAt = DateTime.now();

  /// Identity token used by tests to prove which instance is in use.
  final int token = DateTime.now().microsecondsSinceEpoch;
}

class EventBus {
  final StreamController<String> _controller = StreamController<String>.broadcast();
  Stream<String> get events => _controller.stream;
  void emit(String event) => _controller.add(event);
}

final EventBus eventBus = EventBus();
