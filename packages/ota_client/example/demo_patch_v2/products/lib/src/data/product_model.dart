// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:freezed_annotation/freezed_annotation.dart';

part 'product_model.freezed.dart';
part 'product_model.g.dart';

/// One product as the API sends it (JSON). Regenerate after a change:
/// `dart run build_runner build --delete-conflicting-outputs`
@freezed
abstract class ProductModel with _$ProductModel {
  const factory ProductModel({
    required int id,
    required String name,
    required double price,
    // Demo patch: new field, sent by /v2/products.json.
    double? rating,
  }) = _ProductModel;

  factory ProductModel.fromJson(Map<String, Object?> json) => _$ProductModelFromJson(json);
}
