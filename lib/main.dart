import 'package:flutter/material.dart';
import 'services/diagnostics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/main_shell.dart';
import 'services/cf_session.dart';
import 'services/download_manager.dart';
import 'services/kwik_resolver.dart';
import 'services/image_session.dart';
import 'services/preview_data.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: PaheColors.surface,
  ));
  runApp(const ProviderScope(child: PaheCatApp()));
}

class PaheCatApp extends StatefulWidget {
  const PaheCatApp({super.key});

  @override
  State<PaheCatApp> createState() => _PaheCatAppState();
}

class _PaheCatAppState extends State<PaheCatApp> {
  bool _cfReady = false;

  /// Resolving a download link needs a WebView, which needs a widget tree, so
  /// the download manager cannot do it alone. It is handed a resolver bound to
  /// the app's own navigator instead.
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    DownloadManager().resolver = (url) {
      // The navigator's own overlay, not Overlay.of(its context): that
      // searches ancestors, and the overlay is a descendant of the navigator.
      final overlay = _navigatorKey.currentState?.overlay;
      if (overlay == null) {
        throw StateError('App is not ready to resolve links yet');
      }
      return KwikResolver.resolve(overlay, url);
    };
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Pahe Cat',
      theme: PaheTheme.theme,
      debugShowCheckedModeBanner: false,
      // The design preview has no Cloudflare to clear and no live API, so it
      // goes straight to the app rather than stalling on the handshake.
      home: PreviewMode.enabled
          ? const MainShell()
          : CfGatewayWidget(
              onReady: () {
                setState(() => _cfReady = true);
                Diagnostics.dumpPlayPage();
              },
              // The image host needs its own cleared page — see ImageSession.
              // Started only after the main session is ready, and kept below
              // the app's UI at full size, because a hidden or one-pixel
              // WebView gets throttled by the platform.
              child: _cfReady
                  ? const Stack(
                      children: [
                        Positioned.fill(child: ImageSessionHost()),
                        Positioned.fill(child: MainShell()),
                      ],
                    )
                  : const _SplashScreen(),
            ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PaheColors.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShaderMask(
              shaderCallback: (b) => PaheColors.gradient.createShader(b),
              child: const Text(
                'Pahe Cat',
                style: TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: -1,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Loading…',
              style: TextStyle(
                color: PaheColors.textMuted,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 160,
              child: LinearProgressIndicator(
                backgroundColor: PaheColors.border,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(PaheColors.accent),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
