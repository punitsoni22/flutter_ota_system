// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Deprecated from Flutter 3.47 (replacement: package:material_ui), still the standard library.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/product_api.dart';
import '../domain/product_entity.dart';
import '../domain/product_repository.dart';
import 'product_controller.dart';

/// The products list. Demo patch: every row now shows the rating.
class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key});

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  final _controller = ProductController(ProductRepository(ProductApi()));

  @override
  void initState() {
    super.initState();
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final error = _controller.error;
        return RefreshIndicator(
          onRefresh: _controller.load,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Products (v2, with rating)', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              if (_controller.loading) const LinearProgressIndicator(),
              if (error != null) Text(error, style: const TextStyle(color: Colors.red)),
              for (final product in _controller.products) _ProductTile(product: product),
            ],
          ),
        );
      },
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product});

  final ProductEntity product;

  @override
  Widget build(BuildContext context) {
    final rating = product.rating;
    return Card(
      child: ListTile(
        title: Text(product.name),
        subtitle: Text('Price: ${product.price.toStringAsFixed(2)}'),
        // Demo patch: new UI for the new field.
        trailing: rating == null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.star, color: Colors.amber),
                  Text(rating.toStringAsFixed(1)),
                ],
              ),
      ),
    );
  }
}
