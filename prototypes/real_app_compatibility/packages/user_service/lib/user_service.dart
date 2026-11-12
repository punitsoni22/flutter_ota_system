// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:app_models/app_models.dart';
import 'package:shared_state/shared_state.dart';

/// Authentication mock. The session lives in the HOST's AppState singleton.
class UserService {
  User login(String id, String name) {
    final user = User(id, name);
    AppState.instance.currentUser = user;
    eventBus.emit('login:$id');
    return user;
  }

  void logout() {
    AppState.instance.currentUser = null;
    eventBus.emit('logout');
  }

  User? get currentUser => AppState.instance.currentUser;
}
