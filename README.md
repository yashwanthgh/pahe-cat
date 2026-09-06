# Pahe Boy

AnimePahe client for all platforms. Watch progress, sub/dub selection, multi-quality downloads.

## Features

- Browse & search animepahe.ru
- Sub / Dub selection per episode
- Quality picker (360p / 720p / 1080p)
- Watch progress tracking (no login needed — stored locally)
- Download episodes to your device
- Works on Android, macOS, Windows, Linux

## Install

Download the latest release from [GitHub Releases](https://github.com/yugnasura/pahe-boy/releases).

| Platform | File |
|----------|------|
| Android | `PaheBoy-arm64-v8a-release.apk` |
| macOS | `PaheBoy-macOS.zip` |
| Windows | `PaheBoy-Windows.zip` |
| Linux | `PaheBoy-Linux.tar.gz` |

## Build from Source

```bash
# Install Flutter: https://flutter.dev/docs/get-started/install
flutter pub get
flutter run          # debug
flutter build apk    # Android APK
flutter build macos  # macOS
flutter build windows # Windows
flutter build linux  # Linux
```

## How it works

1. On first launch an invisible WebView loads animepahe.ru and solves the Cloudflare challenge
2. Cookies are stored in memory and used for all subsequent API calls
3. Episode streams go through kwik.si — resolved via a hidden WebView POST
4. Downloads are concurrent (2 at a time) with resume support

## License

MIT © Yashwanth GH
