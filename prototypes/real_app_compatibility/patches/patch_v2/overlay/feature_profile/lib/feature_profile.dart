// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:app_core/app_core.dart';
import 'package:flutter/widgets.dart';
import 'package:user_service/user_service.dart';

/// PATCH v2 of feature_profile: stricter form validation.
class ProfileFeatureImpl implements ProfileFeature {
  ProfileFeatureImpl([UserService? users]) : _users = users ?? UserService();
  final UserService _users;

  @override
  String get version => 'profile v2 (patch 2)';

  @override
  String? validateName(String value) {
    final v = value.trim();
    if (v.isEmpty) return 'Name is required';
    if (v.length < 3) return 'Name must have at least 3 characters';
    if (v.contains(RegExp(r'[0-9]'))) return 'Name must not contain digits';
    return null;
  }

  @override
  Widget buildScreen(BuildContext context) {
    final user = _users.currentUser;
    return Text('Profile ($version): ${user?.name ?? 'guest'} / '
        'validate("")=${validateName('')} validate("ab")=${validateName('ab')} validate("Asha")=${validateName('Asha')}');
  }
}
