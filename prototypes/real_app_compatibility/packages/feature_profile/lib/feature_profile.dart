// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:app_core/app_core.dart';
import 'package:flutter/widgets.dart';
import 'package:user_service/user_service.dart';

/// Default (AOT) profile feature with simple form validation.
class ProfileFeatureImpl implements ProfileFeature {
  ProfileFeatureImpl([UserService? users]) : _users = users ?? UserService();
  final UserService _users;

  @override
  String get version => 'profile v1';

  @override
  String? validateName(String value) => value.trim().isEmpty ? 'Name is required' : null;

  @override
  Widget buildScreen(BuildContext context) {
    final user = _users.currentUser;
    return Text('Profile ($version): ${user?.name ?? 'guest'} / '
        'validate("")=${validateName('')} validate("ab")=${validateName('ab')}');
  }
}
