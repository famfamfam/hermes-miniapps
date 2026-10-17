import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// Limits mirror plugin/mobile_surfaces_core/bundle.py and ADR-009 §7.
const int maxBundleFiles = 1000;
const int maxCompressedBytes = 10 * 1024 * 1024;
const int maxUnpackedBytes = 30 * 1024 * 1024;
const int supportedBundleFormat = 1;
const String manifestName = 'bundle.json';

class BundleException implements Exception {
  BundleException(this.message);
  final String message;
  @override
  String toString() => 'BundleException: $message';
}

class VerifiedBundle {
  VerifiedBundle(this.bundleId, this.manifest, this.files);
  final String bundleId;
  final Map<String, dynamic> manifest;

  /// Relative path -> verified bytes. Held in memory only until written to staging.
  final Map<String, Uint8List> files;

  String get entrypoint => manifest['entrypoint'] as String;
  int get sdkMajor => manifest['sdkMajor'] as int;
  List<String> get capabilities => List<String>.from(manifest['capabilities'] as List);
  int get unpackedSize => files.values.fold(0, (a, b) => a + b.length);
}

final RegExp _segment = RegExp(r'^[A-Za-z0-9._@~+-]+$');

String digestBytes(List<int> data) => 'sha256:${sha256.convert(data)}';

/// Rejects absolute paths, traversal, backslashes, NULs and odd segments.
void checkBundlePath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains(r'\') || path.contains('\u0000')) {
    throw BundleException('bad path: $path');
  }
  if (path == manifestName) throw BundleException('bundle.json cannot be listed as a file');
  for (final seg in path.split('/')) {
    if (seg.isEmpty || seg == '.' || seg == '..' || !_segment.hasMatch(seg)) {
      throw BundleException('bad path segment in $path');
    }
  }
}

/// Validates the archive end to end. Throws [BundleException]; nothing is installed on failure.
/// [expectedId] is the bundleId announced by the app manifest.
VerifiedBundle verifyBundle(Uint8List zipBytes, {required String expectedId}) {
  if (zipBytes.length > maxCompressedBytes) {
    throw BundleException('bundle exceeds compressed size limit');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zipBytes);
  } catch (e) {
    throw BundleException('not a zip: $e');
  }
  // +1 for bundle.json itself.
  if (archive.length > maxBundleFiles + 1) throw BundleException('too many files');

  final lower = <String>{};
  final byName = <String, ArchiveFile>{};
  var declaredTotal = 0;
  for (final f in archive) {
    if (!f.isFile) throw BundleException('directory or symlink entry: ${f.name}');
    // Mode bits are checked on their own, as bundle.py does: the archive package fills in
    // isSymbolicLink only when the zip says it was made on Unix, and zipfile on Windows says not.
    if (f.isSymbolicLink || (f.mode & 0xF000) == 0xA000) throw BundleException('symlink entry: ${f.name}');
    if (!lower.add(f.name.toLowerCase())) throw BundleException('duplicate or case-colliding names');
    byName[f.name] = f;
    declaredTotal += f.size;
    if (declaredTotal > maxUnpackedBytes) throw BundleException('bundle exceeds unpacked size limit');
  }

  final manifestFile = byName[manifestName];
  if (manifestFile == null) throw BundleException('bundle.json missing');
  final manifestBytes = _content(manifestFile);
  if (digestBytes(manifestBytes) != expectedId) {
    throw BundleException('bundle.json digest does not match bundleId');
  }
  final Map<String, dynamic> manifest;
  try {
    manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
  } catch (e) {
    throw BundleException('bundle.json is not valid JSON: $e');
  }
  // Strict integer, as in bundle.py: Dart's 1.0 == 1 would otherwise let a float format through.
  final format = manifest['format'];
  if (format is! int || format != supportedBundleFormat) {
    throw BundleException('unsupported bundle format: $format');
  }
  final listed = manifest['files'];
  if (listed is! List || listed.isEmpty) throw BundleException('bundle.json lists no files');
  // Same shape rules as plugin/mobile_surfaces_core/bundle.py: malformed JSON is always a
  // BundleException, never a type error, and both verifiers agree on the shared fixtures.
  if (manifest['sdkMajor'] is! int) throw BundleException('bundle.json: sdkMajor must be an integer');
  final caps = manifest['capabilities'];
  if (caps is! List || caps.any((c) => c is! String)) {
    throw BundleException('bundle.json: capabilities must be a list of strings');
  }
  if (manifest['entrypoint'] is! String) throw BundleException('bundle.json: entrypoint must be a string');

  final files = <String, Uint8List>{};
  var actualTotal = 0;
  for (final entry in listed) {
    if (entry is! Map<String, dynamic>) throw BundleException('bad file entry');
    final path = entry['path'];
    if (path is! String || entry['sha256'] is! String || entry['size'] is! int) {
      throw BundleException('bundle.json: file entry needs string path, string sha256, integer size');
    }
    checkBundlePath(path);
    if (files.containsKey(path)) throw BundleException('duplicate entry: $path');
    final file = byName[path];
    if (file == null) throw BundleException('listed file missing from archive: $path');
    final data = _content(file);
    actualTotal += data.length;
    if (actualTotal > maxUnpackedBytes) throw BundleException('bundle exceeds unpacked size limit');
    if (data.length != entry['size'] || sha256.convert(data).toString() != entry['sha256']) {
      throw BundleException('hash or size mismatch: $path');
    }
    files[path] = data;
  }
  final extra = byName.keys.toSet()..removeAll(files.keys)..remove(manifestName);
  if (extra.isNotEmpty) throw BundleException('unlisted files in archive: ${extra.toList()..sort()}');
  if (!files.containsKey(manifest['entrypoint'])) {
    throw BundleException('entrypoint is not a listed file');
  }
  return VerifiedBundle(expectedId, manifest, files);
}

Uint8List _content(ArchiveFile f) => f.content;
