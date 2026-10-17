import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'api.dart';
import 'bridge.dart';
import 'bundle_store.dart';
import 'host.dart';
import 'strings.dart';

/// Largest file the phone sends (the server's own limit; checked here first so nothing is read for nothing).
const int maxUploadBytes = 20 * 1024 * 1024;

/// Path under the app's own origin where the host answers with a stored picture, so a page can show one with a
/// plain `<img>` (the content policy allows images from the page's own origin only).
const String filesPathPrefix = '__hermes/files/';

/// A file the user chose in the system picker. The bytes are read from [open] once, while uploading.
class PickedFile {
  PickedFile({required this.name, required this.length, required this.open});
  final String name;
  final int length;
  final Stream<List<int>> Function() open;
}

/// What the user did with a file offered to them.
enum FileOfferResult { saved, opened, shared, cancelled }

/// The native pieces of file handling, supplied by the application: the package itself depends on no picker,
/// no share sheet and no viewer. Each method is the user's own act (a picker they choose in, a sheet they tap);
/// nothing here runs because a page asked silently.
abstract class HostFileActions {
  /// The system file picker, limited to [accept] (media types such as `image/*`; empty = any). Null: cancelled.
  Future<PickedFile?> pick(BuildContext context, {required List<String> accept});

  /// Offer a received file: save it, open it, share it. Returns what the user chose.
  Future<FileOfferResult> offer(BuildContext context,
      {required String name, required String mime, required Uint8List bytes});
}

/// Hands a message to Hermes as the user's own: opens a chat and sends it. False when that was not possible.
typedef SendToHermes = Future<bool> Function(String text);

const Set<String> _imageMimes = {'image/png', 'image/jpeg', 'image/webp', 'image/gif'};

/// The answers to the file operations of the page bridge (`pickFile`, `saveFile`, ...) and to its picture requests.
/// The page names what it wants (a locator and typed arguments, a file id it was given); this class never takes a
/// path, an address or a token from it, goes to the server through [SurfacesApi], and puts every effect behind a
/// step the user takes.
class FileBridge {
  FileBridge({
    required this.actions,
    required this.sendToHermes,
    required this.preview,
    required this.timezone,
    this.imageCacheBytes = 12 * 1024 * 1024,
  });

  final HostFileActions? actions;
  final SendToHermes? sendToHermes;

  /// A build under review: only looked at, so nothing is moved or sent.
  final bool preview;
  final String Function() timezone;
  final int imageCacheBytes;

  final Map<String, ({Uint8List bytes, String mime})> _images = {};
  int _imageBytes = 0;

  HostError _blocked(SurfacesText key, String message, [String code = 'unsupported']) =>
      HostError(code, message, key: key);

  /// Runs one file operation of an already accepted bridge request.
  Future<Object?> handle(
    BridgeRequest req, {
    required SurfacesHost host,
    required InstalledApp app,
    required String title,
    required BuildContext context,
  }) async {
    if (preview) throw _blocked(SurfacesText.filePreviewBlocked, 'Files are off in a preview', 'preview_blocked');
    // A host without the application's pickers moves no file at all, not even to list them.
    if (req.op != 'askHermes') _needActions();
    switch (req.op) {
      case 'pickFile':
        return _pick(req, host, app, context);
      case 'listFiles':
        final files = await _guard(() => host.api.listFiles(app.appId));
        return {'files': [for (final f in files) f.toJson()]};
      case 'deleteFile':
        return _delete(req, host, app, context);
      case 'saveFile':
        return _save(req, host, app, context);
      case 'askHermes':
        return _ask(req, host, app, title, context);
    }
    throw HostError('unknown_op', req.op);
  }

  HostFileActions _needActions() =>
      actions ?? (throw _blocked(SurfacesText.fileUnsupported, 'This host cannot move files'));

  Future<Object?> _pick(BridgeRequest req, SurfacesHost host, InstalledApp app, BuildContext context) async {
    final a = _needActions();
    final picked = await a.pick(context, accept: List<String>.from(req.args['accept'] as List));
    if (picked == null) return null;
    if (picked.length <= 0) throw _blocked(SurfacesText.fileEmpty, 'The file is empty', 'bad_file');
    if (picked.length > maxUploadBytes) throw _blocked(SurfacesText.fileTooLarge, 'The file is too large', 'too_large');
    final stored = await _guard(
      () => host.api.uploadFile(app.appId, name: picked.name, bytes: picked.open(), length: picked.length),
    );
    return stored.toJson();
  }

  Future<Object?> _save(BridgeRequest req, SurfacesHost host, InstalledApp app, BuildContext context) async {
    final a = _needActions();
    final fileId = req.args['fileId'] as String?;
    final DownloadedFile file = await _guard(() => fileId != null
        ? host.api.downloadStored(app.appId, fileId)
        : host.api.downloadNamed(
            app.appId,
            app.revision,
            req.args['name'] as String,
            Map<String, dynamic>.from(req.args['args'] as Map),
            timezone: timezone(),
          ));
    if (!context.mounted) return {'action': FileOfferResult.cancelled.name};
    final result = await a.offer(context, name: file.name, mime: file.mime, bytes: file.bytes);
    return {'action': result.name, 'name': file.name};
  }

  Future<Object?> _delete(BridgeRequest req, SurfacesHost host, InstalledApp app, BuildContext context) async {
    final fileId = req.args['fileId'] as String;
    final files = await _guard(() => host.api.listFiles(app.appId));
    final known = files.where((f) => f.fileId == fileId).firstOrNull;
    if (known == null) throw _blocked(SurfacesText.fileNotFound, 'No such file', 'not_found');
    if (!context.mounted) return {'deleted': false};
    final t = SurfacesStrings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t(SurfacesText.fileDeleteTitle, {'name': known.name})),
        content: Text(t(SurfacesText.fileDeleteBody)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t(SurfacesText.cancel))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t(SurfacesText.fileDeleteAction))),
        ],
      ),
    );
    if (ok != true) return {'deleted': false};
    await _guard(() => host.api.deleteFile(app.appId, fileId));
    _forget(app.appId, fileId);
    return {'deleted': true};
  }

  Future<Object?> _ask(
      BridgeRequest req, SurfacesHost host, InstalledApp app, String title, BuildContext context) async {
    final send = sendToHermes ?? (throw _blocked(SurfacesText.askUnsupported, 'This host cannot message Hermes'));
    final ids = List<String>.from(req.args['fileIds'] as List);
    final chosen = <StoredFile>[];
    if (ids.isNotEmpty) {
      final all = await _guard(() => host.api.listFiles(app.appId));
      for (final id in ids) {
        final f = all.where((x) => x.fileId == id).firstOrNull;
        if (f == null) throw _blocked(SurfacesText.fileNotFound, 'No such file', 'not_found');
        chosen.add(f);
      }
    }
    final text = composeAsk(req.args['prompt'] as String, title: title, appId: app.appId, files: chosen);
    if (!context.mounted) return {'sent': false};
    final t = SurfacesStrings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t(SurfacesText.askTitle)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t(SurfacesText.askBody, {'app': title})),
              const SizedBox(height: 12),
              Container(
                key: const ValueKey('ask-hermes-text'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(text),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t(SurfacesText.cancel))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t(SurfacesText.askSend))),
        ],
      ),
    );
    if (ok != true) return {'sent': false};
    final sent = await send(text);
    if (!sent) throw _blocked(SurfacesText.askSendFailed, 'Could not start the chat', 'send_failed');
    return {'sent': true};
  }

  /// A picture of this app's stored files for the page's own origin (`<img src="/__hermes/files/f_…">`), or null:
  /// not an id the server issues, not a picture, not reachable, or a preview. Pictures are kept for a while so a
  /// list of thumbnails does not fetch the same file again on every redraw.
  Future<({Uint8List bytes, String mime})?> picture(SurfacesHost host, InstalledApp app, String fileId) async {
    if (preview || !isValidFileId(fileId)) return null;
    final key = '${app.appId}/$fileId';
    final cached = _images.remove(key);
    if (cached != null) {
      _images[key] = cached; // most recently used goes last
      return cached;
    }
    try {
      final file = await host.api.downloadStored(app.appId, fileId);
      if (!_imageMimes.contains(file.mime)) return null;
      final entry = (bytes: file.bytes, mime: file.mime);
      if (file.bytes.length <= imageCacheBytes) {
        _images[key] = entry;
        _imageBytes += file.bytes.length;
        while (_imageBytes > imageCacheBytes && _images.length > 1) {
          final oldest = _images.keys.first;
          _imageBytes -= _images.remove(oldest)!.bytes.length;
        }
      }
      return entry;
    } on ApiException {
      return null;
    } on OfflineException {
      return null;
    }
  }

  /// A file was deleted (here or elsewhere): its cached picture must not be served again.
  void forgetFile(String appId, String fileId) => _forget(appId, fileId);

  void _forget(String appId, String fileId) {
    final removed = _images.remove('$appId/$fileId');
    if (removed != null) _imageBytes -= removed.bytes.length;
  }

  /// Maps what the transport reports onto the stable error codes the page can branch on.
  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on OfflineException {
      throw _blocked(SurfacesText.fileOffline, 'No connection', 'offline');
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        throw HostError('unauthorized', 'No access: check the token', key: SurfacesText.hostUnauthorized);
      }
      switch (e.status) {
        case 404:
          // The framework's own 404 ("Not Found") means the route does not exist: an older plugin. Ours says why.
          if (e.message == 'Not Found') {
            throw _blocked(SurfacesText.fileServerOld, 'The server cannot move files yet');
          }
          throw _blocked(SurfacesText.fileNotFound, e.message, 'not_found');
        case 409:
          throw HostError('stale_revision', 'The app was updated on the server', key: SurfacesText.hostStaleRevision);
        case 413:
          throw _blocked(SurfacesText.fileTooLarge, e.message, 'too_large');
        case 507:
          throw _blocked(SurfacesText.fileServerFull, e.message, 'server_full');
      }
      if (e.status >= 500) throw _blocked(SurfacesText.fileServerError, e.message, 'server_error');
      throw HostError('bad_file', e.message, key: null);
    }
  }
}

/// The message that goes to Hermes: the page's own words, then (when files are attached) where they are and how to
/// read them. The page cannot add to the second part, and the user reads all of it before it is sent. The footer is
/// for the agent and stays in English whatever the phone's language is.
String composeAsk(String prompt, {required String title, required String appId, required List<StoredFile> files}) {
  final out = StringBuffer(prompt.trim());
  out.write('\n\n— Sent from the app “$title” (app_id=$appId).');
  if (files.isNotEmpty) {
    out.write('\nFiles kept for this app (surfaces tools, app_id=$appId: file_read / file_view show the content, file_path gives the place on this host to hand a file to a skill or a command):');
    for (final f in files) {
      out.write('\n• ${f.name} · ${f.mime} · ${_size(f.size)} · file_id=${f.fileId}');
    }
  }
  return out.toString();
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
