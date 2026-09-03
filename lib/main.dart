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

class _WikiAppState extends State<WikiApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
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
        onToggleTheme: toggleTheme,
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
  List<ConstellationItem> starNodes;

  ArticleTab({
    required this.title,
    required this.controller,
    this.starNodes = const [],
  });
}

class MainScreen extends StatefulWidget {
  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;
  const MainScreen({super.key, required this.themeMode, required this.onToggleTheme});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
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
  void didUpdateWidget(covariant MainScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeMode != widget.themeMode) {
      _applyThemeToAllControllers();
    }
  }

  @override
  void initState() {
    super.initState();

    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> value) {
      if (value.isNotEmpty) {
        _handleSharedPayload(value.first.path);
      }
    }, onError: (_) {});

    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> value) {
      if (value.isNotEmpty) {
        _handleSharedPayload(value.first.path);
      } else {
        _fetchRandomArticle();
      }
    });
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    _searchCtrl.dispose();
    _chipScrollCtrl.dispose();
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

  // 規格・ISO・識別コード・日付を除外（条約や協定は許可）
  bool _isJunkOrStandard(String title) {
    if (title.contains(':') || title.endsWith('の一覧') || title.contains('(曖昧さ回避)')) return true;

    // ISO・JIS・工業規格・識別番号などの工業ノイズのみ遮断（条約・協定・議定書は通過）
    final standardPattern = RegExp(
      r'(ISO|JIS|IEC|RFC|IEEE|DIN|ASTM|GB|工業標準|工業規格|国際標準化機構|コード|識別子|番号体系|仕様書)',
      caseSensitive: false,
    );
    if (standardPattern.hasMatch(title)) return true;

    // 日付・年号・時代区分の遮断
    final isDate = RegExp(r'^\d+年$').hasMatch(title) ||
        RegExp(r'^\d+月(\d+日)?$').hasMatch(title) ||
        RegExp(r'^(明治|大正|昭和|平成|令和)\d+年?$').hasMatch(title) ||
        RegExp(r'紀元前\d+年?').hasMatch(title) ||
        RegExp(r'^\d+年代$').hasMatch(title) ||
        RegExp(r'^\d+世紀$').hasMatch(title);
    if (isDate) return true;

    return false;
  }

  // 星座候補の取得 ＆ 画像付き検証
  Future<void> _fetchVerifiedConstellation(String title, ArticleTab targetTab) async {
    try {
      final catUrl = Uri.parse(
        'https://ja.wikipedia.org/w/api.php?action=query&prop=categories&cllimit=40&format=json&titles=${Uri.encodeComponent(title)}'
      );
      final linkUrl = Uri.parse(
        'https://ja.wikipedia.org/w/api.php?action=query&prop=links&plnamespace=0&pllimit=250&format=json&titles=${Uri.encodeComponent(title)}'
      );

      final resList = await Future.wait([
        http.get(catUrl, headers: _apiHeaders),
        http.get(linkUrl, headers: _apiHeaders),
      ]);

      final List<String> rawAbstract = [];
      final List<String> rawConcrete = [];
      final List<String> rawSerendipity = [];

      // 1. 上位概念（カテゴリ）
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

      // 2. 下位深掘り ＆ 意外な繋がり（本文リンク）
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

            // 前半（直結トピック＝下位深掘り）
            rawConcrete.addAll(validLinks.take(40));

            // 後半（周辺トピック・派生文化・歴史的出来事＝意外な繋がり）
            if (validLinks.length > 40) {
              final tailLinks = validLinks.skip(40).toList()..shuffle();
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

      if (combined.isEmpty) return;

      // 3. APIで実在確認 ＋ サムネイル画像URLを一括取得
      final verifyUrl = Uri.parse(
        'https://ja.wikipedia.org/w/api.php?action=query&prop=pageimages&pithumbsize=120&titles=${Uri.encodeComponent(combined.join('|'))}&format=json'
      );
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

      // 上位概念（紫）最大5件
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

      // 下位深掘り（水色）最大9件
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

      // 意外な繋がり（橙色）最大4件
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

      setState(() {
        targetTab.starNodes = finalized;
      });
    } catch (_) {}
  }

  Future<void> _fetchRandomArticle() async {
    try {
      final apiUrl = Uri.parse(
        'https://ja.wikipedia.org/w/api.php?action=query&list=random&rnnamespace=0&rnlimit=1&format=json'
      );
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
        items: currentTab.starNodes,
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
            icon: Icon(_isDarkNow ? Icons.light_mode : Icons.dark_mode),
            tooltip: 'テーマ切り替え',
            onPressed: widget.onToggleTheme,
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
// 星座モーダル ＆ 画像付きカスタムペインター
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
  final List<ConstellationItem> items;
  final Function(String) onSelectNode;

  const ConstellationModal({
    super.key,
    required this.centerTitle,
    required this.items,
    required this.onSelectNode,
  });

  @override
  State<ConstellationModal> createState() => _ConstellationModalState();
}

class _ConstellationModalState extends State<ConstellationModal> {
  final Map<String, ui.Image> _loadedImages = {};

  @override
  void initState() {
    super.initState();
    _preloadThumbnailImages();
  }

  void _preloadThumbnailImages() {
    for (final item in widget.items) {
      if (item.imageUrl != null && item.imageUrl!.isNotEmpty) {
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

  List<StarNode> _buildNodes(Size size) {
    final List<StarNode> nodes = [];
    final cx = size.width / 2;
    final cy = size.height / 2;
    final isTablet = size.width >= 768;

    final centerR = isTablet ? 22.0 : 18.0;

    nodes.add(StarNode(
      title: widget.centerTitle,
      position: Offset(cx, cy),
      radius: centerR,
      type: NodeType.center,
    ));

    if (widget.items.isEmpty) return nodes;

    final minDim = math.min(size.width, size.height);
    final count = widget.items.length;

    for (int i = 0; i < count; i++) {
      final item = widget.items[i];

      double baseDist;
      double r;
      switch (item.type) {
        case NodeType.abstractNode:
          baseDist = minDim * (isTablet ? 0.44 : 0.42);
          r = isTablet ? 14.0 : 12.0;
          break;
        case NodeType.serendipity:
          baseDist = minDim * (isTablet ? 0.36 : 0.34);
          r = isTablet ? 13.0 : 11.0;
          break;
        case NodeType.concreteNode:
        default:
          baseDist = minDim * (isTablet ? 0.28 : 0.26);
          r = isTablet ? 12.0 : 10.0;
          break;
      }

      final rad = (i / count) * math.pi * 2;
      final offset = (i % 2 == 0 ? 1.0 : -1.0) * (minDim * 0.03);
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

  void _handleTap(Offset tapPos, List<StarNode> nodes) {
    for (final node in nodes) {
      if (node.type == NodeType.center) continue;

      final dist = (node.position - tapPos).distance;
      if (dist <= node.radius + 24.0) {
        widget.onSelectNode(node.title);
        return;
      }

      final textRect = Rect.fromCenter(
        center: Offset(node.position.dx, node.position.dy + node.radius + 14.0),
        width: 100.0,
        height: 28.0,
      );
      if (textRect.contains(tapPos)) {
        widget.onSelectNode(node.title);
        return;
      }
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
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                final nodes = _buildNodes(size);

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => _handleTap(details.localPosition, nodes),
                  child: CustomPaint(
                    size: size,
                    painter: VisualConstellationPainter(nodes: nodes),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class VisualConstellationPainter extends CustomPainter {
  final List<StarNode> nodes;

  VisualConstellationPainter({required this.nodes});

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
          themeColor = const Color(0xFFC084FC); // 紫
          glowColor = const Color(0xFFA855F7).withValues(alpha: 0.25);
          break;
        case NodeType.serendipity:
          themeColor = const Color(0xFFFB923C); // 橙（意外性）
          glowColor = const Color(0xFFEA580C).withValues(alpha: 0.25);
          break;
        case NodeType.concreteNode:
        default:
          themeColor = const Color(0xFF38BDF8); // 水色
          glowColor = Colors.white.withValues(alpha: 0.10);
          break;
      }

      canvas.drawCircle(node.position, node.radius + 4, Paint()..color = glowColor);

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
          ..strokeWidth = 2.2;
        canvas.drawCircle(node.position, node.radius, borderPaint);
      } else {
        final baseStarPaint = Paint()..color = themeColor;
        canvas.drawCircle(node.position, node.radius, baseStarPaint);
      }

      final displayLabel = node.title.length > 8 ? '${node.title.substring(0, 7)}…' : node.title;
      final textSpan = TextSpan(
        text: displayLabel,
        style: TextStyle(
          color: node.type == NodeType.center ? const Color(0xFF38BDF8) : themeColor,
          fontSize: node.type == NodeType.center ? 14 : 11,
          fontWeight: (node.type == NodeType.center || node.type == NodeType.abstractNode)
              ? FontWeight.bold
              : FontWeight.normal,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 120);

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
