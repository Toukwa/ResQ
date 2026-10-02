class AppConfig {
  static const String rtdbUrl = 'https://resq-db-41ff8-default-rtdb.asia-southeast1.firebasedatabase.app';

  /// Cloudinary (cloudinary.com) - stores incident photos; Firebase Storage needs the paid plan.
  static const String cloudinaryCloudName = 'qcvccs2i';
  static const String cloudinaryUploadPreset = 'qxpfltyg';

  /// Firebase Console > Project settings > General > "Web API Key".
  /// This key is meant to be public; the database rules are what protect data.
  static const String firebaseApiKey = 'AIzaSyDHBxLSpKSbICYzLekvrysNP7dobVZFK6s';

  /// EmailJS (emailjs.com) - sends the 6-digit login code.
  static const String emailJsServiceId = 'service_faiiwt3';
  static const String emailJsTemplateId = 'template_nj03kkh';
  static const String emailJsPublicKey = 'EMdj1dF4OgoUOMggo';

  /// The hosted web app. Only used to resolve old relative photo paths; all data
  /// now goes to Firebase directly (there is no API server anymore).
  static const String baseUrl = 'https://resq-db-41ff8.web.app';

  /// Kept because screens still pass it to the live-update socket, which ignores it.
  static const String apiBaseUrl = '$baseUrl/api';

  /// Hotlines on the login screen's "Call Agencies" button. Dialed straight
  /// from the phone, so they work without internet.
  /// TODO: PLACEHOLDERS - replace with the real Iriga City numbers before release.
  static const List<({String agency, String name, String number})> agencyHotlines = [
    (agency: 'PNP', name: 'Philippine National Police', number: '09000000001'),
    (agency: 'BFP', name: 'Bureau of Fire Protection', number: '09000000002'),
    (agency: 'CDRRMO', name: 'City Disaster Risk Reduction & Management Office', number: '09000000003'),
  ];
}
