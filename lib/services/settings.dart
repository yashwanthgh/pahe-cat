import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User preferences, persisted locally.
///
/// The settings screen used to be a mock-up — every row had an empty `onTap`
/// and a hard-coded value — so nothing on it did anything. These are the real
/// stored values behind it.
@immutable
class AppSettings {
  /// Pre-selected on the source picker when the episode offers it.
  final String preferredQuality;

  /// 'jpn' for subtitled, 'eng' for dubbed.
  final String preferredAudio;

  /// Where downloads are written. Empty means "use the platform default".
  final String downloadDir;

  const AppSettings({
    this.preferredQuality = '720p',
    this.preferredAudio = 'jpn',
    this.downloadDir = '',
  });

  bool get prefersDub => preferredAudio == 'eng';

  AppSettings copyWith({
    String? preferredQuality,
    String? preferredAudio,
    String? downloadDir,
  }) =>
      AppSettings(
        preferredQuality: preferredQuality ?? this.preferredQuality,
        preferredAudio: preferredAudio ?? this.preferredAudio,
        downloadDir: downloadDir ?? this.downloadDir,
      );

  static const qualities = ['1080p', '720p', '360p'];
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(const AppSettings()) {
    _load();
  }

  static const _kQuality = 'pref_quality';
  static const _kAudio = 'pref_audio';
  static const _kDir = 'pref_download_dir';

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    state = AppSettings(
      preferredQuality: p.getString(_kQuality) ?? '720p',
      preferredAudio: p.getString(_kAudio) ?? 'jpn',
      downloadDir: p.getString(_kDir) ?? '',
    );
  }

  Future<void> setQuality(String q) async {
    state = state.copyWith(preferredQuality: q);
    (await SharedPreferences.getInstance()).setString(_kQuality, q);
  }

  Future<void> setAudio(String a) async {
    state = state.copyWith(preferredAudio: a);
    (await SharedPreferences.getInstance()).setString(_kAudio, a);
  }

  Future<void> setDownloadDir(String dir) async {
    state = state.copyWith(downloadDir: dir);
    (await SharedPreferences.getInstance()).setString(_kDir, dir);
  }

  /// Clears the Cloudflare clearance and cached pages.
  ///
  /// Useful when the site's protection changes and a stale clearance is being
  /// rejected — the next launch then starts the check from scratch.
  Future<void> clearWebCache() async {
    await CookieManager.instance().deleteAllCookies();
    await InAppWebViewController.clearAllCache();
    final p = await SharedPreferences.getInstance();
    await p.remove('resolved_domain');
    await p.remove('resolved_domain_at');
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((_) => SettingsNotifier());

/// The effective download directory: the configured one, else the platform
/// default. Shared with [DownloadManager] so both agree on one location.
Future<String> resolveDownloadDir(String configured) async {
  if (configured.isNotEmpty) return configured;
  if (Platform.isAndroid) {
    final dir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    return '${dir.path}/Pahe Cat';
  }
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      (await getApplicationDocumentsDirectory()).path;
  return '$home/Downloads/Pahe Cat';
}
