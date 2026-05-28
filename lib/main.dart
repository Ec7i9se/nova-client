import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  // WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nova',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const String _initialUrl = 'https://demo.footy.gg';

  late final WebViewController _controller;
  String? _loadError;
  String? _authToken;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    );
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setOnConsoleMessage((JavaScriptConsoleMessage message) {
        // print('onConsoleMessage: ${message.message}');
      })
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            print('onPageStarted: $url');
            if (mounted) setState(() => _loadError = null);
          },
          onPageFinished: (String url) {
            print('onPageFinished: $url');
            if (mounted) setState(() => _loadError = null);
            _saveCookiesToFile(url);
            _readAuthToken();
          },
          onWebResourceError: (WebResourceError error) {
            print('onWebResourceError: ${error.description}');
            if (mounted && (error.isForMainFrame ?? false)) {
              setState(() {
                _loadError = error.description.isNotEmpty
                    ? error.description
                    : 'Failed to load page (${error.errorCode})';
              });
            }
          },
          onHttpError: (HttpResponseError error) {
            print('onHttpError: ${error.toString()}');
          },
        ),
      );
    _loadWithSavedCookies();
  }

  Future<void> _loadWithSavedCookies() async {
    final uri = Uri.parse(_initialUrl);
    await _applySavedCookies(uri);
    if (!mounted) return;
    _controller.loadRequest(uri);
  }

  Future<void> _applySavedCookies(Uri targetUri) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/cookies.txt');
      if (!await file.exists()) return;
      final content = await file.readAsString();
      final cookieSection = content.contains('\n\n')
          ? content.split('\n\n').last.trim()
          : content;
      if (cookieSection.isEmpty) return;
      final domain = targetUri.host;
      for (final raw in cookieSection.split('; ')) {
        final part = raw.trim();
        if (part.isEmpty) continue;
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        final name = part.substring(0, eq).trim();
        final value = part.substring(eq + 1).trim();
        if (name.isEmpty) continue;
        final cookie = WebViewCookie(
          name: name,
          value: value,
          domain: domain,
        );
        await _cookieManager.setCookie(cookie);
      }
      if (mounted) debugPrint('Applied saved cookies for $domain');
    } catch (e) {
      debugPrint('Failed to apply saved cookies: $e');
    }
  }

  void _retry() {
    setState(() => _loadError = null);
    _applySavedCookies(Uri.parse(_initialUrl)).then((_) {
      if (mounted) _controller.loadRequest(Uri.parse(_initialUrl));
    });
  }

  Future<void> _readAuthToken() async {
    const key = 'sb-xsrwligqdlmkyqdsczru-auth-token';
    try {
      final result = await _controller.runJavaScriptReturningResult(
        "localStorage.getItem('$key') || ''",
      );
      final raw = result is String ? result : result.toString();
      // runJavaScriptReturningResult wraps strings in quotes on some platforms
      final json = raw.replaceAll(RegExp(r'^"|"$'), '').trim();
      if (json.isEmpty) return;

      print(json);
      if (mounted) setState(() => _authToken = json);

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/authtoken.json');
      await file.writeAsString(json);
      debugPrint('Auth token saved to ${file.path}');
    } catch (e) {
      debugPrint('Failed to read auth token: $e');
    }
  }

  Future<void> _saveCookiesToFile(String pageUrl) async {
    try {
      final result = await _controller.runJavaScriptReturningResult(
        "document.cookie || ''",
      );
      print('result: $result');
      final cookieString = result is String ? result : result.toString();
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/cookies.txt');
      await file.writeAsString(
        'Saved: ${DateTime.now().toIso8601String()}\nURL: $pageUrl\n\n$cookieString',
      );
      if (mounted) debugPrint('Cookies saved to ${file.path}');
    } catch (e) {
      debugPrint('Failed to save cookies: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return Scaffold(
        backgroundColor: Color(0xFF0e1020),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 64, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text(
                  'Unable to load page',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _loadError!,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Color(0xFF0e1020),
      body: SafeArea(
        child: WebViewWidget(controller: _controller)
        ),
    );
  }
}
