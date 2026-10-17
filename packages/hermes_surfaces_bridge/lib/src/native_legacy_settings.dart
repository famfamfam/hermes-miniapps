import 'dart:convert';
import 'dart:io';

import 'native_association_controller.dart' show NativeAssociationSettings;

/// Read-only parser for the example application's own global `settings.json`
/// (`{url, token, deviceId, strictNetworkBlock?, sealNetwork?}`) in [directory].
///
/// Pass it ONLY as the dialog's `legacyPrefill` (the dialog calls it after a separate explicit
/// consent). It never runs at startup/selection/open, never writes, rewrites, deletes or
/// generates anything (no device ID, key, seed or root settings), and never adopts a legacy cache.
/// Returns null when the file is absent. A present but unreadable/misshapen file throws a
/// [FormatException] with a fixed message that never echoes file content.
Future<NativeAssociationSettings?> readLegacyExampleSettings(Directory directory) async {
  final file = File('${directory.path}/settings.json');
  if (!await file.exists()) return null;
  try {
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) throw const FormatException();
    final url = json['url'];
    final token = json['token'];
    final deviceId = json['deviceId'];
    final strict = json['strictNetworkBlock'] ?? true;
    final seal = json['sealNetwork'] ?? true;
    if (url is! String || token is! String || deviceId is! String || strict is! bool || seal is! bool) {
      throw const FormatException();
    }
    return NativeAssociationSettings(
      baseUri: Uri.parse(url),
      bearer: token,
      deviceId: deviceId,
      strictNetworkBlock: strict,
      sealNetwork: seal,
    );
  } catch (_) {
    throw const FormatException('Legacy Surfaces settings are unreadable');
  }
}
