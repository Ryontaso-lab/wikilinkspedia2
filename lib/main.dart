import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
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

class HistoryItem {
  final String title;
  int scrollY;

  HistoryItem({required this.title, this.scrollY = 0});
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
  late final WebViewController _webCtrl;

  String _currentTitle = '読み込み中...';
  final List<HistoryItem> _history = [];
  int _currentHistoryIdx = -1;
  List<ConstellationItem> _starNodes = [];
  int _targetRestoreScrollY = 0;
  int _latestReportedScrollY = 0;

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

  void _applyThemeToWebView() {
    if (_isDarkNow) {
      _webCtrl.runJavaScript(_darkModeCss);
    } else {
      _webCtrl.runJavaScript(_removeDarkCss);
    }
  }

  @override
  void didUpdateWidget(covariant MainScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeMode != widget.themeMode) {
      _applyThemeToWebView();
    }
  }

  @override
  void initState() {
    super.initState();

    _webCtrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF0B0F19))
      ..addJavaScriptChannel(
        'ScrollTracker',
        onMessageReceived: (JavaScriptMessage msg) {
          final val = int.tryParse(msg.message);
          if (val != null) {
            _latestReportedScrollY = val;
            if (_currentHistoryIdx >= 0 && _currentHistoryIdx < _history.length) {
              _history[_currentHistoryIdx].scrollY = val;
            }
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest req) {
            final url = req.url;
            if (url.contains('wikipedia.org/wiki/')) {
              final raw = url.split('/wiki/').last.split('#').first.split('?').first;
              final clean = Uri.decodeComponent(raw).replaceAll('_', ' ');
              if (clean != _currentTitle) {
                _loadArticle(clean);
                return NavigationDecision.prevent;
              }
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (String url) {
            _applyThemeToWebView();

            _webCtrl.runJavaScript('''
              window.removeEventListener('scroll', window._flutterScrollDebounce);
              window._flutterScrollDebounce = function() {
                if (window.ScrollTracker) {
                  window.ScrollTracker.postMessage(Math.round(window.scrollY || window.pageYOffset || 0).toString());
                }
              };
              window.addEventListener('scroll', window._flutterScrollDebounce, { passive: true });
            ''');

            if (_targetRestoreScrollY > 0) {
              final targetY = _targetRestoreScrollY;
              _targetRestoreScrollY = 0;
              _webCtrl.runJavaScript('''
                (function() {
                  var target = $targetY;
                  var tries = 0;
                  var interval = setInterval(function() {
                    window.scrollTo(0, target);
                    tries++;
                    if (Math.abs((window.scrollY || window.pageYOffset || 0) - target) < 15 || tries > 10) {
                      clearInterval(interval);
                    }
                  }, 80);
                })();
              ''');
            }
          },
        ),
      );

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
      _loadArticle(title);
    }
  }

  Future<void> _loadArticle(String title, {bool addHistory = true, int restoreScrollY = 0}) async {
    if (title.isEmpty) return;

    if (_currentHistoryIdx >= 0 && _currentHistoryIdx < _history.length) {
      _history[_currentHistoryIdx].scrollY = _latestReportedScrollY;
    }

    setState(() {
      _currentTitle = title;
      _targetRestoreScrollY = restoreScrollY;
      _latestReportedScrollY = restoreScrollY;
    });

    final rawTitle = title.replaceAll(' ', '_');
    final directUrl = 'https://ja.m.wikipedia.org/wiki/${Uri.encodeComponent(rawTitle)}';

    _webCtrl.loadRequest(Uri.parse(directUrl));

    if (addHistory) {
      setState(() {
        _history.add(HistoryItem(title: title, scrollY: 0));
        _currentHistoryIdx = _history.length - 1;
      });
    }

    _fetchVerifiedConstellation(title);
  }

  // 実在確認付きの上位概念（抽象）と下位概念（具体）の精製取得
  Future<void> _fetchVerifiedConstellation(String title) async {
    try {
      final catUrl = Uri.parse(
        'https://ja.wikipedia.org/w/api.php?action=query&prop=categories&cllimit=40&format=json&titles=${Uri.encodeComponent(title)}'
      );
      final linkUrl = Uri.parse(
        'https://ja.wikipedia.org/w/api.php?action=query&prop=links&plnamespace=0&pllimit=150&format=json&titles=${Uri.encodeComponent(title)}'
      );

      final resList = await Future.wait([
        http.get(catUrl, headers: _apiHeaders),
        http.get(linkUrl, headers: _apiHeaders),
      ]);

      final List<String> rawAbstractCandidates = [];
      final List<String> rawConcreteCandidates = [];

      // 1. 上位候補（カテゴリから管理タグを除いた名詞）
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
                  name.contains('識別子') ||
                  name.contains('合意') ||
                  name.contains('案内') ||
                  name.contains('一覧') ||
                  RegExp(r'\d+年').hasMatch(name)) {
                continue;
              }
              rawAbstractCandidates.add(name);
            }
          }
        }
      }

      // 2. 下位候補（本文リンクから日付・管理タグを除外）
      if (resList[1].statusCode == 200) {
        final data = json.decode(resList[1].body);
        final pages = data['query']?['pages'] as Map<String, dynamic>?;
        if (pages != null && pages.isNotEmpty) {
          final links = pages.values.first['links'] as List<dynamic>?;
          if (links != null) {
            for (final l in links) {
              final t = l['title'].toString();
              if (t.contains(':') || t.endsWith('の一覧') || t.contains('(曖昧さ回避)')) continue;

              final isDate = RegExp(r'^\d+年$').hasMatch(t) ||
                  RegExp(r'^\d+月(\d+日)?$').hasMatch(t) ||
                  RegExp(r'^(明治|大正|昭和|平成|令和)\d+年?$').hasMatch(t) ||
                  RegExp(r'紀元前\d+年?').hasMatch(t) ||
                  RegExp(r'^\d+年代$').hasMatch(t) ||
                  RegExp(r'^\d+世紀$').hasMatch(t);

              if (isDate) continue;
              rawConcreteCandidates.add(t);
            }
          }
        }
      }

      // 3. 実在確認（API一括検証：赤リンクを100%排除）
      final allCandidates = [
        ...rawAbstractCandidates.take(12),
        ...rawConcreteCandidates.take(30),
      ];

      if (allCandidates.isEmpty) return;

      final verifyUrl = Uri.parse(
        'https://ja.wikipedia.org/w/api.php?action=query&titles=${Uri.encodeComponent(allCandidates.join('|'))}&format=json'
      );
      final verifyRes = await http.get(verifyUrl, headers: _apiHeaders);

      final Set<String> validArticles = {};
      if (verifyRes.statusCode == 200) {
        final vData = json.decode(verifyRes.body);
        final vPages = vData['query']?['pages'] as Map<String, dynamic>?;
        if (vPages != null) {
          for (final page in vPages.values) {
            // missing（存在しない記事）が付いていないものだけを許可
            if (page['missing'] == null && page['title'] != null) {
              validArticles.add(page['title'].toString());
            }
          }
        }
      }

      // 4. 実在する記事のみで抽象・具体ノードを構築
      final List<ConstellationItem> finalized = [];

      // 上位概念（抽象：紫）最大6件
      for (final ab in rawAbstractCandidates) {
        if (validArticles.contains(ab) && finalized.where((e) => e.isAbstract).length < 6) {
          finalized.add(ConstellationItem(title: ab, isAbstract: true));
        }
      }

      // 下位概念（具体：水色）最大14件
      for (final con in rawConcreteCandidates) {
        if (validArticles.contains(con) &&
            !finalized.any((e) => e.title == con) &&
            finalized.where((e) => !e.isAbstract).length < 14) {
          finalized.add(ConstellationItem(title: con, isAbstract: false));
        }
      }

      setState(() {
        _starNodes = finalized;
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
          _loadArticle(title);
          return;
        }
      }
    } catch (_) {}

    const fallbacks = ['深海魚', 'ピラミッド', '量子コンピュータ', 'オーロラ', 'アンモナイト', '火星探査'];
    final pick = fallbacks[math.Random().nextInt(fallbacks.length)];
    _loadArticle(pick);
  }

  void _openConstellation() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ConstellationModal(
        centerTitle: _currentTitle,
        items: _starNodes,
        onSelectNode: (selected) {
          Navigator.pop(ctx);
          _loadArticle(selected);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width >= 768;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: '検索 (例: 富士山, 太陽系)',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) _loadArticle(v.trim());
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              if (_searchCtrl.text.trim().isNotEmpty) {
                _loadArticle(_searchCtrl.text.trim());
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
                itemCount: _history.length,
                itemBuilder: (ctx, i) {
                  final isCurrent = i == _currentHistoryIdx;
                  final item = _history[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                      '${i + 1}. ${item.title}',
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? Theme.of(context).primaryColor : null,
                      ),
                    ),
                    onTap: () {
                      if (_currentHistoryIdx == i) return;
                      final targetScrollY = item.scrollY;
                      _currentHistoryIdx = i;
                      _loadArticle(item.title, addHistory: false, restoreScrollY: targetScrollY);
                    },
                  );
                },
              ),
            ),
          Expanded(
            child: WebViewWidget(controller: _webCtrl),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------
// 星座データモデル & UI
// ----------------------------------------------------
class ConstellationItem {
  final String title;
  final bool isAbstract;

  ConstellationItem({required this.title, required this.isAbstract});
}

class StarNode {
  final String title;
  final Offset position;
  final double radius;
  final bool isCenter;
  final bool isAbstract;

  StarNode({
    required this.title,
    required this.position,
    required this.radius,
    required this.isCenter,
    this.isAbstract = false,
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
  List<StarNode> _nodes = [];

  void _calculateNodes(Size size) {
    _nodes.clear();
    final cx = size.width / 2;
    final cy = size.height / 2;
    final isTablet = size.width >= 768;

    final centerR = isTablet ? 18.0 : 15.0;

    _nodes.add(StarNode(
      title: widget.centerTitle,
      position: Offset(cx, cy),
      radius: centerR,
      isCenter: true,
    ));

    if (widget.items.isEmpty) return;

    final minDim = math.min(size.width, size.height);
    final count = widget.items.length;

    for (int i = 0; i < count; i++) {
      final item = widget.items[i];
      // 上位概念（抽象）は外周の軌道、具体は内側の軌道に配置
      final baseDist = minDim * (item.isAbstract ? (isTablet ? 0.44 : 0.42) : (isTablet ? 0.32 : 0.30));
      final rad = (i / count) * math.pi * 2;
      final offset = (i % 2 == 0 ? 1.0 : -1.0) * (minDim * 0.035);
      final dist = baseDist + offset;

      final x = cx + math.cos(rad) * dist;
      final y = cy + math.sin(rad) * dist;

      _nodes.add(StarNode(
        title: item.title,
        position: Offset(x, y),
        radius: item.isAbstract ? (isTablet ? 9.0 : 7.5) : (isTablet ? 7.0 : 5.5),
        isCenter: false,
        isAbstract: item.isAbstract,
      ));
    }
  }

  void _handleTap(Offset tapPos) {
    for (final node in _nodes) {
      if (node.isCenter) continue;

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
                Row(
                  children: [
                    Text(
                      '「${widget.centerTitle}」',
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '紫: 上位・背景 / 水色: 関連詳細',
                      style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                    ),
                  ],
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
                _calculateNodes(size);

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => _handleTap(details.localPosition),
                  child: CustomPaint(
                    size: size,
                    painter: ConstellationPainter(nodes: _nodes),
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

class ConstellationPainter extends CustomPainter {
  final List<StarNode> nodes;

  ConstellationPainter({required this.nodes});

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;

    final center = nodes.first;

    final linePaint = Paint()
      ..color = const Color(0xFF38BDF8).withValues(alpha: 0.20)
      ..strokeWidth = 1.0;

    final centerStarPaint = Paint()..color = const Color(0xFF38BDF8);
    final haloPaint = Paint()
      ..color = const Color(0xFF38BDF8).withValues(alpha: 0.20)
      ..style = PaintingStyle.fill;

    for (int i = 1; i < nodes.length; i++) {
      final node = nodes[i];
      canvas.drawLine(center.position, node.position, linePaint);

      final next = (i == nodes.length - 1) ? nodes[1] : nodes[i + 1];
      final perimeterPaint = Paint()
        ..color = const Color(0xFF94A3B8).withValues(alpha: 0.12)
        ..strokeWidth = 0.8;
      canvas.drawLine(node.position, next.position, perimeterPaint);
    }

    for (final node in nodes) {
      if (node.isCenter) {
        canvas.drawCircle(node.position, node.radius + 6, haloPaint);
        canvas.drawCircle(node.position, node.radius, centerStarPaint);
      } else {
        final starColor = node.isAbstract ? const Color(0xFFC084FC) : const Color(0xFFE0F2FE);
        final glowColor = node.isAbstract ? const Color(0xFFA855F7).withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.08);

        canvas.drawCircle(node.position, node.radius + 3, Paint()..color = glowColor);
        canvas.drawCircle(node.position, node.radius, Paint()..color = starColor);
      }

      final displayLabel = node.title.length > 9 ? '${node.title.substring(0, 8)}…' : node.title;

      final textSpan = TextSpan(
        text: displayLabel,
        style: TextStyle(
          color: node.isCenter
              ? const Color(0xFF38BDF8)
              : (node.isAbstract ? const Color(0xFFD8B4FE) : const Color(0xFFCBD5E1)),
          fontSize: node.isCenter ? 14 : 11,
          fontWeight: (node.isCenter || node.isAbstract) ? FontWeight.bold : FontWeight.normal,
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
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
