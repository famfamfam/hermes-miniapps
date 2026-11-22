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
The application id is `dev.hermes.hermes_surfaces` (set in `android/app/build.gradle.kts`). An update needs the same id,
the same key and a higher build number. Older releases use `dev.hermes.hermes_surfaces_example` and remain separate apps:
Android does not transfer their data automatically. An encrypted configuration backup can transfer saved connections,
but not the Surfaces association or approval key. Keep the old app installed and paired until approval access is restored.

OneSignal is optional. In notification settings, enter your OneSignal App ID and restart the app; the ID is stored
on the device. The Subscription ID is shown there when registration completes and can be copied explicitly.
A custom APK can instead provide a default at build time:

```sh
flutter build apk --release --dart-define=ONESIGNAL_APP_ID=your-onesignal-app-id
```

The saved App ID takes precedence; clearing it restores the build default. Configure the matching Android application in
Firebase and OneSignal first. An app ID is not a REST API key;
never put the REST API key or a Firebase service-account key in the app. This enables device registration and
receiving push notifications; it does not send cron notifications by itself.

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
