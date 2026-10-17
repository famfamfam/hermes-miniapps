import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hermes_android/core/l10n/l10n.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// What a media type in a page's `accept` list asks the system picker for.
class PickerFilter {
  const PickerFilter(this.type, [this.extensions]);
  final FileType type;
  final List<String>? extensions;

  @override
  bool operator ==(Object other) =>
      other is PickerFilter &&
      other.type == type &&
      (other.extensions ?? const []).join(',') ==
          (extensions ?? const []).join(',');

  @override
  int get hashCode => Object.hash(type, extensions?.join(','));
}

const _extensionsOfType = <String, List<String>>{
  'application/pdf': ['pdf'],
  'image/png': ['png'],
  'image/jpeg': ['jpg', 'jpeg'],
  'image/webp': ['webp'],
  'image/gif': ['gif'],
  'image/heic': ['heic'],
  'text/plain': ['txt'],
  'text/csv': ['csv'],
  'application/json': ['json'],
  'application/zip': ['zip'],
};

/// The picker's filter for a page's `accept` list. Nothing listed, or anything this cannot express (`video/*`,
/// `*/*`), is no filter: the server decides what it accepts either way.
PickerFilter pickerFilterFor(List<String> accept) {
  if (accept.isEmpty) return const PickerFilter(FileType.any);
  if (accept.every((a) => a == 'image/*')) {
    return const PickerFilter(FileType.image);
  }
  final extensions = <String>{};
  for (final entry in accept) {
    final lower = entry.toLowerCase();
    if (lower.startsWith('.') && lower.length > 1) {
      extensions.add(lower.substring(1));
    } else if (_extensionsOfType[lower] case final known?) {
      extensions.addAll(known);
    } else {
      return const PickerFilter(FileType.any);
    }
  }
  return PickerFilter(FileType.custom, extensions.toList()..sort());
}

/// The application's side of file transfer for mini-apps: the system picker, and a sheet that offers a received file
/// for saving, opening or sharing. The user's tap is the only thing that moves a file off the app.
class AndroidHostFileActions implements HostFileActions {
  AndroidHostFileActions({
    MethodChannel? channel,
    this.pickFiles,
    this.saveFile,
    this.temporaryDirectory,
    this.share,
  }) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.hermesagent.hermes_android/files';

  /// Folder of the cache directory that the Android file provider exposes; nothing else is ever opened.
  static const openedFolder = 'opened_files';

  final MethodChannel _channel;

  /// Test seams; the real picker, save dialog, cache folder and share sheet by default.
  final Future<FilePickerResult?> Function(PickerFilter filter)? pickFiles;
  final Future<String?> Function(String name, Uint8List bytes)? saveFile;
  final Future<Directory> Function()? temporaryDirectory;
  final Future<void> Function(String path, String name, String mime)? share;

  @override
  Future<PickedFile?> pick(
    BuildContext context, {
    required List<String> accept,
  }) async {
    final filter = pickerFilterFor(accept);
    final result = await (pickFiles ?? _pickFiles)(filter);
    final file = result?.files.firstOrNull;
    if (file == null) return null;
    final path = file.path;
    final Stream<List<int>> Function() open;
    if (file.readStream != null) {
      open = () => file.readStream!;
    } else if (path != null) {
      open = () => File(path).openRead();
    } else {
      return null;
    }
    return PickedFile(name: file.name, length: file.size, open: open);
  }

  Future<FilePickerResult?> _pickFiles(PickerFilter filter) =>
      FilePicker.platform.pickFiles(
        type: filter.type,
        allowedExtensions: filter.extensions,
        withReadStream: true,
      );

  @override
  Future<FileOfferResult> offer(
    BuildContext context, {
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    final choice = await showModalBottomSheet<FileOfferResult>(
      context: context,
      showDragHandle: true,
      builder: (sheet) =>
          FileOfferSheet(name: name, mime: mime, size: bytes.length),
    );
    if (choice == null ||
        choice == FileOfferResult.cancelled ||
        !context.mounted) {
      return FileOfferResult.cancelled;
    }
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      switch (choice) {
        case FileOfferResult.saved:
          final saved = await (saveFile ?? _saveFile)(name, bytes);
          if (saved == null) return FileOfferResult.cancelled;
          messenger?.showSnackBar(
            SnackBar(content: Text(l10n.file_saved(name))),
          );
          return FileOfferResult.saved;
        case FileOfferResult.opened:
          final path = await _writeTemporary(name, bytes);
          final opened =
              await _channel.invokeMethod<bool>('openFile', {
                'path': path,
                'mime': mime,
              }) ??
              false;
          if (!opened) {
            messenger?.showSnackBar(
              SnackBar(content: Text(l10n.file_no_app_to_open)),
            );
            return FileOfferResult.cancelled;
          }
          return FileOfferResult.opened;
        case FileOfferResult.shared:
          final path = await _writeTemporary(name, bytes);
          await (share ?? _share)(path, name, mime);
          return FileOfferResult.shared;
        case FileOfferResult.cancelled:
          return FileOfferResult.cancelled;
      }
    } on MissingPluginException {
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.file_no_app_to_open)),
      );
      return FileOfferResult.cancelled;
    } on Exception {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.file_action_failed)));
      return FileOfferResult.cancelled;
    }
  }

  Future<String?> _saveFile(String name, Uint8List bytes) =>
      FilePicker.platform.saveFile(fileName: name, bytes: bytes);

  Future<void> _share(String path, String name, String mime) =>
      SharePlus.instance.share(
        ShareParams(
          subject: name,
          files: [XFile(path, mimeType: mime)],
        ),
      );

  /// A copy of the received file in the cache folder the provider exposes, under a name nobody else chooses.
  /// Copies older than a day are removed first (the share sheet gives no signal that it is done with a file).
  Future<String> _writeTemporary(String name, Uint8List bytes) async {
    final cache = await (temporaryDirectory ?? getTemporaryDirectory)();
    final folder = Directory('${cache.path}/$openedFolder');
    await folder.create(recursive: true);
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    for (final old in folder.listSync().whereType<File>()) {
      try {
        if (old.statSync().modified.isBefore(cutoff)) old.deleteSync();
      } on FileSystemException {
        // Still held by a viewer; the next offer removes it.
      }
    }
    final safe = safeFileName(name);
    final file = File(
      '${folder.path}/${DateTime.now().microsecondsSinceEpoch}-$safe',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}

/// The three things a user can do with a received file. Closing the sheet is "cancelled".
class FileOfferSheet extends StatelessWidget {
  const FileOfferSheet({
    super.key,
    required this.name,
    required this.mime,
    required this.size,
  });

  final String name;
  final String mime;
  final int size;

  static String sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: theme.textTheme.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${sizeLabel(size)} · $mime',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          ListTile(
            key: const Key('file-offer-save'),
            leading: const Icon(Icons.download_outlined),
            title: Text(l10n.file_offer_save),
            onTap: () => Navigator.pop(context, FileOfferResult.saved),
          ),
          ListTile(
            key: const Key('file-offer-open'),
            leading: const Icon(Icons.open_in_new),
            title: Text(l10n.file_offer_open),
            onTap: () => Navigator.pop(context, FileOfferResult.opened),
          ),
          ListTile(
            key: const Key('file-offer-share'),
            leading: const Icon(Icons.ios_share_outlined),
            title: Text(l10n.file_offer_share),
            onTap: () => Navigator.pop(context, FileOfferResult.shared),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
