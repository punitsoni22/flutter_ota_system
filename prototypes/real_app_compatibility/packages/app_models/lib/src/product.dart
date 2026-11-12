// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

enum Category { books, electronics, grocery }

/// Price in paise (1/100 rupee).
class Product {
  const Product({required this.id, required this.title, required this.pricePaise, required this.category});

  final String id;
  final String title;
  final int pricePaise;
  final Category category;

  @override
  String toString() => 'Product($id, $title, $pricePaise)';
}

/// Sealed hierarchy used by checkout logic.
sealed class PaymentState {
  const PaymentState();
}

class PaymentPending extends PaymentState {
  const PaymentPending();
}

class PaymentDone extends PaymentState {
  const PaymentDone(this.reference);
  final String reference;
}
