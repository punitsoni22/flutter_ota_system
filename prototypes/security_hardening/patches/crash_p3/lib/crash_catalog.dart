// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:app_models/app_models.dart';
import 'package:feature_catalog/feature_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_state/shared_state.dart';

/// Test-only native-style crash: the process kills itself with SIGABRT.
Never abortProcess(String where) {
  print('[compat] TEST_CRASH aborting process ($where)');
  Process.killPid(pid, ProcessSignal.sigabrt);
  sleep(const Duration(seconds: 5));
  exit(134);
}

enum Failure { none, abortInEntry, abortWhenLoggedIn, abortAfterFirstFrame, throwWhenLoggedIn }

/// Host catalogue with one injected failure. The "WhenLoggedIn" failures depend on app state
/// (a signed-in user) that the isolated verifier does not have, like real environment-dependent
/// bugs: they pass verification and must be handled by the crash guard.
class CrashCatalog implements CatalogFeature {
  CrashCatalog(this.failure);
  final Failure failure;
  final CatalogFeature _host = CatalogFeatureImpl();
  bool _armed = false;

  @override
  String get version => 'crash-test ${failure.name}';

  @override
  String priceLabel(Product product) {
    final loggedIn = AppState.instance.currentUser != null;
    switch (failure) {
      case Failure.abortWhenLoggedIn when loggedIn:
        abortProcess('before first frame (user signed in)');
      case Failure.throwWhenLoggedIn when loggedIn:
        throw StateError('crash-test: exception in build() (user signed in)');
      case Failure.abortAfterFirstFrame when !_armed:
        _armed = true;
        Timer(const Duration(milliseconds: 1000), () => abortProcess('after first frame'));
      default:
        break;
    }
    return 'crash-test: ${_host.priceLabel(product)}';
  }

  @override
  Widget buildScreen(BuildContext context) => _host.buildScreen(context);

  @override
  Widget buildRow(BuildContext context, int index) => _host.buildRow(context, index);
}
