// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

class User {
  User(this.id, this.name);

  factory User.fromJson(Map<String, Object?> json) => User(json['id']! as String, json['name']! as String);

  final String id;
  String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  @override
  bool operator ==(Object other) => other is User && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'User($id, $name)';
}
