// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Shot 1b: classes whose structure changes in v2.

class Profile {
  final String name;

  // NEW field with a constructor parameter (side field + constructor helper).
  final String? avatar;

  const Profile(this.name, {this.avatar});

  String label() => 'P:$name/${avatar ?? 'none'}';
}

Profile makeProfile() => const Profile('ann', avatar: 'a.png');

class Settings {
  // Initializer changed (instance field initializer slot).
  int retries = 5;

  int get r => retries;
}

class Defaults {
  // Initializer changed (static field initializer slot).
  static final List<String> tags = ['a', 'b'];
}

String tagsText() => Defaults.tags.join(',');

class Temp {
  // Field TYPE changed: structure change (Level 3 class copy).
  double value = 1.5;

  String show() => 'T$value';
}

String temp() => Temp().show();
