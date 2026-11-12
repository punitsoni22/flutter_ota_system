// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

// Small, dependency-free helpers to read Dart source files: strip comments, mask string
// contents, read directives and find top-level type declarations.
//
// This is NOT a Dart parser. It is used only for feature discovery (finding the entry class and
// its contract type). Everything it finds is checked again by real compilers: the store build
// (flutter build) and, for a patch, patch_guard (analyzer) and dart2bytecode.

/// One `import`, `export` or `part` directive.
class Directive {
  Directive(this.kind, this.uri, {this.prefix, this.show = const [], this.hide = const []});

  /// `import`, `export`, `part` or `part of`.
  final String kind;
  final String uri;
  final String? prefix;
  final List<String> show;
  final List<String> hide;

  /// Whether [name] passes the `show`/`hide` combinators.
  bool exposes(String name) => (show.isEmpty || show.contains(name)) && !hide.contains(name);

  /// `package:<name>/...` -> `<name>`, otherwise null.
  String? get packageName {
    if (!uri.startsWith('package:')) return null;
    final rest = uri.substring(8);
    final slash = rest.indexOf('/');
    return slash <= 0 ? null : rest.substring(0, slash);
  }

  /// `package:<name>/<path>` -> `<path>` (relative to the package's lib/), otherwise null.
  String? get packagePath {
    final name = packageName;
    return name == null ? null : uri.substring(8 + name.length + 1);
  }
}

/// Removes `//` and (nested) `/* */` comments. String literals are kept unchanged, so directive
/// URIs survive. Newlines inside removed comments are kept, so line numbers stay correct.
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  final n = src.length;
  while (i < n) {
    final c = src[i];
    if (c == '/' && i + 1 < n && src[i + 1] == '/') {
      while (i < n && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < n && src[i + 1] == '*') {
      var depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (src[i] == '/' && i + 1 < n && src[i + 1] == '*') {
          depth++;
          i += 2;
        } else if (src[i] == '*' && i + 1 < n && src[i + 1] == '/') {
          depth--;
          i += 2;
        } else {
          if (src[i] == '\n') out.write('\n');
          i++;
        }
      }
      out.write(' ');
      continue;
    }
    if (c == "'" || c == '"') {
      final end = _stringEnd(src, i);
      out.write(src.substring(i, end));
      i = end;
      continue;
    }
    if (c == 'r' && i + 1 < n && (src[i + 1] == "'" || src[i + 1] == '"') && !_isIdentChar(i > 0 ? src[i - 1] : ' ')) {
      final end = _stringEnd(src, i + 1, raw: true);
      out.write(src.substring(i, end));
      i = end;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// Replaces the contents of every string literal with spaces (quotes are kept). Run on
/// comment-free source. Interpolated code inside strings is masked too, which is fine for
/// finding declarations.
String maskStrings(String src) {
  final out = StringBuffer();
  var i = 0;
  final n = src.length;
  while (i < n) {
    final c = src[i];
    final raw =
        c == 'r' && i + 1 < n && (src[i + 1] == "'" || src[i + 1] == '"') && !_isIdentChar(i > 0 ? src[i - 1] : ' ');
    if (c == "'" || c == '"' || raw) {
      final start = raw ? i + 1 : i;
      final end = _stringEnd(src, start, raw: raw);
      if (raw) out.write('r');
      final q = src[start];
      out.write(q);
      for (var k = start + 1; k < end - 1; k++) {
        out.write(src[k] == '\n' ? '\n' : ' ');
      }
      if (end - 1 > start) out.write(src[end - 1]);
      i = end;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

bool _isIdentChar(String c) => RegExp(r'[A-Za-z0-9_$]').hasMatch(c);

/// Index just after the string literal starting at [start] (which is a quote character).
int _stringEnd(String src, int start, {bool raw = false}) {
  final n = src.length;
  final q = src[start];
  final triple = start + 2 < n && src[start + 1] == q && src[start + 2] == q;
  var i = start + (triple ? 3 : 1);
  while (i < n) {
    final c = src[i];
    if (!raw && c == r'\') {
      i += 2;
      continue;
    }
    if (!raw && c == r'$' && i + 1 < n && src[i + 1] == '{') {
      // Skip the interpolated expression (may contain nested strings and braces).
      var depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        final d = src[i];
        if (d == "'" || d == '"') {
          i = _stringEnd(src, i);
          continue;
        }
        if (d == '{') depth++;
        if (d == '}') depth--;
        i++;
      }
      continue;
    }
    if (triple) {
      if (c == q && i + 2 < n && src[i + 1] == q && src[i + 2] == q) return i + 3;
    } else {
      if (c == q) return i + 1;
      if (c == '\n') return i; // unterminated: stop at the end of the line
    }
    i++;
  }
  return n;
}

final _directiveRe = RegExp(
  r'''(?:^|(?<=[;}]))\s*(import|export|part\s+of|part)\s+(?:r?(['"])(.*?)\2)((?:[^;'"]|'[^']*'|"[^"]*")*);''',
  dotAll: true,
);
final _conditionalUriRe = RegExp(r'''if\s*\([^)]*\)\s*(['"])(.*?)\1''');

/// Reads the directives of a Dart file. Conditional import/export URIs (`if (dart.library.x)
/// 'uri'`) are returned as extra directives of the same kind.
List<Directive> parseDirectives(String source) {
  final src = stripComments(source);
  final out = <Directive>[];
  for (final m in _directiveRe.allMatches(src)) {
    final kind = m.group(1)!.replaceAll(RegExp(r'\s+'), ' ');
    final uri = m.group(3)!;
    final tail = m.group(4) ?? '';
    final tailNoUris = tail.replaceAll(_conditionalUriRe, ' ');
    String? prefix;
    final pm = RegExp(r'\bas\s+([A-Za-z_$][A-Za-z0-9_$]*)').firstMatch(tailNoUris);
    if (pm != null) prefix = pm.group(1);
    List<String> names(String keyword) {
      final km = RegExp('\\b$keyword\\s+([A-Za-z0-9_\$,\\s]+?)(?=\\bshow\\b|\\bhide\\b|\$)').firstMatch(tailNoUris);
      if (km == null) return const [];
      return km.group(1)!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }

    out.add(Directive(kind, uri, prefix: prefix, show: names('show'), hide: names('hide')));
    for (final c in _conditionalUriRe.allMatches(tail)) {
      out.add(Directive(kind, c.group(2)!, prefix: prefix));
    }
    // Directives only appear at the top of a file; a class body ends the directive section.
  }
  return out;
}

/// A top-level type declaration found in a file.
class TypeDeclaration {
  TypeDeclaration({
    required this.name,
    required this.keyword,
    required this.modifiers,
    required this.header,
    required this.body,
  });

  final String name;

  /// `class`, `mixin`, `enum`, `typedef`, `extension type`.
  final String keyword;

  /// Words before the keyword (`abstract`, `base`, `interface`, `final`, `sealed`, `mixin`).
  final List<String> modifiers;

  /// Text between the name and the opening brace (type parameters, extends/with/implements).
  final String header;

  /// Text inside the class braces (comment-free, strings masked). Empty for typedefs.
  final String body;

  bool get isAbstract => modifiers.contains('abstract') || modifiers.contains('sealed') || keyword == 'mixin';

  /// The `extends` type, without type arguments, or null.
  String? get superclass {
    final m = RegExp(r'\bextends\s+([A-Za-z_$][A-Za-z0-9_$.]*)').firstMatch(header);
    return m?.group(1);
  }

  /// The `implements` types, without type arguments.
  List<String> get interfaces => _typeList('implements');

  /// The `with` types, without type arguments.
  List<String> get mixins => _typeList('with');

  List<String> _typeList(String keyword) {
    final m = RegExp('\\b$keyword\\s+(.*?)(?=\\bimplements\\b|\\bwith\\b|\$)', dotAll: true).firstMatch(header);
    if (m == null) return const [];
    return splitTopLevel(
      m.group(1)!,
    ).map((t) => t.replaceAll(RegExp(r'<.*$', dotAll: true), '').trim()).where((t) => t.isNotEmpty).toList();
  }

  /// Unnamed constructors declared in the body (`Name(...)`, `const Name(...)`,
  /// `factory Name(...)`): their parameter lists. Empty when the class declares none.
  List<String> get unnamedConstructorParameters {
    final out = <String>[];
    final re = RegExp('(?:^|[;}\\s])(?:const\\s+|factory\\s+)?${RegExp.escape(name)}\\s*\\(');
    var depth = 0;
    // Only look at class-member level (brace depth 0 inside the body).
    final topLevel = StringBuffer();
    for (var i = 0; i < body.length; i++) {
      final c = body[i];
      if (c == '{') depth++;
      topLevel.write(depth == 0 ? c : ' ');
      if (c == '}') depth--;
    }
    final text = topLevel.toString();
    for (final m in re.allMatches(text)) {
      final open = m.end - 1;
      var d = 0;
      var j = open;
      for (; j < body.length; j++) {
        if (body[j] == '(') d++;
        if (body[j] == ')') {
          d--;
          if (d == 0) break;
        }
      }
      out.add(body.substring(open + 1, j.clamp(open + 1, body.length)));
    }
    return out;
  }
}

/// Splits a comma-separated list at top level (ignores commas inside `<...>` and `(...)`).
List<String> splitTopLevel(String s) {
  final out = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '<' || c == '(') depth++;
    if (c == '>' || c == ')') depth--;
    if (c == ',' && depth == 0) {
      out.add(s.substring(start, i));
      start = i + 1;
    }
  }
  out.add(s.substring(start));
  return out;
}

final _declRe = RegExp(
  r'(?:^|(?<=[;}\n)\]]))\s*((?:(?:abstract|base|interface|final|sealed|mixin)\s+)*)(class|mixin|enum|typedef|extension\s+type)\s+([A-Za-z_$][A-Za-z0-9_$]*)',
);

/// Finds the top-level type declarations of a Dart file.
List<TypeDeclaration> findTypeDeclarations(String source) {
  final src = maskStrings(stripComments(source));
  // Mark brace depth so only top-level declarations are returned.
  final depthAt = List<int>.filled(src.length + 1, 0);
  var depth = 0;
  for (var i = 0; i < src.length; i++) {
    depthAt[i] = depth;
    if (src[i] == '{') depth++;
    if (src[i] == '}') depth--;
  }
  final out = <TypeDeclaration>[];
  for (final m in _declRe.allMatches(src)) {
    if (depthAt[m.end - 1] != 0) continue;
    final keyword = m.group(2)!.replaceAll(RegExp(r'\s+'), ' ');
    final name = m.group(3)!;
    final modifiers = m.group(1)!.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    var header = '';
    var body = '';
    if (keyword == 'typedef') {
      final semi = src.indexOf(';', m.end);
      header = src.substring(m.end, semi < 0 ? src.length : semi);
    } else {
      final open = src.indexOf('{', m.end);
      final semi = src.indexOf(';', m.end);
      if (open < 0 || (semi >= 0 && semi < open)) {
        // `class A = B with C;` (mixin application)
        header = src.substring(m.end, semi < 0 ? src.length : semi);
      } else {
        header = src.substring(m.end, open);
        var d = 0;
        var j = open;
        for (; j < src.length; j++) {
          if (src[j] == '{') d++;
          if (src[j] == '}') {
            d--;
            if (d == 0) break;
          }
        }
        body = src.substring(open + 1, j.clamp(open + 1, src.length));
      }
    }
    out.add(TypeDeclaration(name: name, keyword: keyword, modifiers: modifiers, header: header, body: body));
  }
  return out;
}

/// Whether a parameter list (the text inside the parentheses) has a required parameter.
bool hasRequiredParameter(String params) {
  final t = params.trim();
  if (t.isEmpty) return false;
  final optStart = t.indexOf(RegExp(r'[\[{]'));
  final positional = optStart < 0 ? t : t.substring(0, optStart);
  if (splitTopLevel(positional).any((s) => s.trim().isNotEmpty)) return true;
  if (optStart >= 0 && t[optStart] == '{') {
    return RegExp(r'\brequired\b').hasMatch(t.substring(optStart));
  }
  return false;
}

/// `user_profile` -> `UserProfile`.
String pascalCase(String snake) =>
    snake.split('_').where((s) => s.isNotEmpty).map((s) => s[0].toUpperCase() + s.substring(1)).join();

/// `user_profile` -> `userProfile`.
String camelCase(String snake) {
  final p = pascalCase(snake);
  return p.isEmpty ? p : p[0].toLowerCase() + p.substring(1);
}

/// Dart reserved words that cannot be used as a getter name.
const reservedWords = {
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'Function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'while',
  'with',
  'yield',
};
