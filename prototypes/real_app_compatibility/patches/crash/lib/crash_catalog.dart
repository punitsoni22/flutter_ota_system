// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:app_models/app_models.dart';
import 'package:feature_catalog/feature_catalog.dart';
import 'package:flutter/widgets.dart';

/// Test-only native-style crash: the process kills itself with SIGABRT.
Never abortProcess(String where) {
  print('[compat] TEST_CRASH aborting process ($where)');
  Process.killPid(pid, ProcessSignal.sigabrt);
  // killPid is asynchronous to the signal delivery; never return to normal code.
  sleep(const Duration(seconds: 5));
  exit(134);
}

enum Failure { none, abortAfterFirstFrame, buildThrows }

/// Host catalogue with one failure injected into priceLabel (called while building the home screen).
class CrashCatalog implements CatalogFeature {
  CrashCatalog(this.failure);
  final Failure failure;
  final CatalogFeature _host = CatalogFeatureImpl();
  bool _armed = false;

  @override
  String get version => 'crash-test ${failure.name}';

  @override
  String priceLabel(Product product) {
    switch (failure) {
      case Failure.none:
        break;
      case Failure.abortAfterFirstFrame:
        if (!_armed) {
          _armed = true;
          // First frame renders normally; the process dies ~1 s later, before confirmation (3 s).
          Timer(const Duration(milliseconds: 1000), () => abortProcess('after first frame'));
        }
      case Failure.buildThrows:
        throw StateError('crash-test: exception thrown inside build()');
    }
    return 'crash-test: ${_host.priceLabel(product)}';
  }

  @override
  Widget buildScreen(BuildContext context) => _host.buildScreen(context);

  @override
  Widget buildRow(BuildContext context, int index) => _host.buildRow(context, index);
}
