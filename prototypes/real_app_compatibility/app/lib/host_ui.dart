// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:app_core/app_core.dart';
import 'package:app_models/app_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_state/shared_state.dart';

const _ink = Color(0xFF111111);
const _featured = Product(id: 'p1', title: 'Flutter Handbook', pricePaise: 49900, category: Category.books);

/// Host-owned asset bundle: assets a patch provides win; everything else comes from the APK.
/// Every widget that resolves assets through DefaultAssetBundle (Image.asset included) sees it.
class OverlayAssetBundle extends CachingAssetBundle {
  OverlayAssetBundle(this.base);
  final AssetBundle base;

  @override
  Future<ByteData> load(String key) async {
    final o = FeatureSlots.assetOverrides[key];
    return o != null ? ByteData.sublistView(o) : base.load(key);
  }

  @override
  Future<ui.ImmutableBuffer> loadBuffer(String key) async {
    final o = FeatureSlots.assetOverrides[key];
    return o != null ? ui.ImmutableBuffer.fromUint8List(o) : base.loadBuffer(key);
  }
}

class HostApp extends StatelessWidget {
  const HostApp({super.key, required this.slotsChanged});
  final ValueNotifier<int> slotsChanged;

  @override
  Widget build(BuildContext context) => WidgetsApp(
        navigatorKey: HostNavigation.key,
        color: const Color(0xFF1E5AC8),
        textStyle: const TextStyle(fontSize: 16, color: _ink),
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(settings: settings, pageBuilder: (c, _, _) => builder(c)),
        builder: (context, child) => DefaultAssetBundle(bundle: OverlayAssetBundle(rootBundle), child: child!),
        home: ValueListenableBuilder<int>(valueListenable: slotsChanged, builder: (_, _, _) => const HomeScreen()),
      );
}

Widget page(String title, Widget body) => ColoredBox(
      color: const Color(0xFFFFFFFF),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 22, color: _ink)),
            const SizedBox(height: 12),
            Expanded(child: body),
          ]),
        ),
      ),
    );

void openRoute(String name) {
  final builder = switch (name) {
    'catalog' => (BuildContext c) => page('Catalogue', SingleChildScrollView(child: FeatureSlots.catalog.buildScreen(c))),
    'profile' => (BuildContext c) => page('Profile', FeatureSlots.profile.buildScreen(c)),
    'feed' => (BuildContext c) => page('Feed', ListView.builder(itemCount: 100000, itemBuilder: FeatureSlots.catalog.buildRow)),
    _ => throw ArgumentError(name),
  };
  HostNavigation.key.currentState!.push(PageRouteBuilder<void>(
    settings: RouteSettings(name: name),
    pageBuilder: (c, _, _) => builder(c),
  ));
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => page('Home', ListView(children: [
        const AssetJsonText(asset: 'assets/strings_en.json', field: 'welcome'),
        const AssetJsonText(asset: 'assets/config.json', field: 'title'),
        const AssetImageInfo(asset: 'assets/logo.png'),
        Text('User: ${AppState.instance.currentUser?.name ?? 'guest'}'),
        // Built by the catalogue slot during the FIRST frame (crash-test variants hook in here).
        Text('Featured: ${FeatureSlots.catalog.priceLabel(_featured)}'),
        Text('catalog slot: ${FeatureSlots.sources['catalog']} (${FeatureSlots.catalog.version})'),
        Text('profile slot: ${FeatureSlots.sources['profile']} (${FeatureSlots.profile.version})'),
        const SizedBox(height: 12),
        for (final r in ['catalog', 'profile', 'feed'])
          GestureDetector(
            key: Key('nav-$r'),
            behavior: HitTestBehavior.opaque,
            onTap: () => openRoute(r),
            child: Padding(padding: const EdgeInsets.all(10), child: Text('Open $r >')),
          ),
      ]));
}

/// Unpatched (AOT) widget that reads a JSON asset through DefaultAssetBundle.
class AssetJsonText extends StatelessWidget {
  const AssetJsonText({super.key, required this.asset, required this.field});
  final String asset;
  final String field;

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: DefaultAssetBundle.of(context).loadString(asset, cache: false),
        builder: (_, s) => Text(s.hasData ? '${(jsonDecode(s.data!) as Map)[field]}' : '...'),
      );
}

/// Unpatched (AOT) widget that shows an image asset and its decoded size.
class AssetImageInfo extends StatelessWidget {
  const AssetImageInfo({super.key, required this.asset});
  final String asset;

  Future<String> _size(AssetBundle bundle) async {
    final data = await bundle.load(asset);
    final codec = await ui.instantiateImageCodec(Uint8List.sublistView(data));
    final frame = await codec.getNextFrame();
    return 'logo ${frame.image.width}x${frame.image.height}';
  }

  @override
  Widget build(BuildContext context) => Row(children: [
        Image.asset(asset, width: 24, height: 24, gaplessPlayback: true),
        const SizedBox(width: 8),
        FutureBuilder<String>(
          future: _size(DefaultAssetBundle.of(context)),
          builder: (_, s) => Text(s.data ?? '...'),
        ),
      ]);
}
