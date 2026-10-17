/// Parsing of the gateway's `MEDIA:/path` file-delivery contract out of
/// assistant message text.
///
/// Mirrors the desktop client's `apps/desktop/src/lib/chat-messages/parts.ts`
/// (which itself mirrors the gateway's `MEDIA_DELIVERY_EXTS` in
/// `gateway/platforms/base.py`) so all three surfaces agree on which
/// `MEDIA:` paths are real deliverables. A `MEDIA:` mention of a non-path
/// (`MEDIA:...`, a bare word) stays prose — a dead download card for a
/// non-path is worse than no card.
library;

/// Extensions the gateway treats as deliverable media. Kept in sync with
/// `MEDIA_DELIVERY_EXTS` in the gateway's `gateway/platforms/base.py` —
/// currently all 58 entries; a drift here silently drops cards for whole
/// categories (archives, geo, presentations) that the gateway will deliver.
const List<String> kMediaDeliveryExts = [
  // images
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'tiff', 'svg',
  // video
  'mp4', 'mov', 'avi', 'mkv', 'webm', '3gp',
  // audio
  'mp3', 'm2a', 'wav', 'ogg', 'opus', 'm4a', 'flac',
  // documents
  'pdf', 'docx', 'doc', 'odt', 'rtf', 'txt', 'md', 'epub',
  // spreadsheets/data
  'xlsx', 'xls', 'ods', 'csv', 'tsv', 'json', 'xml', 'yaml', 'yml',
  // geospatial / GIS
  'kmz', 'kml', 'geojson', 'gpx',
  // presentations
  'pptx', 'ppt', 'odp', 'key',
  // archives
  'zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'apk', 'ipa',
  // web / rendered output
  'html', 'htm',
];

// Longest-first so the alternation never matches a shorter ext as a prefix
// of a longer one.
final String _extAlternation = (() {
  final sorted = [...kMediaDeliveryExts]
    ..sort((a, b) => b.length.compareTo(a.length));
  return sorted.join('|');
})();

// Unquoted path branch: anchored start (`~/`, `/`, `X:\` or `X:/`), interior
// whitespace allowed, end anchored on a known deliverable extension followed
// by a boundary. Mirrors `_MEDIA_PATH_ANCHORED`. The bare fallback stops
// before backtick/double-quote so inline-code closers are not swallowed;
// apostrophes stay legal inside paths.
final RegExp _mediaTagPattern = RegExp(
  'MEDIA:\\s*(?:`[^`\\n]+`|"[^"\\n]+"|\'[^\'\\n]+\'|'
  '(?:~/|/|[A-Za-z]:[/\\\\])\\S+?(?:[^\\S\\n]+\\S+?)*?\\.(?:'
  '$_extAlternation'
  ')(?=[\\s`"\'*_,;:)\\]}]|MEDIA:|\$)|[^\\s`"]+)',
  caseSensitive: false,
);

const String _trailingPunctuation = '.,;:!?';
const String _quoteCharacters = '"\'`';

// A path ending in a known deliverable extension — the streaming guard's
// "this token is complete" test. Case-insensitive to match _mediaTagPattern.
final RegExp _completeExtPattern = RegExp(
  '\\.(?:$_extAlternation)\$',
  caseSensitive: false,
);

bool _isPlausibleMediaPath(String value) {
  return value.contains('/') ||
      value.contains(r'\') ||
      RegExp(r'\.[^.]').hasMatch(value);
}

String _unquoteMediaPath(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return trimmed;
  final quote = trimmed[0];
  // A one-character capture such as a streaming `MEDIA:'` has no closing
  // quote. Requiring two characters prevents substring(1, 0).
  if (trimmed.length >= 2 &&
      quote == trimmed[trimmed.length - 1] &&
      _quoteCharacters.contains(quote)) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  // A trailing backtick or double-quote left in the value is formatting
  // residue, not part of the path. Apostrophes are not (`john's.md`).
  final last = trimmed[trimmed.length - 1];
  return (last == '`' || last == '"')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

({String path, String punctuation}) _splitTrailingPunctuation(String value) {
  var end = value.length;
  while (end > 0 && _trailingPunctuation.contains(value[end - 1])) {
    if (!_isPlausibleMediaPath(value.substring(0, end - 1))) break;
    end -= 1;
  }
  return (path: value.substring(0, end), punctuation: value.substring(end));
}

class _SourceRange {
  final int start;
  final int end;

  const _SourceRange(this.start, this.end);

  bool overlaps(int otherStart, int otherEnd) =>
      start < otherEnd && end > otherStart;
}

List<_SourceRange> _mergeRanges(Iterable<_SourceRange> source) {
  final sorted = source.toList()..sort((a, b) => a.start.compareTo(b.start));
  if (sorted.isEmpty) return const [];
  final merged = <_SourceRange>[sorted.first];
  for (final range in sorted.skip(1)) {
    final previous = merged.last;
    if (range.start <= previous.end) {
      merged[merged.length - 1] = _SourceRange(
        previous.start,
        range.end > previous.end ? range.end : previous.end,
      );
    } else {
      merged.add(range);
    }
  }
  return merged;
}

({String marker, String rest})? _lineFence(String line) {
  var offset = 0;
  while (offset < line.length && line[offset] == ' ' && offset < 4) {
    offset += 1;
  }
  if (offset > 3 || offset >= line.length) return null;
  final markerCharacter = line[offset];
  if (markerCharacter != '`' && markerCharacter != '~') return null;
  var markerEnd = offset;
  while (markerEnd < line.length && line[markerEnd] == markerCharacter) {
    markerEnd += 1;
  }
  if (markerEnd - offset < 3) return null;
  return (
    marker: line.substring(offset, markerEnd),
    rest: line.substring(markerEnd),
  );
}

int _backtickRunLength(String text, int offset) {
  var end = offset;
  while (end < text.length && text[end] == '`') {
    end += 1;
  }
  return end - offset;
}

bool _mediaMatchIsCode(
  String text,
  List<_SourceRange> ranges,
  RegExpMatch match,
) {
  final matched = match.group(0)!;
  final backtick = matched.indexOf('`', 'MEDIA:'.length);
  for (final range in ranges) {
    if (range.start >= match.end) return false;
    if (!range.overlaps(match.start, match.end)) continue;
    // `MEDIA:` explicitly supports a backtick-quoted path. That span starts
    // after the contract marker, unlike Markdown code that surrounds the
    // whole mention. Keep the quote escape while still rejecting the same
    // text inside a fenced/indented/outer-inline code range.
    final quotedPathSpan =
        backtick >= 0 &&
        range.start == match.start + backtick &&
        range.end <= match.end &&
        text[range.end - 1] == '`';
    if (!quotedPathSpan) return true;
  }
  return false;
}

/// Code spans and code blocks are documentation, not file delivery.
///
/// This recognises CommonMark fenced blocks (backticks or tildes, arbitrary
/// info-string metadata, longer fences, and unclosed streaming fences),
/// indented blocks, and inline backtick spans. [isFinal] only affects an
/// unmatched inline-code opener: while streaming its tail stays protected so
/// an incomplete example cannot briefly turn into a download link.
List<_SourceRange> _markdownCodeRanges(String text, {required bool isFinal}) {
  final blockRanges = <_SourceRange>[];
  int? fenceStart;
  String? fenceCharacter;
  var fenceLength = 0;
  var lineStart = 0;

  while (lineStart < text.length) {
    final newline = text.indexOf('\n', lineStart);
    final lineEnd = newline == -1 ? text.length : newline + 1;
    var contentEnd = newline == -1 ? text.length : newline;
    if (contentEnd > lineStart && text[contentEnd - 1] == '\r') {
      contentEnd -= 1;
    }
    final line = text.substring(lineStart, contentEnd);
    final fence = _lineFence(line);

    if (fenceStart != null) {
      if (fence != null &&
          fence.marker[0] == fenceCharacter &&
          fence.marker.length >= fenceLength &&
          fence.rest.trim().isEmpty) {
        blockRanges.add(_SourceRange(fenceStart, lineEnd));
        fenceStart = null;
        fenceCharacter = null;
        fenceLength = 0;
      }
    } else if (fence != null &&
        (fence.marker[0] != '`' || !fence.rest.contains('`'))) {
      fenceStart = lineStart;
      fenceCharacter = fence.marker[0];
      fenceLength = fence.marker.length;
    } else {
      var spaces = 0;
      while (spaces < line.length && line[spaces] == ' ') {
        spaces += 1;
      }
      if ((line.isNotEmpty && line[0] == '\t') || spaces >= 4) {
        blockRanges.add(_SourceRange(lineStart, lineEnd));
      }
    }
    lineStart = lineEnd;
  }

  if (fenceStart != null) {
    blockRanges.add(_SourceRange(fenceStart, text.length));
  }

  final ranges = _mergeRanges(blockRanges);
  final inlineRanges = <_SourceRange>[];

  void collectInlineRanges(int start, int end) {
    var cursor = start;
    while (cursor < end) {
      final opening = text.indexOf('`', cursor);
      if (opening == -1 || opening >= end) return;
      final openingLength = _backtickRunLength(text, opening);
      var candidate = opening + openingLength;
      int? closingEnd;
      while (candidate < end) {
        final next = text.indexOf('`', candidate);
        if (next == -1 || next >= end) break;
        final candidateLength = _backtickRunLength(text, next);
        if (candidateLength == openingLength) {
          closingEnd = next + candidateLength;
          break;
        }
        candidate = next + candidateLength;
      }
      if (closingEnd == null) {
        if (!isFinal) inlineRanges.add(_SourceRange(opening, end));
        return;
      }
      inlineRanges.add(_SourceRange(opening, closingEnd));
      cursor = closingEnd;
    }
  }

  var proseStart = 0;
  for (final range in ranges) {
    collectInlineRanges(proseStart, range.start);
    proseStart = range.end;
  }
  collectInlineRanges(proseStart, text.length);
  return _mergeRanges([...ranges, ...inlineRanges]);
}

/// One `MEDIA:` reference extracted from assistant text.
class MediaTagRef {
  /// The gateway-host path to fetch (never a local path — always resolve
  /// through the session's gateway `fs/download`).
  final String path;

  /// True when the capture was quoted: quotes are the escape hatch for odd
  /// names, so trailing punctuation inside them is part of the path.
  final bool quoted;

  const MediaTagRef({required this.path, this.quoted = false});

  String get filename {
    final segments = path.split(RegExp(r'[/\\]'));
    return segments.isEmpty ? path : segments.last;
  }

  String get extension =>
      filename.contains('.') ? filename.split('.').last.toLowerCase() : '';
}

/// A segment of assistant text after `MEDIA:` extraction: either prose or a
/// media reference. Prose segments keep everything between refs (including
/// the sentence punctuation a bare ref shed) so the message reads intact.
class MediaTextSegment {
  final String text;
  final MediaTagRef? media;

  /// True for refs that sat alone on their line: safe to splice as a block
  /// between markdown documents. Inline refs must stay in the prose (as a
  /// markdown link) so they don't fragment a list item, table row, or
  /// emphasis span.
  final bool standalone;

  const MediaTextSegment.prose(this.text) : media = null, standalone = false;
  const MediaTextSegment.mediaRef(this.media, {this.standalone = false})
    : text = '';

  bool get isMedia => media != null;
}

class _ParsedMediaTag {
  final MediaTagRef ref;
  final String punctuation;

  const _ParsedMediaTag(this.ref, this.punctuation);
}

_ParsedMediaTag? _parseMediaTag(
  RegExpMatch match, {
  required int textLength,
  required bool isFinal,
}) {
  final raw = match.group(0)!.substring('MEDIA:'.length);
  final trimmedRaw = raw.trim();
  if (trimmedRaw.isEmpty) return null;
  final quote = trimmedRaw[0];
  final quoted =
      trimmedRaw.length >= 2 &&
      quote == trimmedRaw[trimmedRaw.length - 1] &&
      _quoteCharacters.contains(quote);
  // An unmatched leading quote is a streaming fragment or malformed prose,
  // never a gateway path. Apostrophes remain legal away from the first byte.
  if (!quoted && _quoteCharacters.contains(quote)) return null;
  final bare = quoted
      ? (path: _unquoteMediaPath(trimmedRaw), punctuation: '')
      : _splitTrailingPunctuation(_unquoteMediaPath(trimmedRaw));
  // At the live stream edge, an unknown-extension bare token may still grow.
  // A terminal message is authoritative, and a closed quoted token or known
  // delivery extension already provides its own boundary.
  if (!isFinal &&
      !quoted &&
      match.end == textLength &&
      !_completeExtPattern.hasMatch(bare.path)) {
    return null;
  }
  if (!_isPlausibleMediaPath(bare.path)) return null;
  return _ParsedMediaTag(
    MediaTagRef(path: bare.path, quoted: quoted),
    bare.punctuation,
  );
}

String _mediaMarkdownLabel(String path) {
  final segments = path.split(RegExp(r'[/\\]'));
  final filename = segments.isEmpty ? path : segments.last;
  return filename
      .replaceAll(r'\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]');
}

String _mediaArtifactHref(String path) {
  // Keep slash separators readable/triple-slash-compatible while encoding
  // every reserved character inside a path segment (`#`, `?`, `%`, spaces).
  final encoded = path.split('/').map(Uri.encodeComponent).join('/');
  return 'media-artifact://$encoded';
}

/// Decode one app-owned artifact link. Malformed or pathless crafted links are
/// inert instead of throwing from a Markdown tap callback.
String? mediaPathFromArtifactHref(String href) {
  const prefix = 'media-artifact://';
  if (!href.startsWith(prefix)) return null;
  try {
    final path = Uri.decodeComponent(href.substring(prefix.length));
    return _isPlausibleMediaPath(path) ? path : null;
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// Rewrite inline (mid-line) `MEDIA:` refs as markdown links so prose
/// rendering keeps them in context; standalone-line refs are left for
/// [splitMediaTags] card splicing. Code spans/blocks stay verbatim.
String inlineMediaTagsAsLinks(String text, {bool isFinal = true}) {
  final codeRanges = _markdownCodeRanges(text, isFinal: isFinal);
  final output = StringBuffer();
  var cursor = 0;
  for (final match in _mediaTagPattern.allMatches(text)) {
    if (_mediaMatchIsCode(text, codeRanges, match)) continue;
    final parsed = _parseMediaTag(
      match,
      textLength: text.length,
      isFinal: isFinal,
    );
    if (parsed == null) continue;
    output
      ..write(text.substring(cursor, match.start))
      ..write(
        '[${_mediaMarkdownLabel(parsed.ref.path)}]'
        '(${_mediaArtifactHref(parsed.ref.path)})'
        '${parsed.punctuation}',
      );
    cursor = match.end;
  }
  if (cursor == 0) return text;
  output.write(text.substring(cursor));
  return output.toString();
}

/// Split [text] into prose and media-reference segments. Degenerate captures
/// (`MEDIA:...`, bare words with no path separator or extension) stay prose.
///
/// [isFinal] distinguishes an authoritative terminal message from a growing
/// stream edge. Final absolute paths with an extension unknown to this client,
/// or no extension at all, remain actionable because the gateway has already
/// validated the delivery.
List<MediaTextSegment> splitMediaTags(String text, {bool isFinal = true}) {
  final segments = <MediaTextSegment>[];
  final codeRanges = _markdownCodeRanges(text, isFinal: isFinal);
  var cursor = 0;
  for (final match in _mediaTagPattern.allMatches(text)) {
    if (_mediaMatchIsCode(text, codeRanges, match)) continue;
    final parsed = _parseMediaTag(
      match,
      textLength: text.length,
      isFinal: isFinal,
    );
    if (parsed == null) continue;

    // A card is a block widget, so it may only replace a tag that occupies its
    // own line (the gateway's canonical delivery form). A mid-line tag stays
    // in prose and is rewritten by [inlineMediaTagsAsLinks].
    final lineStart = match.start == 0
        ? 0
        : text.lastIndexOf('\n', match.start - 1) + 1;
    final nlAfter = text.indexOf('\n', match.end);
    final lineEnd = nlAfter == -1 ? text.length : nlAfter;
    final standalone =
        text.substring(lineStart, match.start).trim().isEmpty &&
        text.substring(match.end, lineEnd).trim().isEmpty;
    if (!standalone) continue;

    if (lineStart > cursor) {
      segments.add(MediaTextSegment.prose(text.substring(cursor, lineStart)));
    }
    segments.add(MediaTextSegment.mediaRef(parsed.ref, standalone: true));
    if (parsed.punctuation.isNotEmpty) {
      segments.add(MediaTextSegment.prose(parsed.punctuation));
    }
    cursor = nlAfter == -1 ? text.length : nlAfter + 1;
  }
  if (segments.isEmpty) return [MediaTextSegment.prose(text)];
  if (cursor < text.length) {
    segments.add(MediaTextSegment.prose(text.substring(cursor)));
  }
  return segments;
}
