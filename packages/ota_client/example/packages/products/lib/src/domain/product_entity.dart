// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// A product as the app uses it, independent of the JSON format.
class ProductEntity {
  const ProductEntity({required this.id, required this.name, required this.price});

  final int id;
  final String name;
  final double price;
}
