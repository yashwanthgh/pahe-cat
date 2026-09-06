import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/settings.dart';
import '../theme.dart';

const _repoUrl = 'https://github.com/yashwanthgh/pahe-cat';

/// Shown in the About row. Must match `version:` in pubspec.yaml and the
/// released tag, so a user reporting a problem names the build they have.
const kAppVersion = '0.3.3';

/// Every row here is wired to stored state. This screen was previously a
/// mock-up — hard-coded values and an empty `onTap` on each row — so none of
/// it did anything when tapped.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      backgroundColor: PaheColors.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Settings',
                style: TextStyle(
                  color: PaheColors.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 24),
              _Section(
                title: 'PLAYBACK',
                children: [
                  _SettingTile(
                    icon: Icons.hd_rounded,
                    title: 'Preferred quality',
                    subtitle: settings.preferredQuality,
                    onTap: () => _pickQuality(context, settings, notifier),
                  ),
                  _SettingTile(
                    icon: Icons.subtitles_rounded,
                    title: 'Preferred audio',
                    subtitle: settings.prefersDub
                        ? 'DUB (English)'
                        : 'SUB (Japanese)',
                    onTap: () => _pickAudio(context, settings, notifier),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'STORAGE',
                children: [
                  _SettingTile(
                    icon: Icons.folder_rounded,
                    title: 'Download location',
                    subtitle: settings.downloadDir.isEmpty
                        ? 'Default folder'
                        : settings.downloadDir,
                    onTap: () => _editDir(context, settings, notifier),
                  ),
                  _SettingTile(
                    icon: Icons.delete_sweep_rounded,
                    title: 'Reset site check',
                    subtitle: 'Clear cookies, cache and the saved domain',
                    onTap: () => _clearCache(context, notifier),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'ABOUT',
                children: [
                  const _SettingTile(
                    icon: Icons.info_outline_rounded,
                    title: 'Version',
                    subtitle: kAppVersion,
                    onTap: null,
                  ),
                  _SettingTile(
                    icon: Icons.code_rounded,
                    title: 'Source code',
                    subtitle: 'github.com/yashwanthgh/pahe-cat',
                    onTap: () => _open(_repoUrl),
                  ),
                  _SettingTile(
                    icon: Icons.gavel_rounded,
                    title: 'License',
                    subtitle: 'MIT License',
                    onTap: () => _open('$_repoUrl/blob/main/LICENSE'),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              Center(
                child: Column(
                  children: [
                    ShaderMask(
                      shaderCallback: (b) => PaheColors.gradient.createShader(b),
                      child: const Text(
                        'Pahe Cat',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Made with ♥ · MIT License',
                      style: TextStyle(color: PaheColors.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _pickQuality(
      BuildContext ctx, AppSettings s, SettingsNotifier n) async {
    final choice = await _choose(
      ctx,
      'Preferred quality',
      AppSettings.qualities,
      s.preferredQuality,
    );
    if (choice != null) await n.setQuality(choice);
  }

  Future<void> _pickAudio(
      BuildContext ctx, AppSettings s, SettingsNotifier n) async {
    final choice = await _choose(
      ctx,
      'Preferred audio',
      const ['SUB (Japanese)', 'DUB (English)'],
      s.prefersDub ? 'DUB (English)' : 'SUB (Japanese)',
    );
    if (choice != null) {
      await n.setAudio(choice.startsWith('DUB') ? 'eng' : 'jpn');
    }
  }

  /// Typed rather than picked from a browser: a native folder picker needs a
  /// plugin per platform, and this has to work on Android and desktop alike.
  Future<void> _editDir(
      BuildContext ctx, AppSettings s, SettingsNotifier n) async {
    final fallback = await resolveDownloadDir('');
    if (!ctx.mounted) return;
    final controller = TextEditingController(
        text: s.downloadDir.isEmpty ? fallback : s.downloadDir);

    final result = await showDialog<String>(
      context: ctx,
      builder: (c) => AlertDialog(
        backgroundColor: PaheColors.card,
        title: const Text('Download location',
            style: TextStyle(color: PaheColors.textPrimary, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: PaheColors.textPrimary, fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'Full path to a folder',
            hintStyle: TextStyle(color: PaheColors.textMuted, fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, ''),
            child: const Text('Use default'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) await n.setDownloadDir(result);
  }

  Future<void> _clearCache(BuildContext ctx, SettingsNotifier n) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        backgroundColor: PaheColors.card,
        title: const Text('Reset site check?',
            style: TextStyle(color: PaheColors.textPrimary, fontSize: 16)),
        content: const Text(
          'Clears cookies, cached pages and the saved domain. Your watch '
          'history and downloads are not touched. The check runs again next '
          'time the app starts.',
          style: TextStyle(color: PaheColors.textMuted, fontSize: 12),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    await n.clearWebCache();
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
      content: Text('Cleared. Restart the app to run the check again.'),
      backgroundColor: PaheColors.accent,
    ));
  }

  Future<String?> _choose(
      BuildContext ctx, String title, List<String> options, String current) {
    return showDialog<String>(
      context: ctx,
      builder: (c) => SimpleDialog(
        backgroundColor: PaheColors.card,
        title: Text(title,
            style: const TextStyle(
                color: PaheColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w800)),
        children: options
            .map((o) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(c, o),
                  child: Row(
                    children: [
                      Icon(
                        o == current
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 18,
                        color: o == current
                            ? PaheColors.accent
                            : PaheColors.textMuted,
                      ),
                      const SizedBox(width: 10),
                      Text(o,
                          style: const TextStyle(
                              color: PaheColors.textPrimary, fontSize: 13)),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: const TextStyle(
              color: PaheColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
        ),
        // Material, not a coloured Container: a ListTile paints its background
        // and ink splashes onto the nearest Material ancestor, so a plain
        // decorated box around them hides both.
        //
        // The outline goes through `shape` alone. Material asserts that only
        // one of `shape` and `borderRadius` describes it, and passing both
        // threw on every build of this screen.
        Material(
          color: PaheColors.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: PaheColors.border),
          ),
          child: Column(
            children: List.generate(children.length * 2 - 1, (i) {
              if (i.isOdd) {
                return const Divider(height: 1, indent: 52);
              }
              return children[i ~/ 2];
            }),
          ),
        ),
      ],
    );
  }
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  /// Null for rows that are information only, so they do not offer a tap that
  /// does nothing.
  final VoidCallback? onTap;

  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: PaheColors.accent.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: PaheColors.accentLight, size: 18),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: PaheColors.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: PaheColors.textMuted, fontSize: 11),
      ),
      trailing: onTap == null
          ? null
          : const Icon(Icons.chevron_right_rounded,
              color: PaheColors.textMuted, size: 18),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );
  }
}
