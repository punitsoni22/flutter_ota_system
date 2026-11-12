// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';

import '../domain/product_entity.dart';
import '../domain/product_repository.dart';

/// Screen state: loading, an error, or the list of products.
class ProductController extends ChangeNotifier {
  ProductController(this._repository);

  final ProductRepository _repository;
  bool _disposed = false;

  bool loading = false;
  String? error;
  List<ProductEntity> products = const [];

  Future<void> load() async {
    loading = true;
    error = null;
    _notify();
    try {
      products = await _repository.getProducts();
    } catch (e) {
      error = 'Could not load products: $e';
    }
    loading = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
