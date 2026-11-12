// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

part 'model.g.dart';

class Product {
  Product(this.name);
  final String name;
  Map<String, Object?> toJson() => _$ProductToJson(this);
}
