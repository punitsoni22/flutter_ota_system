// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:app_core/app_core.dart';
import 'package:app_models/app_models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:product_service/product_service.dart';
import 'package:shared_state/shared_state.dart';

/// Short reference code shown under each product (uses the third-party pure-Dart package crypto).
String productRef(Product p) => sha1.convert(p.id.codeUnits).toString().substring(0, 6);

/// Default (AOT) catalogue feature.
class CatalogFeatureImpl implements CatalogFeature {
  CatalogFeatureImpl([ProductService? service]) : _service = service ?? ProductService();
  final ProductService _service;

  @override
  String get version => 'catalog (patch 4, crypto 3.0.8 copy) / ${_service.version}';

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

class _CatalogScreenState extends State<CatalogScreen> {
  int _added = 0;

  @override
  Widget build(BuildContext context) {
    final items = widget.service.products();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Catalogue (${widget.feature.version})'),
      for (final p in items)
        GestureDetector(
          key: Key('row-${p.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() {
            AppState.instance.cart.add(p);
            _added++;
          }),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text('${p.title} | ${widget.feature.priceLabel(p)} | ref ${productRef(p)}'),
          ),
        ),
      Text('added here: $_added, cart: ${AppState.instance.cart.length}'),
    ]);
  }
}
