// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Shot 1b: classes whose structure changes in v2.

class Profile {
  final String name;

  const Profile(this.name);

  String label() => 'P:$name';
}

Profile makeProfile() => const Profile('ann');

class Settings {
  int retries = 3;

  int get r => retries;
}

class Defaults {
  static final List<String> tags = ['a'];
}

String tagsText() => Defaults.tags.join(',');

class Temp {
  int value = 1;

  String show() => 'T$value';
}

String temp() => Temp().show();
