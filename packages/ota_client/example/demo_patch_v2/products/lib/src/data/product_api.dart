// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:core/core.dart';
import 'package:http/http.dart' as http;

import 'product_model.dart';

/// Loads the product list from the demo's product API.
class ProductApi {
  ProductApi({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? DemoConfig.productApiBaseUrl;

  /// The endpoint. Demo patch: was `/v1/products.json`.
  static const productsPath = '/v2/products.json';

  final http.Client _client;
  final String _baseUrl;

  Future<List<ProductModel>> fetchProducts() async {
    final response = await _client
        .get(Uri.parse('$_baseUrl$productsPath'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw ProductApiException('HTTP ${response.statusCode} from $productsPath');
    }
    // Typed casts only: patch code must not make dynamic calls.
    final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, Object?>;
    final items = body['products'] as List<Object?>;
    return [
      for (final item in items) ProductModel.fromJson(item as Map<String, Object?>),
    ];
  }
}

class ProductApiException implements Exception {
  ProductApiException(this.message);
  final String message;

  @override
  String toString() => message;
}
