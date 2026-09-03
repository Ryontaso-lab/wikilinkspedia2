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

// 探索ログ管理用クラス（記事名とスクロール位置をセットで保持）
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
  List<String> _starLinks = [];
  int _targetRestoreScrollY = 0; // 復元用スクロール目標値

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

            // 復元先のスクロール位置が指定されていればスクロール
            if (_targetRestoreScrollY > 0) {
              final y = _targetRestoreScrollY;
              _targetRestoreScrollY = 0;
              // 描画安定を待ってからスクロール
              Future.delayed(const Duration(milliseconds: 150), () {
                _webCtrl.runJavaScript('window.scrollTo({top: $y, behavior: "smooth"});');
              });
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

  // 現在の閲覧位置を退避してから記事を切り替える
  Future<void> _loadArticle(String title, {bool addHistory = true, int restoreScrollY = 0}) async {
    if (title.isEmpty) return;

    // 現在閲覧中の記事があればスクロール位置を取得して履歴に保存
    if (_currentHistoryIdx >= 0 && _currentHistoryIdx < _history.length) {
      try {
        final currentScrollOffset = await _webCtrl.getScrollPosition();
        _history[_currentHistoryIdx].scrollY = currentScrollOffset.dy.toInt();
      } catch (_) {}
    }

    setState(() {
      _currentTitle = title;
      _targetRestoreScrollY = restoreScrollY;
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

    _fetchStarLinksFromApi(title);
  }

  Future<void> _fetchStarLinksFromApi(String title) async {
    try {
      final apiUrl = Uri.parse(
        'https://ja.wikipedia.org/w/api.php?action=query&prop=links&plnamespace=0&pllimit=150&format=json&titles=${Uri.encodeComponent(title)}'
      );
      final res = await http.get(apiUrl, headers: _apiHeaders);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final pages = data['query']?['pages'] as Map<String, dynamic>?;
        if (pages != null && pages.isNotEmpty) {
          final firstPage = pages.values.first;
          final linksList = firstPage['links'] as List<dynamic>?;
          if (linksList != null) {
            int dateCount = 0;
            final List<String> result = [];

            for (final item in linksList) {
              final t = item['title'].toString();
              if (t.contains(':') || t.endsWith('の一覧') || t.contains('(曖昧さ回避)')) {
                continue;
              }

              final isPureDate = RegExp(r'^\d+年$').hasMatch(t) ||
                  RegExp(r'^\d+月\d+日$').hasMatch(t) ||
                  RegExp(r'^(明治|大正|昭和|平成|令和)\d+年?$').hasMatch(t) ||
                  RegExp(r'紀元前\d+年?').hasMatch(t);

              if (isPureDate) {
                if (dateCount < 3) {
                  result.add(t);
                  dateCount++;
                }
              } else {
                result.add(t);
              }

              if (result.length >= 20) break;
            }

            setState(() {
              _starLinks = result;
            });
          }
        }
      }
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

    const fallbacks = ['宇宙', '深海', 'ピラミッド', '量子力学', 'オーロラ', 'アンモナイト', '人工知能'];
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
        links: _starLinks,
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
          // 左サイドバー（探索ログ）
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
                      // 履歴からの復元時は addHistory: false かつ以前の scrollY を渡す
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
// 星座マップ（星・直下ラベル直タップ対応）
// ----------------------------------------------------
class StarNode {
  final String title;
  final Offset position;
  final double radius;
  final bool isCenter;

  StarNode({
    required this.title,
    required this.position,
    required this.radius,
    required this.isCenter,
  });
}

class ConstellationModal extends StatefulWidget {
  final String centerTitle;
  final List<String> links;
  final Function(String) onSelectNode;

  const ConstellationModal({
    super.key,
    required this.centerTitle,
    required this.links,
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
    final starR = isTablet ? 8.0 : 6.0;

    _nodes.add(StarNode(
      title: widget.centerTitle,
      position: Offset(cx, cy),
      radius: centerR,
      isCenter: true,
    ));

    if (widget.links.isEmpty) return;

    final minDim = math.min(size.width, size.height);
    final baseDist = minDim * (isTablet ? 0.38 : 0.36);
    final count = widget.links.length;

    for (int i = 0; i < count; i++) {
      final rad = (i / count) * math.pi * 2;
      final offset = (i % 2 == 0 ? 1.0 : -1.0) * (minDim * 0.05);
      final dist = baseDist + offset;

      final x = cx + math.cos(rad) * dist;
      final y = cy + math.sin(rad) * dist;

      _nodes.add(StarNode(
        title: widget.links[i],
        position: Offset(x, y),
        radius: starR,
        isCenter: false,
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
                      '(星や文字をタップして移動)',
                      style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
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
      ..color = const Color(0xFF38BDF8).withValues(alpha: 0.25)
      ..strokeWidth = 1.0;

    final starPaint = Paint()..color = const Color(0xFFE0F2FE);
    final centerStarPaint = Paint()..color = const Color(0xFF38BDF8);
    final haloPaint = Paint()
      ..color = const Color(0xFF38BDF8).withValues(alpha: 0.20)
      ..style = PaintingStyle.fill;

    for (int i = 1; i < nodes.length; i++) {
      final node = nodes[i];
      canvas.drawLine(center.position, node.position, linePaint);

      final next = (i == nodes.length - 1) ? nodes[1] : nodes[i + 1];
      final perimeterPaint = Paint()
        ..color = const Color(0xFF94A3B8).withValues(alpha: 0.15)
        ..strokeWidth = 0.8;
      canvas.drawLine(node.position, next.position, perimeterPaint);
    }

    for (final node in nodes) {
      if (node.isCenter) {
        canvas.drawCircle(node.position, node.radius + 6, haloPaint);
        canvas.drawCircle(node.position, node.radius, centerStarPaint);
      } else {
        canvas.drawCircle(
          node.position,
          node.radius + 3,
          Paint()..color = Colors.white.withValues(alpha: 0.08),
        );
        canvas.drawCircle(node.position, node.radius, starPaint);
      }

      final displayLabel = node.title.length > 9 ? '${node.title.substring(0, 8)}…' : node.title;

      final textSpan = TextSpan(
        text: displayLabel,
        style: TextStyle(
          color: node.isCenter ? const Color(0xFF38BDF8) : const Color(0xFFCBD5E1),
          fontSize: node.isCenter ? 14 : 12,
          fontWeight: node.isCenter ? FontWeight.bold : FontWeight.normal,
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
