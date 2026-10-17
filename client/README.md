# Hermes Mobile Surfaces: the Android app

The Flutter app of [Hermes Mobile Surfaces](../README.md): chat with Hermes, the Apps screen, tasks (cron jobs) and
settings. Install and connect it by following steps 3 to 5 of the main README.

The app started from [rusty4444/hermes-android](https://github.com/rusty4444/hermes-android) 2.1.19 (commit
`8f0edca2ea98`, MIT) and keeps its chat, sessions, voice, attachments, model selection and turn recovery.
[CHANGELOG.md](CHANGELOG.md) lists what this fork changed; below that entry is upstream's own history.

## What a connection gets

| Connection | Tabs |
|---|---|
| Only the Hermes Gateway API (no dashboard) | Chats · Apps · Tasks · More |
| With the Hermes dashboard and Projects | Home · Chats · Projects · Activity · More |

Files, Skills and Memory need the Hermes dashboard. Without it they are left out and More says why.

## Build

You need Flutter 3.44.0 (stable), JDK 17 and Android SDK platform 36.

```sh
flutter pub get
flutter build apk --release
```

Without a `key.properties` next to this file the release APK is signed with your machine's debug key, so it installs as
is. To sign with your own key create `key.properties` with `storeFile`, `storePassword`, `keyAlias` and `keyPassword`.
The application id is `dev.hermes.hermes_surfaces_example` (change it in `android/app/build.gradle.kts`). An update needs
the same id, the same key and a higher build number.

## Code

| Path | Contents |
|---|---|
| `lib/core/screens/` | Workspace shell, chat, tasks, settings, chat lists |
| `lib/core/widgets/` | Shell, panes, components, dialogs |
| `lib/core/services/` | Gateway clients, connection storage, notifications, the Apps binding (`native_apps.dart`) |
| `lib/l10n/` | Translations (`app_en.arb` is the template; other languages fall back to it for new texts) |
| `../packages/` | The Apps screen and the Surfaces core, consumed as path packages |

## Tests

```sh
flutter test
flutter analyze
```

They are synthetic (fake gateways and servers) and do not replace a run on a device.
