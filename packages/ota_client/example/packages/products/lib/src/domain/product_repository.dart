// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import '../data/product_api.dart';
import 'product_entity.dart';

/// Turns API models into entities for the screen.
class ProductRepository {
  ProductRepository(this._api);

  final ProductApi _api;

  Future<List<ProductEntity>> getProducts() async {
    final models = await _api.fetchProducts();
    return [
      for (final m in models) ProductEntity(id: m.id, name: m.name, price: m.price),
    ];
  }
}
