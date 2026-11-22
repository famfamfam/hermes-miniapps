/// Convert Hermes/OpenAI message content into displayable text.
///
/// Legacy messages carry a String. Multimodal messages carry a list of typed
/// parts such as `{type: text, text: ...}` and `{type: image_url, ...}`.
/// Keep rendering resilient when the gateway adds new part types.
String messageContentToText(dynamic content) {
  if (content == null) return '';
  if (content is String) return normaliseDisplayText(content);

  if (content is List) {
    return normaliseDisplayText(
      content
          .map(_contentPartToText)
          .where((part) => part.isNotEmpty)
          .join('\n\n'),
    );
  }

  return normaliseDisplayText(_contentPartToText(content));
}

/// Normalise common JSON-escaped line endings that can survive one decode layer.
///
/// Hermes tool result payloads may contain nested JSON strings, so the outer
/// `jsonDecode` leaves literal two-character `\\n` sequences in the message
/// content. Markdown needs real newline characters to render paragraphs, lists,
/// and headings correctly.
String normaliseDisplayText(String text) {
  if (!text.contains(r'\n') && !text.contains(r'\r')) return text;
  return text
      .replaceAll(r'\r\n', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\n');
}

/// True when a stored message is a tool result rather than user-visible chat.
bool isToolResultMessage(Map<String, dynamic> message) {
  final role = (message['role']?.toString() ?? '').trim().toLowerCase();
  if (role == 'tool' ||
      role == 'tool_result' ||
      role == 'tool-result' ||
      role == 'function' ||
      role.contains('tool')) {
    return true;
  }

  return looksLikeToolResultText(messageContentToText(message['content']));
}

/// True when message text contains Hermes' raw tool-result wrapper.
bool looksLikeToolResultText(String text) {
  final trimmed = text.trimLeft();
  return trimmed.startsWith('<untrusted_tool_result') ||
      trimmed.contains('<untrusted_tool_result') ||
      trimmed.startsWith('{"tool_call_id"') ||
      trimmed.startsWith('{"toolCallId"');
}

/// Remove embedded raw tool-result blocks from assistant text.
///
/// If the whole message is tool output, this returns an empty string so the chat
/// screen can suppress the bubble and show only the compact tool progress card.
String stripToolResultText(String text) {
  final normalised = normaliseDisplayText(text);
  final stripped = normalised
      .replaceAll(
        RegExp(
          r'<untrusted_tool_result\b[^>]*>[\s\S]*?</untrusted_tool_result>',
          multiLine: true,
        ),
        '',
      )
      .trim();

  if (looksLikeToolResultText(stripped)) return '';
  return stripped;
}

/// Splits a multimodal message into its image data URLs and text-part text.
///
/// Used by the chat to render attached photos inline instead of `[Image]`
/// placeholders. Plain-string content yields no images and the string itself.
(List<String>, String) messageImageParts(dynamic content) {
  if (content is! List) return (const [], content is String ? content : '');
  final urls = <String>[];
  final textParts = <String>[];
  for (final part in content) {
    if (part is! Map) continue;
    if (part['type']?.toString().contains('image') == true ||
        part.containsKey('image_url')) {
      final url = (part['image_url'] is Map
              ? part['image_url']['url']
              : part['image_url'])
          ?.toString();
      if (url != null && url.isNotEmpty) urls.add(url);
    } else if (part['text'] is String) {
      textParts.add(part['text'] as String);
    }
  }
  return (urls, textParts.join('\n\n'));
}

/// One attached document kept in a message's own content: display name and
/// the data URL carrying the bytes.
typedef MessageFileAttachment = ({String name, String dataUrl});

/// Extracts `file` parts (OpenAI inline-document shape) from message content.
///
/// The gateway stores chat documents only for the running turn; these parts
/// exist in the locally sent message, which is where the tappable cards read
/// their bytes from.
List<MessageFileAttachment> messageFileParts(dynamic content) {
  if (content is! List) return const [];
  final files = <MessageFileAttachment>[];
  for (final part in content) {
    if (part is! Map) continue;
    final type = part['type']?.toString() ?? '';
    if (!type.contains('file') && !part.containsKey('file')) continue;
    final file = part['file'];
    if (file is! Map) continue;
    final name = file['filename']?.toString() ?? 'document';
    final data = file['file_data']?.toString() ?? '';
    if (data.isNotEmpty) files.add((name: name, dataUrl: data));
  }
  return files;
}

String _contentPartToText(dynamic part) {
  if (part == null) return '';
  if (part is String) return normaliseDisplayText(part);
  if (part is! Map) return part.toString();

  final text = part['text'];
  if (text is String && text.isNotEmpty) return normaliseDisplayText(text);

  final type = part['type']?.toString() ?? 'unknown';
  // Binary parts render as thumbnails/cards elsewhere in the bubble; a text
  // placeholder here would duplicate them.
  if (type.contains('image') || part.containsKey('image_url')) return '';
  if (type.contains('file') || part.containsKey('file')) return '';

  return '[Unsupported content: $type]';
}
