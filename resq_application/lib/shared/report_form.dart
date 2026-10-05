/// A citizen can send a report only when they have no active one, picked at
/// least one emergency type, and attached at least one photo.
bool canSubmitReport({
  required bool hasActiveIncident,
  required Iterable<String> emergencyTypes,
  required int photoCount,
}) =>
    !hasActiveIncident && emergencyTypes.isNotEmpty && photoCount > 0;
