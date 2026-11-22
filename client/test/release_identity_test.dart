import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Build 0.2.0 has the exact release identity and an upgrade-safe code',
    () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match = RegExp(
        r'^version:\s*([^\s+]+)\+(\d+)\s*$',
        multiLine: true,
      ).firstMatch(pubspec);

      expect(match, isNotNull);
      expect(match!.group(1), '0.2.0');
      expect(int.parse(match.group(2)!), 2163);
      // Version codes only determine upgrades within the same application ID.
      expect(int.parse(match.group(2)!), greaterThan(2162));
      // F-Droid ABI split: packaged arm64 code is base * 10 + ABI code.
      expect(int.parse(match.group(2)!) * 10 + 2, 21632);
    },
  );

  test('release and debug use the intended separate application IDs', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('applicationId = "dev.hermes.hermes_surfaces"'));
    expect(gradle, contains('applicationIdSuffix = ".dev"'));
    expect(
      gradle,
      isNot(contains('applicationId = "dev.hermes.hermes_surfaces_example"')),
    );
  });

  test('Gradle enforces the accepted APK upgrade floor', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('minimumInstalledVersionCode = 2127'));
    expect(
      gradle,
      contains('check(flutter.versionCode > minimumInstalledVersionCode)'),
    );
    // F-Droid ABI-split version-code scheme: base * 10 + abiCode.
    expect(
      gradle,
      contains('mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)'),
    );
    expect(gradle, contains('variant.versionCode * 10 + abiVersionCode'));
  });
}
