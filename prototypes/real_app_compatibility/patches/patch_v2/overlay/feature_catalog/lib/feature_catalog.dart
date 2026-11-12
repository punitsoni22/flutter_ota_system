// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// PATCH v2 of feature_catalog: uses the patched product_service (discount), new navigation to a
// detail route, FutureBuilder/StreamBuilder async UI, an AnimationController with a host mixin.

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:app_models/app_models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:product_service/product_service.dart';
import 'package:shared_state/shared_state.dart';

String productRef(Product p) => sha1.convert(p.id.codeUnits).toString().substring(0, 6);

class CatalogFeatureImpl implements CatalogFeature {
  CatalogFeatureImpl([ProductService? service]) : _service = service ?? ProductService();
  final ProductService _service;

  @override
  String get version => 'catalog v3 (patch 2) / ${_service.version}';

  @override
  String priceLabel(Product product) => _service.priceLabel(product);

  @override
  Widget buildScreen(BuildContext context) => CatalogScreen(feature: this, service: _service);

  @override
  Widget buildRow(BuildContext context, int index) {
    final items = _service.products();
    final p = items[index % items.length];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(children: [
        Expanded(child: Text('#$index ${p.title}')),
        Text(priceLabel(p)),
      ]),
    );
  }
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.feature, required this.service});
  final CatalogFeature feature;
  final ProductService service;
  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _fade =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 400))..forward();
  late final Stream<int> _ticks = Stream<int>.periodic(const Duration(milliseconds: 200), (i) => i + 1).take(5);

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _openDetail(BuildContext context, Product p) {
    AppState.instance.cart.add(p);
    eventBus.emit('patched-catalog:open:${p.id}');
    Navigator.of(context).push(PageRouteBuilder<void>(
      settings: const RouteSettings(name: 'detail (patch 2)'),
      pageBuilder: (c, _, _) => ProductDetail(product: p, service: widget.service),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.service.products();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Catalogue (${widget.feature.version})'),
      FadeTransition(opacity: _fade, child: const Text('Festival sale: 20% off books')),
      StreamBuilder<int>(
        stream: _ticks,
        builder: (_, s) => Text('live ticks: ${s.data ?? 0} (${s.connectionState.name})'),
      ),
      for (final p in items)
        GestureDetector(
          key: Key('row-${p.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _openDetail(context, p),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${p.title} | ${widget.feature.priceLabel(p)} | ref ${productRef(p)}'),
              FutureBuilder<String>(
                future: widget.service.stockStatus(p),
                builder: (_, s) => Text('  ${p.id} stock: ${s.data ?? 'loading'}'),
              ),
            ]),
          ),
        ),
      Text('cart: ${AppState.instance.cart.length}'),
    ]);
  }
}

/// NEW route added by the patch (navigation logic lives in patched code).
class ProductDetail extends StatelessWidget {
  const ProductDetail({super.key, required this.product, required this.service});
  final Product product;
  final ProductService service;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Detail (patch 2): ${product.title}'),
              Text(service.priceLabel(product)),
              Text('was ₹${product.pricePaise ~/ 100}, cart now ${AppState.instance.cart.length}'),
            ]),
          ),
        ),
      );
}
