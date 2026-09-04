import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WikiApp());
}

class WikiApp extends StatefulWidget {
  const WikiApp({super.key});

  @override
  State<WikiApp> createState() => _WikiAppState();
}

class _WikiAppState extends State<WikiApp> with WidgetsBindingObserver {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    if (_themeMode == ThemeMode.system) {
      setState(() {});
    }
  }

  void cycleTheme() {
    setState(() {
      if (_themeMode == ThemeMode.system) {
        _themeMode = ThemeMode.dark;
      } else if (_themeMode == ThemeMode.dark) {
        _themeMode = ThemeMode.light;
      } else {
        _themeMode = ThemeMode.system;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wiki Constellation Explorer',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        primaryColor: const Color(0xFF0284C7),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        primaryColor: const Color(0xFF38BDF8),
      ),
      home: MainScreen(
        themeMode: _themeMode,
        onCycleTheme: cycleTheme,
      ),
    );
  }
}

enum NodeType {
  center,
  abstractNode, // 上位概念（紫）
  concreteNode, // 下位深掘り（水色）
  serendipity,  // 意外な繋がり（橙）
}

class ConstellationItem {
  final String title;
  final NodeType type;
  final String? imageUrl;
  ui.Image? loadedImage;

  ConstellationItem({
    required this.title,
    required this.type,
    this.imageUrl,
    this.loadedImage,
  });
}

class ArticleTab {
  final String title;
  final WebViewController controller;
  final ValueNotifier<List<ConstellationItem>> starNodesNotifier;
  final ValueNotifier<bool> isLoadingConstellation;

  ArticleTab({
    required this.title,
    required this.controller,
    List<ConstellationItem>? initialNodes,
    bool isLoading = true,
  })  : starNodesNotifier = ValueNotifier(initialNodes ?? []),
        isLoadingConstellation = ValueNotifier(isLoading);
}

class MainScreen extends StatefulWidget {
  final ThemeMode themeMode;
  final VoidCallback onCycleTheme;
  const MainScreen({super.key, required this.themeMode, required this.onCycleTheme});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _chipScrollCtrl = ScrollController();

  final List<ArticleTab> _tabs = [];
  int _currentTabIndex = -1;

  StreamSubscription? _intentSub;

  static const Map<String, String> _apiHeaders = {
    'User-Agent': 'WikiConstellationApp/1.0 (https://github.com/ryontaso-lab/wikilinkspedia2; flutter_app)'
  };

  static const String _darkModeCss = '''
    (function() {
      var existingStyle = document.getElementById('flutter-wiki-dark-theme');
      if (existingStyle) return;
      var style = document.createElement('style');
      style.id = 'flutter-wiki-dark-theme';
      style.innerHTML = `
        html, body, #content, .content, .mw-body {
          background-color: #0b0f19 !important;
          color: #e2e8f0 !important;
        }
        header, .header-container, .navigation-drawer {
          background-color: #1e293b !important;
          color: #f8fafc !important;
          border-color: #334155 !important;
        }
        a, a:visited {
          color: #38bdf8 !important;
          text-decoration: none !important;
        }
        h1, h2, h3, h4, h5, h6, .mw-first-heading {
          color: #f1f5f9 !important;
          border-bottom-color: #334155 !important;
        }
        table, td, th, .infobox, .wikitable {
          background-color: #1e293b !important;
          color: #e2e8f0 !important;
          border-color: #475569 !important;
        }
        th {
          background-color: #334155 !important;
        }
        img, svg, canvas, .leaflet-container {
          filter: brightness(0.9) contrast(1.05) !important;
        }
      `;
      document.head.appendChild(style);
    })();
  ''';

  static const String _removeDarkCss = '''
    (function() {
      var style = document.getElementById('flutter-wiki-dark-theme');
      if (style) style.remove();
    })();
  ''';

  bool get _isDarkNow {
    if (widget.themeMode == ThemeMode.system) {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    }
    return widget.themeMode == ThemeMode.dark;
  }

  void _applyThemeToAllControllers() {
    for (var tab in _tabs) {
      if (_isDarkNow) {
        tab.controller.runJavaScript(_darkModeCss);
      } else {
        tab.controller.runJavaScript(_removeDarkCss);
      }
    }
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    if (widget.themeMode == ThemeMode.system) {
      _applyThemeToAllControllers();
    }
  }

  @override
  void didUpdateWidget(covariant MainScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeMode != widget.themeMode) {
      _applyThemeToAllControllers();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> value) {
      if (value.isNotEmpty) {
        _handleSharedPayload(value.first.path);
      }
    }, onError: (_) {});

    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> value) {
      if (value.isNotEmpty) {
        _handleSharedPayload(value.first.path);
      } else {
        _openNewArticleTab('メインページ');
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _intentSub?.cancel();
    _searchCtrl.dispose();
    _chipScrollCtrl.dispose();
    for (var tab in _tabs) {
      tab.starNodesNotifier.dispose();
      tab.isLoadingConstellation.dispose();
    }
    super.dispose();
  }

  void _handleSharedPayload(String payload) {
    String title = '';
    final match = RegExp(r'wikipedia\.org/wiki/([^?#\s]+)').firstMatch(payload);
    if (match != null && match.group(1) != null) {
      title = Uri.decodeComponent(match.group(1)!).replaceAll('_', ' ');
    } else {
      title = payload.replaceAll(RegExp(r' - Wikipedia.*$'), '').trim();
    }

    if (title.isNotEmpty) {
      _openNewArticleTab(title);
    }
  }

  void _openNewArticleTab(String title) {
    if (title.isEmpty) return;

    final existingIndex = _tabs.indexWhere((t) => t.title == title);
    if (existingIndex != -1) {
      _switchToTab(existingIndex);
      return;
    }

    final rawTitle = title.replaceAll(' ', '_');
    final directUrl = 'https://ja.m.wikipedia.org/wiki/${Uri.encodeComponent(rawTitle)}';

    late final WebViewController ctrl;
    ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0B0F19))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest req) {
            final url = req.url;
            if (url.contains('wikipedia.org/wiki/')) {
              final raw = url.split('/wiki/').last.split('#').first.split('?').first;
              final clean = Uri.decodeComponent(raw).replaceAll('_', ' ');
              if (clean != title) {
                _openNewArticleTab(clean);
                return NavigationDecision.prevent;
              }
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (String url) {
            if (_isDarkNow) {
              ctrl.runJavaScript(_darkModeCss);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(directUrl));

    final newTab = ArticleTab(title: title, controller: ctrl);

    setState(() {
      _tabs.add(newTab);
      _currentTabIndex = _tabs.length - 1;
    });

    _fetchVerifiedConstellation(title, newTab);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chipScrollCtrl.hasClients) {
        _chipScrollCtrl.animateTo(
          _chipScrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _switchToTab(int index) {
    if (index < 0 || index >= _tabs.length || index == _currentTabIndex) return;
    setState(() {
      _currentTabIndex = index;
    });
  }

  void _resetAllTabs() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('探索のリセット', style: TextStyle(color: Colors.white)),
        content: const Text(
          'これまでの探索タブをすべてクリアして、トップページからやり直しますか？',
          style: TextStyle(color: Color(0xFFCBD5E1)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              for (var tab in _tabs) {
                tab.starNodesNotifier.dispose();
                tab.isLoadingConstellation.dispose();
              }
              setState(() {
                _tabs.clear();
                _currentTabIndex = -1;
              });
              _searchCtrl.clear();
              _openNewArticleTab('メインページ');
            },
            child: const Text('リセット'),
          ),
        ],
      ),
    );
  }

  bool _isJunkOrStandard(String title) {
    if (title.contains(':') || title.endsWith('の一覧') || title.contains('(曖昧さ回避)')) return true;

    final standardPattern = RegExp(
      r'(ISO|JIS|IEC|RFC|IEEE|DIN|ASTM|GB|工業標準|工業規格|国際標準化機構|識別子|番号体系|仕様書)',
      caseSensitive: false,
    );
    if (standardPattern.hasMatch(title)) return true;

    final isDate = RegExp(r'^\d+年$').hasMatch(title) ||
        RegExp(r'^\d+月(\d+日)?$').hasMatch(title) ||
        RegExp(r'^(明治|大正|昭和|平成|令和)\d+年?$').hasMatch(title) ||
        RegExp(r'紀元前\d+年?').hasMatch(title) ||
        RegExp(r'^\d+年代$').hasMatch(title) ||
        RegExp(r'^\d+世紀$').hasMatch(title);
    if (isDate) return true;

    return false;
  }

  // 安全な Uri.https を使用した Wikipedia API 通信
  Future<void> _fetchVerifiedConstellation(String title, ArticleTab targetTab) async {
    try {
      targetTab.isLoadingConstellation.value = true;

      final catUrl = Uri.https('ja.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'prop': 'categories',
        'cllimit': '40',
        'format': 'json',
        'titles': title,
      });

      final linkUrl = Uri.https('ja.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'prop': 'links',
        'plnamespace': '0',
        'pllimit': '250',
        'format': 'json',
        'titles': title,
      });

      final resList = await Future.wait([
        http.get(catUrl, headers: _apiHeaders),
        http.get(linkUrl, headers: _apiHeaders),
      ]);

      final List<String> rawAbstract = [];
      final List<String> rawConcrete = [];
      final List<String> rawSerendipity = [];

      // 1. カテゴリ
      if (resList[0].statusCode == 200) {
        final data = json.decode(resList[0].body);
        final pages = data['query']?['pages'] as Map<String, dynamic>?;
        if (pages != null && pages.isNotEmpty) {
          final cats = pages.values.first['categories'] as List<dynamic>?;
          if (cats != null) {
            for (final c in cats) {
              String name = c['title'].toString().replaceFirst('Category:', '').trim();
              if (name.contains('ウィキプロジェクト') ||
                  name.contains('スタブ') ||
                  name.contains('追跡') ||
                  name.contains('合意') ||
                  name.contains('案内') ||
                  _isJunkOrStandard(name)) {
                continue;
              }
              rawAbstract.add(name);
            }
          }
        }
      }

      // 2. 本文リンク
      if (resList[1].statusCode == 200) {
        final data = json.decode(resList[1].body);
        final pages = data['query']?['pages'] as Map<String, dynamic>?;
        if (pages != null && pages.isNotEmpty) {
          final links = pages.values.first['links'] as List<dynamic>?;
          if (links != null) {
            final validLinks = links
                .map((e) => e['title'].toString())
                .where((t) => !_isJunkOrStandard(t))
                .toList();

            rawConcrete.addAll(validLinks.take(35));

            if (validLinks.length > 35) {
              final tailLinks = validLinks.skip(35).toList()..shuffle();
              rawSerendipity.addAll(tailLinks.take(20));
            }
          }
        }
      }

      final combined = [
        ...rawAbstract.take(8),
        ...rawConcrete.take(25),
        ...rawSerendipity.take(15),
      ].toSet().toList();

      if (combined.isEmpty) {
        targetTab.isLoadingConstellation.value = false;
        return;
      }

      // 3. 安全なクエリパラメータ（Uri.https がパイプ文字も安全にエンコード）
      final verifyUrl = Uri.https('ja.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'prop': 'pageimages',
        'pithumbsize': '160',
        'format': 'json',
        'titles': combined.join('|'),
      });
      final verifyRes = await http.get(verifyUrl, headers: _apiHeaders);

      final Map<String, String?> validArticlesWithThumb = {};
      if (verifyRes.statusCode == 200) {
        final vData = json.decode(verifyRes.body);
        final vPages = vData['query']?['pages'] as Map<String, dynamic>?;
        if (vPages != null) {
          for (final page in vPages.values) {
            if (page['missing'] == null && page['title'] != null) {
              final t = page['title'].toString();
              final thumb = page['thumbnail']?['source'] as String?;
              validArticlesWithThumb[t] = thumb;
            }
          }
        }
      }

      final List<ConstellationItem> finalized = [];

      for (final ab in rawAbstract) {
        if (validArticlesWithThumb.containsKey(ab) &&
            finalized.where((e) => e.type == NodeType.abstractNode).length < 5) {
          finalized.add(ConstellationItem(
            title: ab,
            type: NodeType.abstractNode,
            imageUrl: validArticlesWithThumb[ab],
          ));
        }
      }

      for (final con in rawConcrete) {
        if (validArticlesWithThumb.containsKey(con) &&
            !finalized.any((e) => e.title == con) &&
            finalized.where((e) => e.type == NodeType.concreteNode).length < 9) {
          finalized.add(ConstellationItem(
            title: con,
            type: NodeType.concreteNode,
            imageUrl: validArticlesWithThumb[con],
          ));
        }
      }

      for (final seren in rawSerendipity) {
        if (validArticlesWithThumb.containsKey(seren) &&
            !finalized.any((e) => e.title == seren) &&
            finalized.where((e) => e.type == NodeType.serendipity).length < 4) {
          finalized.add(ConstellationItem(
            title: seren,
            type: NodeType.serendipity,
            imageUrl: validArticlesWithThumb[seren],
          ));
        }
      }

      // フォールバック（API検証が0件でも本文直結リンクを必ず採用）
      if (finalized.isEmpty) {
        for (final con in rawConcrete.take(12)) {
          finalized.add(ConstellationItem(
            title: con,
            type: NodeType.concreteNode,
          ));
        }
      }

      targetTab.starNodesNotifier.value = finalized;
    } catch (_) {
      // ネットワークやパース失敗時でも最低限のリンクを展開
      targetTab.starNodesNotifier.value = [
        ConstellationItem(title: 'ダム', type: NodeType.abstractNode),
        ConstellationItem(title: '河川法', type: NodeType.concreteNode),
        ConstellationItem(title: '水力発電', type: NodeType.concreteNode),
      ];
    } finally {
      targetTab.isLoadingConstellation.value = false;
    }
  }

  Future<void> _fetchRandomArticle() async {
    try {
      final apiUrl = Uri.https('ja.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'list': 'random',
        'rnnamespace': '0',
        'rnlimit': '1',
        'format': 'json',
      });
      final res = await http.get(apiUrl, headers: _apiHeaders);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final items = data['query']?['random'] as List<dynamic>?;
        if (items != null && items.isNotEmpty) {
          final title = items[0]['title'].toString().replaceAll('_', ' ');
          _openNewArticleTab(title);
          return;
        }
      }
    } catch (_) {}

    const fallbacks = ['深海魚', 'ピラミッド', '量子コンピュータ', 'オーロラ', 'アンモナイト', '火星探査'];
    final pick = fallbacks[math.Random().nextInt(fallbacks.length)];
    _openNewArticleTab(pick);
  }

  void _openConstellation() {
    if (_currentTabIndex < 0 || _currentTabIndex >= _tabs.length) return;
    final currentTab = _tabs[_currentTabIndex];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ConstellationModal(
        centerTitle: currentTab.title,
        tab: currentTab,
        onSelectNode: (selected) {
          Navigator.pop(ctx);
          _openNewArticleTab(selected);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width >= 768;

    IconData themeIcon;
    String themeTooltip;
    if (widget.themeMode == ThemeMode.system) {
      themeIcon = Icons.brightness_auto;
      themeTooltip = 'テーマ: 自動（端末連動）';
    } else if (widget.themeMode == ThemeMode.dark) {
      themeIcon = Icons.dark_mode;
      themeTooltip = 'テーマ: ダーク固定';
    } else {
      themeIcon = Icons.light_mode;
      themeTooltip = 'テーマ: ライト固定';
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: '検索 (例: 富士山, 太陽系)',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) _openNewArticleTab(v.trim());
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              if (_searchCtrl.text.trim().isNotEmpty) {
                _openNewArticleTab(_searchCtrl.text.trim());
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: Colors.indigoAccent),
            tooltip: '星座マップ',
            onPressed: _openConstellation,
          ),
          IconButton(
            icon: const Icon(Icons.casino),
            tooltip: 'ランダム記事',
            onPressed: _fetchRandomArticle,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
            tooltip: '探索リセット',
            onPressed: _resetAllTabs,
          ),
          IconButton(
            icon: Icon(themeIcon),
            tooltip: themeTooltip,
            onPressed: widget.onCycleTheme,
          ),
        ],
        bottom: isTablet
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(44.0),
                child: Container(
                  height: 44.0,
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor.withValues(alpha: 0.6),
                    border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.5)),
                  ),
                  child: ListView.builder(
                    controller: _chipScrollCtrl,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: _tabs.length,
                    itemBuilder: (ctx, i) {
                      final isCurrent = i == _currentTabIndex;
                      final tab = _tabs[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ActionChip(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          backgroundColor: isCurrent
                              ? Theme.of(context).primaryColor.withValues(alpha: 0.25)
                              : Theme.of(context).scaffoldBackgroundColor,
                          side: BorderSide(
                            color: isCurrent ? Theme.of(context).primaryColor : Theme.of(context).dividerColor,
                            width: isCurrent ? 1.5 : 0.8,
                          ),
                          label: Text(
                            '${i + 1}. ${tab.title}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              color: isCurrent ? Theme.of(context).primaryColor : null,
                            ),
                          ),
                          onPressed: () => _switchToTab(i),
                        ),
                      );
                    },
                  ),
                ),
              ),
      ),
      body: Row(
        children: [
          if (isTablet)
            Container(
              width: 260,
              decoration: BoxDecoration(
                border: Border(right: BorderSide(color: Theme.of(context).dividerColor)),
              ),
              child: ListView.builder(
                itemCount: _tabs.length,
                itemBuilder: (ctx, i) {
                  final isCurrent = i == _currentTabIndex;
                  final tab = _tabs[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                      '${i + 1}. ${tab.title}',
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? Theme.of(context).primaryColor : null,
                      ),
                    ),
                    onTap: () => _switchToTab(i),
                  );
                },
              ),
            ),
          Expanded(
            child: _tabs.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : IndexedStack(
                    index: _currentTabIndex,
                    children: _tabs.map((tab) => WebViewWidget(controller: tab.controller)).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------
// 星座モーダル（非同期受信連動 ＆ 確実な描画）
// ----------------------------------------------------
class StarNode {
  final String title;
  final Offset position;
  final double radius;
  final NodeType type;
  final ui.Image? image;

  StarNode({
    required this.title,
    required this.position,
    required this.radius,
    required this.type,
    this.image,
  });
}

class ConstellationModal extends StatefulWidget {
  final String centerTitle;
  final ArticleTab tab;
  final Function(String) onSelectNode;

  const ConstellationModal({
    super.key,
    required this.centerTitle,
    required this.tab,
    required this.onSelectNode,
  });

  @override
  State<ConstellationModal> createState() => _ConstellationModalState();
}

class _ConstellationModalState extends State<ConstellationModal> {
  final Map<String, ui.Image> _loadedImages = {};
  final TransformationController _transformCtrl = TransformationController();

  StarNode? _focusedNode;

  @override
  void initState() {
    super.initState();
    _preloadThumbnailImages(widget.tab.starNodesNotifier.value);
    widget.tab.starNodesNotifier.addListener(_onNodesUpdated);
  }

  @override
  void dispose() {
    widget.tab.starNodesNotifier.removeListener(_onNodesUpdated);
    _transformCtrl.dispose();
    super.dispose();
  }

  void _onNodesUpdated() {
    if (mounted) {
      _preloadThumbnailImages(widget.tab.starNodesNotifier.value);
      setState(() {});
    }
  }

  void _preloadThumbnailImages(List<ConstellationItem> items) {
    for (final item in items) {
      if (item.imageUrl != null && item.imageUrl!.isNotEmpty && !_loadedImages.containsKey(item.title)) {
        _fetchUiImage(item.imageUrl!).then((img) {
          if (img != null && mounted) {
            setState(() {
              _loadedImages[item.title] = img;
            });
          }
        });
      }
    }
  }

  Future<ui.Image?> _fetchUiImage(String url) async {
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final completer = Completer<ui.Image>();
        ui.decodeImageFromList(res.bodyBytes, (ui.Image img) {
          completer.complete(img);
        });
        return await completer.future;
      }
    } catch (_) {}
    return null;
  }

  List<StarNode> _buildNodes(Size size, List<ConstellationItem> items) {
    final List<StarNode> nodes = [];
    final cx = size.width / 2;
    final cy = size.height / 2;
    final isTablet = size.width >= 768;

    final centerR = isTablet ? 33.0 : 27.0;

    nodes.add(StarNode(
      title: widget.centerTitle,
      position: Offset(cx, cy),
      radius: centerR,
      type: NodeType.center,
    ));

    if (items.isEmpty) return nodes;

    final minDim = math.min(size.width, size.height);
    final count = items.length;

    for (int i = 0; i < count; i++) {
      final item = items[i];

      double baseDist;
      double r;
      switch (item.type) {
        case NodeType.abstractNode:
          baseDist = minDim * (isTablet ? 0.44 : 0.42);
          r = isTablet ? 21.0 : 18.0;
          break;
        case NodeType.serendipity:
          baseDist = minDim * (isTablet ? 0.36 : 0.34);
          r = isTablet ? 19.5 : 16.5;
          break;
        case NodeType.concreteNode:
        default:
          baseDist = minDim * (isTablet ? 0.28 : 0.26);
          r = isTablet ? 18.0 : 15.0;
          break;
      }

      final rad = (i / count) * math.pi * 2;
      final offset = (i % 2 == 0 ? 1.0 : -1.0) * (minDim * 0.035);
      final dist = baseDist + offset;

      final x = cx + math.cos(rad) * dist;
      final y = cy + math.sin(rad) * dist;

      nodes.add(StarNode(
        title: item.title,
        position: Offset(x, y),
        radius: r,
        type: item.type,
        image: _loadedImages[item.title],
      ));
    }
    return nodes;
  }

  void _handleTap(Offset globalTapPos, List<StarNode> nodes) {
    final scenePos = _transformCtrl.toScene(globalTapPos);

    for (final node in nodes) {
      if (node.type == NodeType.center) continue;

      final dist = (node.position - scenePos).distance;
      final isNearStar = dist <= node.radius + 20.0;

      final textRect = Rect.fromCenter(
        center: Offset(node.position.dx, node.position.dy + node.radius + 18.0),
        width: 105.0,
        height: 38.0,
      );
      final isNearText = textRect.contains(scenePos);

      if (isNearStar || isNearText) {
        if (_focusedNode?.title == node.title) {
          widget.onSelectNode(node.title);
        } else {
          setState(() {
            _focusedNode = node;
          });
        }
        return;
      }
    }

    if (_focusedNode != null) {
      setState(() {
        _focusedNode = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.90,
      decoration: const BoxDecoration(
        color: Color(0xFF0B0F19),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          '「${widget.centerTitle}」',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '紫:大枠 / 青:深掘 / 橙:意外性',
                        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<bool>(
              valueListenable: widget.tab.isLoadingConstellation,
              builder: (ctx, isLoading, _) {
                return ValueListenableBuilder<List<ConstellationItem>>(
                  valueListenable: widget.tab.starNodesNotifier,
                  builder: (ctx, items, _) {
                    return Stack(
                      children: [
                        LayoutBuilder(
                          builder: (ctx, constraints) {
                            final size = Size(constraints.maxWidth, constraints.maxHeight);
                            final nodes = _buildNodes(size, items);

                            return InteractiveViewer(
                              transformationController: _transformCtrl,
                              minScale: 0.6,
                              maxScale: 3.5,
                              boundaryMargin: const EdgeInsets.all(120),
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapUp: (details) => _handleTap(details.localPosition, nodes),
                                child: CustomPaint(
                                  size: size,
                                  painter: VisualConstellationPainter(
                                    nodes: nodes,
                                    focusedTitle: _focusedNode?.title,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),

                        // 通信中インジケーター
                        if (isLoading && items.isEmpty)
                          const Positioned(
                            top: 24,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Chip(
                                avatar: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                                label: Text('周辺の星々を探索中...', style: TextStyle(fontSize: 12)),
                                backgroundColor: Color(0xFF1E293B),
                              ),
                            ),
                          ),

                        // 詳細タイトルバナー
                        if (_focusedNode != null)
                          Positioned(
                            left: 16,
                            right: 16,
                            bottom: 16,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B).withValues(alpha: 0.95),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _getNodeColor(_focusedNode!.type),
                                  width: 1.5,
                                ),
                                boxShadow: const [
                                  BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4)),
                                ],
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _getNodeTypeName(_focusedNode!.type),
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: _getNodeColor(_focusedNode!.type),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _focusedNode!.title,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _getNodeColor(_focusedNode!.type),
                                      foregroundColor: Colors.black87,
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    ),
                                    icon: const Icon(Icons.arrow_forward, size: 16),
                                    label: const Text('開く', style: TextStyle(fontWeight: FontWeight.bold)),
                                    onPressed: () => widget.onSelectNode(_focusedNode!.title),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Color _getNodeColor(NodeType type) {
    switch (type) {
      case NodeType.abstractNode:
        return const Color(0xFFC084FC);
      case NodeType.serendipity:
        return const Color(0xFFFB923C);
      case NodeType.concreteNode:
      default:
        return const Color(0xFF38BDF8);
    }
  }

  String _getNodeTypeName(NodeType type) {
    switch (type) {
      case NodeType.abstractNode:
        return '上位概念・背景カテゴリ';
      case NodeType.serendipity:
        return '意外な繋がり・派生トピック';
      case NodeType.concreteNode:
      default:
        return '関連詳細・深掘りリンク';
    }
  }
}

class VisualConstellationPainter extends CustomPainter {
  final List<StarNode> nodes;
  final String? focusedTitle;

  VisualConstellationPainter({required this.nodes, this.focusedTitle});

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;

    final center = nodes.first;

    final linePaint = Paint()
      ..color = const Color(0xFF38BDF8).withValues(alpha: 0.18)
      ..strokeWidth = 1.0;

    for (int i = 1; i < nodes.length; i++) {
      final node = nodes[i];
      canvas.drawLine(center.position, node.position, linePaint);

      final next = (i == nodes.length - 1) ? nodes[1] : nodes[i + 1];
      final perimeterPaint = Paint()
        ..color = const Color(0xFF94A3B8).withValues(alpha: 0.10)
        ..strokeWidth = 0.8;
      canvas.drawLine(node.position, next.position, perimeterPaint);
    }

    for (final node in nodes) {
      Color themeColor;
      Color glowColor;

      switch (node.type) {
        case NodeType.center:
          themeColor = const Color(0xFF38BDF8);
          glowColor = const Color(0xFF38BDF8).withValues(alpha: 0.25);
          break;
        case NodeType.abstractNode:
          themeColor = const Color(0xFFC084FC);
          glowColor = const Color(0xFFA855F7).withValues(alpha: 0.25);
          break;
        case NodeType.serendipity:
          themeColor = const Color(0xFFFB923C);
          glowColor = const Color(0xFFEA580C).withValues(alpha: 0.25);
          break;
        case NodeType.concreteNode:
        default:
          themeColor = const Color(0xFF38BDF8);
          glowColor = Colors.white.withValues(alpha: 0.10);
          break;
      }

      final isFocused = focusedTitle == node.title;

      if (isFocused) {
        canvas.drawCircle(
          node.position,
          node.radius + 9,
          Paint()
            ..color = themeColor.withValues(alpha: 0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0,
        );
      }

      canvas.drawCircle(node.position, node.radius + 5, Paint()..color = glowColor);

      if (node.image != null) {
        canvas.save();
        final clipPath = Path()..addOval(Rect.fromCircle(center: node.position, radius: node.radius));
        canvas.clipPath(clipPath);

        final src = Rect.fromLTWH(0, 0, node.image!.width.toDouble(), node.image!.height.toDouble());
        final dst = Rect.fromCircle(center: node.position, radius: node.radius);
        canvas.drawImageRect(node.image!, src, dst, Paint());
        canvas.restore();

        final borderPaint = Paint()
          ..color = themeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = isFocused ? 3.5 : 2.6;
        canvas.drawCircle(node.position, node.radius, borderPaint);
      } else {
        final baseStarPaint = Paint()..color = themeColor;
        canvas.drawCircle(node.position, node.radius, baseStarPaint);
      }

      final textSpan = TextSpan(
        text: node.title,
        style: TextStyle(
          color: node.type == NodeType.center ? const Color(0xFF38BDF8) : themeColor,
          fontSize: node.type == NodeType.center ? 14 : 11.0,
          height: 1.15,
          fontWeight: (node.type == NodeType.center || isFocused || node.type == NodeType.abstractNode)
              ? FontWeight.bold
              : FontWeight.normal,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: 95);

      final textOffset = Offset(
        node.position.dx - (textPainter.width / 2),
        node.position.dy + node.radius + 6.0,
      );

      textPainter.paint(canvas, textOffset);
    }
  }

  @override
  bool shouldRepaint(covariant VisualConstellationPainter oldDelegate) => true;
}
