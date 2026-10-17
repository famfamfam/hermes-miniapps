/// The review identity attached to the exact installed preview, not a listing entry.
class PreviewIdentity {
  const PreviewIdentity({required this.buildId, required this.baseRevision});

  final String buildId;
  final int baseRevision;

  factory PreviewIdentity.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) throw const FormatException('preview must be an object');
    final buildId = json['buildId'], baseRevision = json['baseRevision'];
    if (buildId is! String || buildId.trim().isEmpty) {
      throw const FormatException('preview buildId must be a non-empty string');
    }
    if (baseRevision is! int || baseRevision < 0) {
      throw const FormatException('preview baseRevision must be a non-negative integer');
    }
    return PreviewIdentity(buildId: buildId, baseRevision: baseRevision);
  }

  Map<String, dynamic> toJson() => {'buildId': buildId, 'baseRevision': baseRevision};

  @override
  bool operator ==(Object other) =>
      other is PreviewIdentity && other.buildId == buildId && other.baseRevision == baseRevision;

  @override
  int get hashCode => Object.hash(buildId, baseRevision);
}
