/// A citizen can send a report only when they have no active one, picked at
/// least one emergency type, and took at least one photo or video. Picking
/// "Not sure" makes the voice message required, so responders know what is happening.
bool canSubmitReport({
  required bool hasActiveIncident,
  required Iterable<String> emergencyTypes,
  required int photoCount,
  bool voiceRequired = false,
  bool hasVoice = false,
}) =>
    !hasActiveIncident && emergencyTypes.isNotEmpty && photoCount > 0 && (!voiceRequired || hasVoice);
