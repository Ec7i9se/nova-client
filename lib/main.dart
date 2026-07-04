import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nova/firebase_options.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
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

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  static const String _baseUrl = 'https://novagame.io';
  static const String _initialUrl = '$_baseUrl/login';
  static const String _supabaseAuthTokenKey = 'sb-xsrwligqdlmkyqdsczru-auth-token';

  late final WebViewController _controller;
  String? _loadError;
  String? _authToken;
  bool _hasNotificationPermission = false;
  bool _isRegisteringPushToken = false;
  String? _lastRegisteredFcmToken;
  StreamSubscription<String>? _tokenRefreshSubscription;
  Timer? _authTokenPollTimer;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
            _startAuthTokenPolling();
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
    _tokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh.listen(
      (String token) => _tryRegisterPushToken(fcmToken: token, reason: 'token refresh'),
      onError: (Object error) {
        debugPrint('FCM token refresh failed: $error');
      },
    );
    _requestNotificationPermission();
    _startAuthTokenPolling();
    _loadWithSavedCookies();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tokenRefreshSubscription?.cancel();
    _authTokenPollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _readAuthToken();
      _startAuthTokenPolling();
      _tryRegisterPushToken(reason: 'app resumed');
    }
  }

  Future<void> _requestNotificationPermission() async {
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    debugPrint('Notification permission: ${settings.authorizationStatus}');
    _hasNotificationPermission = _isNotificationPermissionGranted(settings);
    if (_hasNotificationPermission) {
      await _tryRegisterPushToken(reason: 'permission granted');
    }
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
    _startAuthTokenPolling();
  }

  void _startAuthTokenPolling() {
    _authTokenPollTimer?.cancel();

    var attempts = 0;
    _authTokenPollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      attempts += 1;
      await _readAuthToken();
      await _tryRegisterPushToken(reason: 'auth token polling');

      if (_lastRegisteredFcmToken != null || attempts >= 60) {
        timer.cancel();
        if (identical(_authTokenPollTimer, timer)) {
          _authTokenPollTimer = null;
        }
      }
    });
  }

  bool _isNotificationPermissionGranted(NotificationSettings settings) {
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  String _currentPlatform() {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  String _normalizeJavaScriptStringResult(Object? result) {
    var raw = result is String ? result : result?.toString() ?? '';
    raw = raw.trim();

    for (var i = 0; i < 2; i += 1) {
      if (raw.isEmpty || raw == 'null' || raw == 'undefined') return '';
      try {
        final decoded = jsonDecode(raw);
        if (decoded is String) {
          raw = decoded.trim();
          continue;
        }
      } catch (_) {
        // Some WebView implementations return the raw string, not JSON.
      }
      break;
    }

    return raw.replaceAll(RegExp(r'^"|"$'), '').trim();
  }

  String? _extractAccessToken(String authTokenJson) {
    try {
      final decoded = jsonDecode(authTokenJson);
      if (decoded is Map<String, dynamic>) {
        final accessToken = decoded['access_token'];
        if (accessToken is String && accessToken.isNotEmpty) return accessToken;
      }
    } catch (e) {
      debugPrint('Failed to parse auth token: $e');
    }
    return null;
  }

  Future<void> _readAuthToken() async {
    try {
      final result = await _controller.runJavaScriptReturningResult(
        "localStorage.getItem('$_supabaseAuthTokenKey') || ''",
      );
      final jsonStr = _normalizeJavaScriptStringResult(result);
      if (jsonStr.isEmpty) return;

      if (_authToken != jsonStr) {
        _lastRegisteredFcmToken = null;
      }
      if (mounted) setState(() => _authToken = jsonStr);

      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/authtoken.json');
      await file.writeAsString(jsonStr);
      debugPrint('Auth token saved to ${file.path}');

      await _tryRegisterPushToken(reason: 'auth token read');
    } catch (e) {
      debugPrint('Failed to read auth token: $e');
    }
  }

  Future<void> _tryRegisterPushToken({String? fcmToken, String reason = 'manual'}) async {
    if (_isRegisteringPushToken) return;

    final authToken = _authToken;
    if (authToken == null || authToken.isEmpty) {
      debugPrint('Skipping FCM registration ($reason): auth token is not ready');
      return;
    }

    final accessToken = _extractAccessToken(authToken);
    if (accessToken == null || accessToken.isEmpty) {
      debugPrint('Skipping FCM registration ($reason): access token is missing');
      return;
    }

    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    _hasNotificationPermission = _isNotificationPermissionGranted(settings);
    if (!_hasNotificationPermission) {
      debugPrint('Skipping FCM registration ($reason): notification permission is not granted');
      return;
    }

    _isRegisteringPushToken = true;
    try {
      if (Platform.isIOS) {
        final apnsToken = await FirebaseMessaging.instance.getAPNSToken();
        if (apnsToken == null) {
          debugPrint('Skipping FCM registration ($reason): APNS token is not available yet');
          return;
        }
      }

      final token = fcmToken ?? await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) {
        debugPrint('FCM token not available');
        return;
      }
      if (_lastRegisteredFcmToken == token) {
        debugPrint('FCM token already registered ($reason)');
        return;
      }

      final uri = Uri.parse('$_baseUrl/api/push/token');
      final client = HttpClient();
      try {
        final request = await client.postUrl(uri);
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
        request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        request.write(jsonEncode({
          'token': token,
          'platform': _currentPlatform(),
        }));

        final response = await request.close();
        final responseBody = await utf8.decodeStream(response);
        debugPrint('FCM token registration ($reason) status: ${response.statusCode}');

        if (response.statusCode >= 200 && response.statusCode < 300) {
          _lastRegisteredFcmToken = token;
        } else {
          debugPrint('FCM token registration failed: $responseBody');
        }
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      debugPrint('Failed to send FCM token: $e');
    } finally {
      _isRegisteringPushToken = false;
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
