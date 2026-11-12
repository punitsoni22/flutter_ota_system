// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:app_models/app_models.dart';
import 'package:collection/collection.dart';
import 'package:patchable_utils/patchable_utils.dart';

/// PATCH v2 of product_service: 20 % festival discount on books.
class ProductService {
  static const List<Product> _catalogue = [
    Product(id: 'p1', title: 'Flutter Handbook', pricePaise: 49900, category: Category.books),
    Product(id: 'p2', title: 'USB-C Cable', pricePaise: 29900, category: Category.electronics),
    Product(id: 'p3', title: 'Green Tea', pricePaise: 19900, category: Category.grocery),
  ];

  String get version => 'product_service v2 (patch 2)';

  List<Product> products() => _catalogue.sortedBy<num>((p) => p.pricePaise).reversed.toList();

  int finalPricePaise(Product p) => applyDiscount(p.pricePaise, p.category == Category.books ? 20 : 0);

  String priceLabel(Product p) => 'Product price: ${formatPrice(finalPricePaise(p))}';

  Map<Category, List<Product>> byCategory() => groupBy(_catalogue, (Product p) => p.category);

  /// New async API (used by the patched screen's FutureBuilder).
  Future<String> stockStatus(Product p) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return p.category == Category.grocery ? 'low stock' : 'in stock';
  }
}
