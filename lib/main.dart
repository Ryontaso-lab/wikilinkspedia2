import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_html/flutter_html.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
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
        cardColor: Colors.white,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        primaryColor: const Color(0xFF38BDF8),
        cardColor: const Color(0xFF1E293B),
      ),
      home: MainScreen(onToggleTheme: toggleTheme),
    );
  }
}

class MainScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  const MainScreen({super.key, required this.onToggleTheme});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  
  String _currentTitle = '読み込み中...';
  String _articleHtml = '<p>扉を開いています...</p>';
  bool _isLoading = false;

  final List<String> _history = [];
  int _currentHistoryIdx = -1;
  List<String> _starLinks = [];

  StreamSubscription? _intentSub;

  @override
  void initState() {
    super.initState();

    // 1. 共有メニューからテキストを受け取る（アプリ常駐時）
    _intentSub = ReceiveSharingIntent.instance.getTextStream().listen((String value) {
      _handleSharedText(value);
    }, onError: (err) {});

    // 2. 共有メニューから起動された時（初回起動時）
    ReceiveSharingIntent.instance.getInitialText().then((String? value) {
      if (value != null && value.isNotEmpty) {
        _handleSharedText(value);
      } else {
        _fetchRandomArticle();
      }
    });
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // 共有テキストから記事タイトルを抽出して開く
  void _handleSharedText(String text) {
    String title = '';
    final match = RegExp(r'wikipedia\.org/wiki/([^?#\s]+)').firstMatch(text);
    if (match != null && match.group(1) != null) {
      title = Uri.decodeComponent(match.group(1)!).replaceAll('_', ' ');
    } else {
      title = text.replaceAll(RegExp(r' - Wikipedia.*$'), '').trim();
    }

    if (title.isNotEmpty) {
      _loadArticle(title);
    }
  }

  // Wikipedia REST APIから記事取得
  Future<void> _loadArticle(String title, {bool addHistory = true}) async {
    if (title.isEmpty) return;

    setState(() {
      _isLoading = true;
      _currentTitle = title;
      _articleHtml = '<p style="color:gray;">記事を取得しています...</p>';
    });

    final rawTitle = title.replaceAll(' ', '_');
    final url = Uri.parse('https://ja.wikipedia.org/api/rest_v1/page/html/${Uri.encodeComponent(rawTitle)}');

    try {
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final html = res.body;

        if (addHistory) {
          _history.add(title);
          _currentHistoryIdx = _history.length - 1;
        }

        _extractStarLinks(html);

        setState(() {
          _articleHtml = html;
          _isLoading = false;
        });

        // ページ上部へスクロール
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.jumpTo(0);
        }
      } else {
        throw Exception();
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _articleHtml = '<p style="color:red; font-weight:bold;">記事の取得に失敗しました</p>';
      });
    }
  }

  // 記事内の内部リンクを星座用リストとして抽出
  void _extractStarLinks(String html) {
    final matches = RegExp(r'href="\./([^"#?:]+)"').allMatches(html);
    final Set<String> titles = {};
    for (var m in matches) {
      if (m.group(1) != null) {
        titles.add(Uri.decodeComponent(m.group(1)!).replaceAll('_', ' '));
      }
    }
    _starLinks = titles.take(20).toList();
  }

  // ランダム記事取得
  Future<void> _fetchRandomArticle() async {
    try {
      final res = await http.get(Uri.parse('https://ja.wikipedia.org/api/rest_v1/page/random/title'));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final title = data['items'][0]['title'].toString().replaceAll('_', ' ');
        _loadArticle(title);
        return;
      }
    } catch (_) {}
    _loadArticle('富士山');
  }

  // 星座モーダル表示
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
        titleSpacing: 8,
        title: TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: 'キーワード (例: 日本, 富士山)',
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
            icon: const Icon(Icons.brightness_medium),
            onPressed: widget.onToggleTheme,
          ),
        ],
      ),
      body: Row(
        children: [
          // タブレット用：左サイドバー（探索ログ）
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
                  return ListTile(
                    dense: true,
                    title: Text(
                      '${i + 1}. ${_history[i]}',
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? Theme.of(context).primaryColor : null,
                      ),
                    ),
                    onTap: () {
                      _currentHistoryIdx = i;
                      _loadArticle(_history[i], addHistory: false);
                    },
                  );
                },
              ),
            ),

          // 右メインコンテンツ
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(20),
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 960),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _currentTitle,
                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                      ),
                      const Divider(height: 32),
                      Html(
                        data: _articleHtml,
                        onLinkTap: (url, _, __) {
                          if (url != null) {
                            if (url.startsWith('./') || url.contains('/wiki/')) {
                              final raw = url.split('/wiki/').last.replaceAll('./', '');
                              final clean = Uri.decodeComponent(raw.split('#').first);
                              _loadArticle(clean);
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------
// 静止型星座マップモーダル
// ----------------------------------------------------
class ConstellationModal extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Color(0xFF0B0F19),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '星座マップ: $centerTitle',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: ConstellationPainter(centerTitle: centerTitle, links: links),
            ),
          ),
          // 下部に星一覧ボタンを配置（タップ確実化）
          SizedBox(
            height: 70,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: links.length,
              itemBuilder: (ctx, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E293B),
                    foregroundColor: const Color(0xFF38BDF8),
                  ),
                  onPressed: () => onSelectNode(links[i]),
                  child: Text(links[i]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ConstellationPainter extends CustomPainter {
  final String centerTitle;
  final List<String> links;

  ConstellationPainter({required this.centerTitle, required this.links});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final centerOffset = Offset(cx, cy);

    final linePaint = Paint()
      ..color = const Color(0xFF38BDF8).withValues(alpha: 0.25)
      ..strokeWidth = 1.0;

    final starPaint = Paint()..color = const Color(0xFFE0F2FE);
    final centerStarPaint = Paint()..color = const Color(0xFF38BDF8);

    // 中心星
    canvas.drawCircle(centerOffset, 16, centerStarPaint);

    if (links.isEmpty) return;

    final radius = math.min(size.width, size.height) * 0.36;
    final count = links.length;

    for (int i = 0; i < count; i++) {
      final rad = (i / count) * math.PI * 2;
      final x = cx + math.cos(rad) * radius;
      final y = cy + math.sin(rad) * radius;
      final nodeOffset = Offset(x, y);

      // 中心からの連結線
      canvas.drawLine(centerOffset, nodeOffset, linePaint);

      // 周囲の星
      canvas.drawCircle(nodeOffset, 6, starPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
