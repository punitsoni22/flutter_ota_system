// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// A text replacement in one source file. Insertions have offset == end.
class Edit {
  Edit(this.offset, this.end, this.text, {this.exclusive = false});

  final int offset;
  final int end;
  final String text;

  /// An exclusive edit replaces a whole node; edits inside its range are dropped.
  final bool exclusive;
}

/// Applies [edits] to [src]. Edits inside an exclusive edit are ignored. Several insertions at
/// the same offset keep the order in which they were added.
String applyEdits(String src, List<Edit> edits) {
  final kept = <Edit>[];
  for (final e in edits) {
    final covered = edits.any((x) =>
        x.exclusive &&
        !identical(x, e) &&
        x.offset <= e.offset &&
        e.end <= x.end &&
        (x.end - x.offset) > (e.end - e.offset));
    if (!covered) kept.add(e);
  }
  final indexed = [for (var i = 0; i < kept.length; i++) (i, kept[i])];
  indexed.sort((a, b) {
    final c = b.$2.offset.compareTo(a.$2.offset);
    return c != 0 ? c : b.$1.compareTo(a.$1);
  });
  var out = src;
  for (final (_, e) in indexed) {
    out = out.replaceRange(e.offset, e.end, e.text);
  }
  return out;
}
