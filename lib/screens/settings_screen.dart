import 'package:flutter/material.dart';
import '../theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
                    title: 'Default Quality',
                    subtitle: '720p',
                    onTap: () {},
                  ),
                  _SettingTile(
                    icon: Icons.subtitles_rounded,
                    title: 'Default Audio',
                    subtitle: 'SUB (Japanese)',
                    onTap: () {},
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'STORAGE',
                children: [
                  _SettingTile(
                    icon: Icons.folder_rounded,
                    title: 'Download Location',
                    subtitle: 'Desktop/Pahe Boy',
                    onTap: () {},
                  ),
                  _SettingTile(
                    icon: Icons.delete_sweep_rounded,
                    title: 'Clear Cache',
                    subtitle: 'Free up CF session data',
                    onTap: () {},
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _Section(
                title: 'ABOUT',
                children: [
                  _SettingTile(
                    icon: Icons.info_outline_rounded,
                    title: 'Version',
                    subtitle: '1.0.0',
                    onTap: () {},
                  ),
                  _SettingTile(
                    icon: Icons.code_rounded,
                    title: 'Source Code',
                    subtitle: 'github.com/yugnasura/pahe-boy',
                    onTap: () {},
                  ),
                  _SettingTile(
                    icon: Icons.gavel_rounded,
                    title: 'License',
                    subtitle: 'MIT License',
                    onTap: () {},
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
                        'Pahe Boy',
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
        Container(
          decoration: BoxDecoration(
            color: PaheColors.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: PaheColors.border),
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
  final VoidCallback onTap;

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
          color: PaheColors.purple.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: PaheColors.purpleLight, size: 18),
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
        style: const TextStyle(color: PaheColors.textMuted, fontSize: 11),
      ),
      trailing: const Icon(Icons.chevron_right_rounded,
          color: PaheColors.textMuted, size: 18),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );
  }
}
