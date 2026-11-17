// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// A miniature widget system (stand-in for Flutter, which can't be AOT-built here).
// v2 gives widgets new parameters: the "widget copy" tier.

abstract class Widget {
  const Widget();

  String render();
}

class Label extends Widget {
  final String text;
  final bool bold;

  const Label(this.text, {this.bold = false});

  @override
  String render() => bold ? '**$text**' : '[$text]';
}

String screen() => const Label('hi', bold: true).render();

abstract class StatefulWidget extends Widget {
  const StatefulWidget();

  State createState();

  @override
  String render() => createState().build();
}

abstract class State<T extends StatefulWidget> {
  late T widget;

  String build();
}

class Counter extends StatefulWidget {
  final int start;
  final int step;

  const Counter(this.start, {this.step = 1});

  @override
  State<Counter> createState() => _CounterState()..widget = this;
}

class _CounterState extends State<Counter> {
  int _n = 1;

  @override
  String build() => 'count=${widget.start + _n * widget.step}';
}

String counterScreen() => const Counter(3, step: 5).render();
