// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// PATCH v1 of feature_catalog: new widget (SaleBadge), changed build method, changed StatefulWidget
// behaviour and tap callback. Business logic and models still come from the host.

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
  String get version => 'catalog v2 (patch 1) / ${_service.version}';

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

/// NEW widget added by the patch.
class SaleBadge extends StatelessWidget {
  const SaleBadge({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        color: const Color(0xFFFFE08A),
        child: Text('NEW: $text'),
      );
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.feature, required this.service});
  final CatalogFeature feature;
  final ProductService service;
  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  String _selected = 'nothing';

  @override
  Widget build(BuildContext context) {
    final items = widget.service.products();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Catalogue (${widget.feature.version})'),
      const SaleBadge(text: 'patched catalogue'),
      for (final p in items)
        GestureDetector(
          key: Key('row-${p.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() {
            AppState.instance.cart.add(p);
            globalCounter++;
            _selected = p.title;
          }),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text('${p.title} | ${widget.feature.priceLabel(p)} | ref ${productRef(p)}'),
          ),
        ),
      Text('selected (patch 1): $_selected, cart: ${AppState.instance.cart.length}, globalCounter: $globalCounter'),
    ]);
  }
}
