import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../shared/status_style.dart';
import '../shared/display_settings.dart';
import '../shared/evidence_camera.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/firebase_rest.dart';
import '../services/firebase_services.dart';
import '../services/incident_data.dart';
import '../services/media_upload.dart';
import '../services/session_service.dart';
import '../services/theme_service.dart';
import '../services/phone_call_reports.dart';
import '../services/report_status_notifier.dart';
import '../shared/incident_catalog.dart';
import '../shared/incident_format.dart';
import '../shared/incident_picker_sheet.dart';
import '../shared/report_form.dart';
import '../shared/voice_note.dart';
import 'citizen_header.dart';
import 'guest_registration_screen.dart';
import '../services/prank_warning.dart';
import '../services/sound_service.dart';
import '../shared/iriga_address.dart';
import '../shared/resq_logo.dart';
import 'incident_status_screen.dart';
import '../shared/resq_toast.dart';
import '../shared/resq_text.dart';

class HelpIsOnTheWayBanner extends StatelessWidget {
  final String vehicleCode;
  final String incidentStatus;
  final VoidCallback? onTap;

  const HelpIsOnTheWayBanner({super.key, this.vehicleCode = '', this.incidentStatus = "Pending", this.onTap});

  /// Help is only "on the way" once a unit has been sent.
  bool get _unitSent => const ['En Route', 'Arrived'].contains(reportStatusLabel(incidentStatus));

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFDC2626), // Emergency Red
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFDC2626).withValues(alpha: 0.35),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // 1. Left Info / Alert Icon
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
              child: const Icon(Icons.info_outline_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 12),

            // 2. Middle Text Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _unitSent
                        ? (vehicleCode.isEmpty ? 'Help is on the way!' : 'Help is on the way: $vehicleCode')
                        : reportStatusLabel(incidentStatus) == 'Accepted'
                            ? 'Your report was accepted.'
                            : 'Report sent. Waiting for an agency.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 1),
                  const Text(
                    'You can send a new report once this one is closed.',
                    style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w400, height: 1.3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // 3. Right Incident Status Pill
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _BlinkingDot(color: Colors.white, size: 7),
                  const SizedBox(width: 6),
                  Text(
                    reportStatusLabel(incidentStatus),
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small dot that fades in and out, for live statuses.
class _BlinkingDot extends StatefulWidget {
  final Color color;
  final double size;
  const _BlinkingDot({required this.color, this.size = 8});

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot> with SingleTickerProviderStateMixin {
  late final _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 0.2, end: 1.0).animate(_blink),
    child: Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.7), blurRadius: 6)],
      ),
    ),
  );
}

class HomeScreen extends StatefulWidget {
  final String citizenId;
  final String userName;

  const HomeScreen({super.key, required this.citizenId, required this.userName});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  /// Chosen card -> the incidents picked under it (or "Not sure").
  final Map<String, Set<String>> _selectedEmergencyTypes = {};

  /// Saved as the report's type; see IncidentCatalog.format.
  String get _formattedEmergencyTypes => _selectedEmergencyTypes.entries
      .map((e) => IncidentCatalog.format(e.key, e.value, general: e.key == IncidentData.generalEmergency))
      .join(' · ');
  final List<File> _uploadedImages = [];
  final TextEditingController _descriptionController = TextEditingController();
  File? _voiceNote; // optional voice message
  final _voiceKey = GlobalKey<VoiceRecorderFieldState>();

  String _currentAddressText = "Detecting location...";
  LatLng _currentLocation = const LatLng(13.4210, 123.4142);
  final MapController _mapController = MapController();

  /// True once the citizen places the pin themselves; GPS updates then leave it alone
  /// until they tap "my location" again.
  bool _pinSetManually = false;

  /// No usable GPS: permission denied, location turned off, or no fix yet after trying.
  bool _locationOff = false;

  /// Where the active report was filed. While set, nothing (GPS, taps, "my location")
  /// may move the pin; it is cleared only when the report is finished or failed to send.
  LatLng? _reportedLocation;
  bool _sendingReport = false; // between Confirm and the report being saved

  /// Ticks whenever the pin moves, so the full-screen map redraws it too.
  final ValueNotifier<int> _pinMoved = ValueNotifier(0);
  StreamSubscription<Position>? _gpsStream;
  bool _isLoadingLocation = false;

  AnimationController? _pulseController;
  Animation<double>? _pulseAnimation;

  Timer? _activeCheckTimer;
  Map<String, dynamic>? _activeIncident;
  List<dynamic> _dispatchedVehicles = [];
  String _activeVehicleCode = '';
  String _activeStatusStr = "Pending";

  bool get _hasActiveIncident => _activeIncident != null;

  final Color brandOrange = const Color(0xFFFF6B00);
  final Color disabledGray = const Color(0xFFE2E8F0);
  final Color textSecondary = const Color(0xFF94A3B8);

  /// Shown in the greeting; starts with the name from login, then the latest from the database.
  late String _userName = widget.userName;

  /// Report Now guest: asked to finish registering once their report has ended.
  bool _isGuest = false;
  bool _registrationOpen = false;
  bool _voiceExpanded = false;

  /// Loads the current name, in case it changed since this phone last logged in.
  Future<void> _refreshUserName() async {
    try {
      final profile = await Rtdb.get('users/${FirebaseAuthRest.uid}');
      if (profile is! Map) return;
      _isGuest = profile['guest'] == true;
      final name = (profile['fullName'] ?? '').toString().trim();
      if (name.isEmpty || name == _userName || !mounted) return;
      setState(() => _userName = name);
      await SessionService.updateFullName(name);
    } catch (_) {} // offline: keep the saved name
  }

  @override
  void initState() {
    super.initState();
    _refreshUserName();
    ThemeService.instance.addListener(_onThemeChanged);
    DisplaySettings.mapTheme.addListener(_onThemeChanged);
    _loadTheme();
    _showWelcomeOnce();
    _checkPrankWarning();
    _warningTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkPrankWarning());
    _descriptionController.addListener(() => setState(() {}));

    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat(reverse: true);

    _pulseAnimation = Tween<double>(
      begin: 8.0,
      end: 24.0,
    ).animate(CurvedAnimation(parent: _pulseController!, curve: Curves.easeInOut));

    _checkActiveIncident();
    _activeCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkActiveIncident();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _requestDashboardPermissions();
      await _initializeLiveTracking();
      // Phone notifications when a report's status changes
      await ReportStatusNotifier.start();
      // Hotline calls made from the login screen while offline become incidents now
      await PhoneCallReports.upload(widget.citizenId);
    });
  }

  Future<void> _checkActiveIncident() async {
    final List<Map<String, dynamic>> reqs;
    try {
      reqs = await IncidentData.getMyIncidents();
    } catch (_) {
      return; // offline or a hiccup: keep the current report and pin as they are
    }
    final activeList = reqs.where((r) {
      final s = (r['reqStatus'] ?? '').toString().trim().toLowerCase();
      return s != 'completed' && s != 'denied' && s != 'declined' && s != 'cancelled' && s != 'invalid';
    }).toList();

    if (mounted) {
      if (activeList.isNotEmpty) {
        final activeReq = activeList.first;
        final reqId = activeReq['Req_ID'];
        final dispatched = await FirebaseService.getDispatchedVehicles(reqId);

        if (mounted) {
          setState(() {
            _activeIncident = activeReq;
            _dispatchedVehicles = dispatched;
            _activeStatusStr = (_activeIncident!['reqStatus'] ?? 'Pending').toString();

            if (_dispatchedVehicles.isNotEmpty) {
              final firstV = _dispatchedVehicles.first;
              final p = firstV['plate_no'];
              final vt = firstV['vehicle_type'];
              _activeVehicleCode = (p != null && p.toString().isNotEmpty)
                  ? p.toString()
                  : ((vt != null && vt.toString().isNotEmpty) ? vt.toString() : "Unit Dispatched");
            } else {
              _activeVehicleCode = '';
            }
          });
          // Lock pin to reported active incident coordinates
          final rawLat = double.tryParse((activeReq['latitude'] ?? '').toString());
          final rawLng = double.tryParse((activeReq['longitude'] ?? '').toString());
          if (rawLat != null && rawLng != null && rawLat.isFinite && rawLng.isFinite) {
            _lockPinAt(LatLng(rawLat, rawLng));
          }
        }
      } else {
        if (mounted) {
          final hadIncident = _activeIncident != null;
          setState(() {
            _activeIncident = null;
            _dispatchedVehicles = [];
          });
          // The pin was locked to the incident spot; move it back to the citizen's GPS position
          // A guest whose report has ended finishes registering before going on
          if (_isGuest && reqs.isNotEmpty) _openGuestRegistration();
          // (also a report that ended before this screen saw it as active)
          if (hadIncident || (_reportedLocation != null && !_sendingReport)) {
            _reportedLocation = null;
            _useMyLocation();
          }
        }
      }
    }
  }

  /// The citizen's pin, used on both the small and the full-screen map so they always match.
  Marker _userPinMarker(Color brandOrange) {
    return Marker(
      point: (_currentLocation.latitude.isFinite && _currentLocation.longitude.isFinite)
          ? _currentLocation
          : const LatLng(13.4210, 123.4142),
      width: 60,
      height: 60,
      child: AnimatedBuilder(
        animation: _pulseAnimation!,
        builder: (context, child) => Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: _pulseAnimation!.value * 2.2,
              height: _pulseAnimation!.value * 2.2,
              decoration: BoxDecoration(color: brandOrange.withValues(alpha: 0.25), shape: BoxShape.circle),
            ),
            Container(
              width: 14,
              height: 14,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: Center(
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: brandOrange, shape: BoxShape.circle),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _requestDashboardPermissions() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    await [Permission.locationWhenInUse, Permission.camera].request();
  }

  Future<void> _openGuestRegistration() async {
    if (_registrationOpen || !mounted) return;
    _registrationOpen = true;
    final done = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => GuestRegistrationScreen(userName: _userName)));
    _registrationOpen = false;
    if (done == true) _isGuest = false;
  }

  /// The label next to the address: where the pin's position comes from.
  ({String text, Color color}) get _locationStatus {
    if (_hasActiveIncident || _reportedLocation != null) {
      return (text: 'Report location', color: const Color(0xFFEF4444));
    }
    if (_pinSetManually) return (text: 'Pin set manually', color: const Color(0xFFFF6B00));
    if (_isLoadingLocation) return (text: 'Finding you…', color: const Color(0xFFF59E0B));
    if (_locationOff) return (text: 'Location off', color: const Color(0xFF94A3B8));
    return (text: 'Live location', color: const Color(0xFF16A34A));
  }

  /// Pins the map to where the report was filed and keeps it there.
  void _lockPinAt(LatLng point) {
    if (_reportedLocation == point && _currentLocation == point) return;
    _reportedLocation = point;
    setState(() {
      _currentLocation = point;
      _pinMoved.value++;
    });
    _mapController.move(point, 16.0);
    _showAddressFor(point);
  }

  Future<void> _updateLocationFromLatLng(LatLng point, {bool manual = false}) async {
    if (!mounted) return;
    // Citizens cannot change/update location while an active incident is in progress
    if (_hasActiveIncident || _reportedLocation != null) return;
    if (manual) {
      _pinSetManually = true;
    } else {
      _locationOff = false; // a GPS reading arrived
      if (_pinSetManually) return; // a GPS reading must not undo the citizen's own pin
    }

    LatLng safePoint = point;
    if (!point.latitude.isFinite || !point.longitude.isFinite || point.latitude.isNaN || point.longitude.isNaN) {
      safePoint = const LatLng(13.4210, 123.4142);
    }

    setState(() {
      _currentLocation = safePoint;
      _pinMoved.value++;
      _isLoadingLocation = true;
    });
    _mapController.move(safePoint, 16.0);
    await _showAddressFor(safePoint);
  }

  /// Shows the barangay and city of [point] under the map.
  Future<void> _showAddressFor(LatLng point) async {
    if (mounted) setState(() => _isLoadingLocation = true);
    try {
      String? barangay;
      try {
        barangay = await IrigaAddress.barangayAt(point.latitude, point.longitude);
      } catch (_) {} // offline or busy: fall back to the phone's own lookup
      String formattedAddress;
      if (barangay != null) {
        formattedAddress = 'Brgy. $barangay, Iriga City';
      } else {
        List<Placemark> placemarks = await placemarkFromCoordinates(point.latitude, point.longitude);
        String area = placemarks.isNotEmpty ? (placemarks[0].subLocality ?? placemarks[0].name ?? "") : "";
        String city = placemarks.isNotEmpty
            ? (placemarks[0].locality ?? placemarks[0].subAdministrativeArea ?? "")
            : "";
        formattedAddress = (area.isNotEmpty && city.isNotEmpty)
            ? "$area, $city"
            : (area.isNotEmpty ? area : (city.isNotEmpty ? city : "Iriga City"));
      }

      // Skip if the pin moved on while looking this one up (e.g. it was just locked elsewhere)
      if (mounted && _currentLocation == point) {
        setState(() {
          _currentAddressText = formattedAddress;
          _isLoadingLocation = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingLocation = false);
      }
    }
  }

  Future<void> _initializeLiveTracking() async {
    if (!mounted) return;
    // Do not override pin location if an active incident is in progress
    if (_hasActiveIncident || _reportedLocation != null) return;
    setState(() => _isLoadingLocation = true);

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _currentAddressText = "Location Access Denied";
            _isLoadingLocation = false;
            _locationOff = true;
          });
        }
        return;
      }

      // Try last known position first for instant response
      Position? lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null && mounted) {
        _updateLocationFromLatLng(LatLng(lastKnown.latitude, lastKnown.longitude));
      }

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 10)),
      );

      _updateLocationFromLatLng(LatLng(position.latitude, position.longitude));
      _followGps();
    } catch (e) {
      // No fix (GPS turned off or no signal); the stream below still picks one up later
      if (mounted) {
        setState(() {
          _isLoadingLocation = false;
          if (!_pinSetManually) _locationOff = true;
        });
      }
      _followGps();
    }
  }

  /// Keeps the pin on the citizen as they move (every 10 m), until they place it themselves.
  void _followGps() {
    if (_gpsStream != null) return;
    _gpsStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 10),
    ).listen((p) => _updateLocationFromLatLng(LatLng(p.latitude, p.longitude)), onError: (_) {});
  }

  /// "My location" button: go back to following GPS.
  Future<void> _useMyLocation() async {
    _pinSetManually = false;
    await _initializeLiveTracking();
  }

  void _showFullScreenMapDialog() {
    final LatLng safeLocation =
        (_currentLocation.latitude.isFinite &&
            _currentLocation.longitude.isFinite &&
            !_currentLocation.latitude.isNaN &&
            !_currentLocation.longitude.isNaN)
        ? _currentLocation
        : const LatLng(13.4210, 123.4142);

    showDialog(
      context: context,
      builder: (dialogContext) {
        final MapController fullScreenMapController = MapController();
        return Dialog.fullscreen(
          child: Scaffold(
            resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
            appBar: AppBar(
              backgroundColor: ThemeService.instance.cardBackground,
              elevation: 1,
              leading: IconButton(
                icon: Icon(Icons.close_rounded, color: ThemeService.instance.textPrimary),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _hasActiveIncident ? "Active Incident Location" : "Location Selector Map",
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: ThemeService.instance.textPrimary,
                    ),
                  ),
                  Text(
                    _hasActiveIncident
                        ? "Location locked for current emergency report"
                        : "Tap anywhere on map to set emergency pin",
                    style: TextStyle(fontSize: 11, color: ThemeService.instance.textSecondary),
                  ),
                ],
              ),
              actions: [
                if (!_hasActiveIncident)
                  TextButton.icon(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.check_circle_rounded, color: Color(0xFFFF6B00)),
                    label: const Text(
                      "Confirm Location",
                      style: TextStyle(color: Color(0xFFFF6B00), fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
            body: StatefulBuilder(
              builder: (context, setDialogState) {
                return Stack(
                  children: [
                    FlutterMap(
                      mapController: fullScreenMapController,
                      options: MapOptions(
                        initialCenter: safeLocation,
                        initialZoom: 16.5,
                        interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
                        onTap: _hasActiveIncident
                            ? null
                            : (tapPosition, point) {
                                if (point.latitude.isFinite &&
                                    point.longitude.isFinite &&
                                    !point.latitude.isNaN &&
                                    !point.longitude.isNaN) {
                                  _updateLocationFromLatLng(point, manual: true);
                                  setDialogState(() {});
                                }
                              },
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.resq',
                          tileBuilder: DisplaySettings.mapTileBuilder,
                        ),
                        // Same pin and position as the small map, redrawn whenever it moves
                        ValueListenableBuilder<int>(
                          valueListenable: _pinMoved,
                          builder: (context, _, _) => MarkerLayer(markers: [_userPinMarker(brandOrange)]),
                        ),
                      ],
                    ),

                    if (!_hasActiveIncident)
                      Positioned(
                        bottom: 24,
                        right: 16,
                        child: FloatingActionButton.extended(
                          heroTag: 'recenter_gps',
                          backgroundColor: ThemeService.instance.cardBackground,
                          foregroundColor: ThemeService.instance.textPrimary,
                          onPressed: () async {
                            await _useMyLocation();
                            if (_currentLocation.latitude.isFinite && _currentLocation.longitude.isFinite) {
                              fullScreenMapController.move(_currentLocation, 16.5);
                            }
                            setDialogState(() {});
                          },
                          icon: const Icon(Icons.my_location_rounded, color: Color(0xFFFF6B00)),
                          label: const Text("My GPS Location", style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// Evidence is taken on the spot with the camera; picking from the gallery
  /// is not offered, so old or downloaded files can't be sent as evidence.
  Future<void> _showAttachmentSourcePicker() async {
    if (_hasActiveIncident || _uploadedImages.length >= _maxEvidence) return;

    final ts = ThemeService.instance;
    final textDark = ts.isDark ? Colors.white : const Color(0xFF0F172A);
    final textGrey = ts.isDark ? Colors.grey.shade400 : const Color(0xFF64748B);
    final border = ts.isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);
    final remaining = _maxEvidence - _uploadedImages.length;

    Widget option({
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap,
    }) => Expanded(
      child: Material(
        color: ts.isDark ? const Color(0xFF111827) : const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: brandOrange.withValues(alpha: 0.35), width: 1.5),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: brandOrange, shape: BoxShape.circle),
                  child: Icon(icon, color: Colors.white, size: 28),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textDark),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 12, color: textGrey)),
              ],
            ),
          ),
        ),
      ),
    );

    showModalBottomSheet(
      context: context,
      backgroundColor: ts.isDark ? const Color(0xFF1F2937) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: border, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: brandOrange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.camera_alt_rounded, color: brandOrange, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Send Evidence',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textDark),
                        ),
                        Text(
                          '$remaining more ${remaining == 1 ? 'item' : 'items'} allowed',
                          style: TextStyle(fontSize: 12, color: textGrey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  option(
                    icon: Icons.photo_camera_rounded,
                    title: 'Take a Photo',
                    subtitle: 'Snap the scene',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _captureEvidence(video: false);
                    },
                  ),
                  const SizedBox(width: 12),
                  option(
                    icon: Icons.videocam_rounded,
                    title: 'Record a Video',
                    subtitle: 'Up to ${_maxVideoSeconds}s',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _captureEvidence(video: true);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: ts.isDark ? const Color(0xFF1E3A8A) : const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: ts.isDark ? const Color(0xFF1D4ED8) : const Color(0xFFBFDBFE)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: ts.isDark ? const Color(0xFF93C5FD) : const Color(0xFF2563EB),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Evidence must be taken now with your camera. Files from your gallery can't be sent.",
                        style: TextStyle(
                          fontSize: 12,
                          color: ts.isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => Navigator.pop(sheetContext),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  side: BorderSide(color: border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: textDark, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPermissionDeniedSnackBar(String feature) {
    ScaffoldMessenger.of(context).showResqSnackBar(
      SnackBar(
        content: Text('❌ $feature permission is required to upload evidence. Please enable it in system settings.'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.red,
      ),
    );
  }

  static const _maxEvidence = 5;
  bool _compressingVideo = false;
  static const _maxVideoSeconds = 30;

  Future<void> _captureEvidence({required bool video}) async {
    if (!(await Permission.camera.request()).isGranted) {
      _showPermissionDeniedSnackBar('Camera');
      return;
    }
    if (video) await Permission.microphone.request(); // sound for the video; it still records without
    if (!mounted) return;
    // ResQ's own camera: quicker shutter than the phone's camera app, and never leaves the app
    final file = await openEvidenceCamera(context, video: video, maxVideoSeconds: _maxVideoSeconds);
    if (file == null || !mounted || _uploadedImages.length >= _maxEvidence) return;
    var evidence = file;
    if (video) {
      // Videos are compressed now, while the citizen fills in the rest of the form
      setState(() => _compressingVideo = true);
      evidence = await MediaUpload.compressVideo(evidence);
      if (!mounted) return;
      setState(() => _compressingVideo = false);
    }
    setState(() => _uploadedImages.add(evidence));
  }

  /// Last check before sending: a summary of what goes out, in the app's popup style.
  Future<bool?> _confirmBroadcastDialog() {
    const red = Color(0xFFEF4444);
    final ts = ThemeService.instance;
    final textDark = ts.isDark ? Colors.white : const Color(0xFF0F172A);
    final textBody = ts.isDark ? Colors.grey.shade300 : const Color(0xFF475569);
    final border = ts.isDark ? const Color(0xFF374151) : const Color(0xFFE2E8F0);
    final videos = _uploadedImages.where((f) => IncidentData.isVideoFile(f.path)).length;
    final photos = _uploadedImages.length - videos;
    final evidence = [
      if (photos > 0) '$photos photo${photos == 1 ? '' : 's'}',
      if (videos > 0) '$videos video${videos == 1 ? '' : 's'}',
    ].join(' · ');

    Widget row(IconData icon, String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF94A3B8)),
          const SizedBox(width: 10),
          SizedBox(
            width: 72,
            child: Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: textDark),
            ),
          ),
        ],
      ),
    );

    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: ts.isDark ? const Color(0xFF1F2937) : Colors.white,
        surfaceTintColor: Colors.transparent,
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
        actionsPadding: const EdgeInsets.all(24),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.campaign_rounded, color: red, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Send Emergency Alert?',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: textDark),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Responders will be alerted right away. Please check your report:',
                style: TextStyle(fontSize: 13, height: 1.4, color: textBody),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
                decoration: BoxDecoration(
                  color: ts.isDark ? const Color(0xFF111827) : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: border),
                ),
                child: Column(
                  children: [
                    for (final e in _selectedEmergencyTypes.entries)
                      row(
                        Icons.emergency_rounded,
                        e.key == IncidentData.generalEmergency ? 'EOC' : e.key,
                        e.value.map((p) => p.replaceFirst(RegExp(r'^(BFP|PNP|CDRRMO): '), '')).join(', '),
                      ),
                    row(Icons.place_rounded, 'Location', _currentAddressText),
                    row(Icons.photo_camera_rounded, 'Evidence', evidence),
                    if (_voiceNote != null) row(Icons.mic_rounded, 'Voice', 'Voice message attached'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'False reports may lead to penalties.',
                style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
        ),
        // Stacked full-width buttons: room for the label on any screen size
        actions: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.campaign_rounded, size: 20),
                label: const Text('Send Alert', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: red,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  side: BorderSide(color: border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: textDark, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _submitEmergencyAlert() async {
    if (_hasActiveIncident || !_isFormValid) return;

    final confirmBroadcast = await _confirmBroadcastDialog() == true;
    if (!confirmBroadcast) return;
    if (!mounted) return;

    // From here the pin stays where it is being reported, even while evidence uploads
    final reportedAt = _currentLocation;
    _lockPinAt(reportedAt);
    _sendingReport = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          const Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF6B00)))),
    );

    try {
      final typesSelected = _formattedEmergencyTypes;
      final emergencyId = await FirebaseService.createIncident(
        citizenId: widget.citizenId,
        incidentType: typesSelected,
        description: _descriptionController.text.trim(),
        latitude: reportedAt.latitude,
        longitude: reportedAt.longitude,
        images: _uploadedImages,
        voiceNote: _voiceNote,
      );
      _sendingReport = false;

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      if (!mounted) return;

      setState(() {
        _selectedEmergencyTypes.clear();
        _uploadedImages.clear();
        _descriptionController.clear();
        _voiceNote = null;
        _voiceKey.currentState?.clear();
      });

      await _checkActiveIncident();

      if (!mounted) return;

      Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (context) => IncidentStatusScreen(
                citizenId: widget.citizenId,
                userName: _userName,
                emergencyId: emergencyId,
                emergencyTypes: typesSelected,
              ),
            ),
          )
          .then((_) => _checkActiveIncident());
    } catch (e) {
      _sendingReport = false;
      _reportedLocation = null; // not sent, so the citizen may move the pin again
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();

        ScaffoldMessenger.of(context).showResqSnackBar(
          SnackBar(
            content: Text('Failed to broadcast critical alert packet: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// "Not sure" on any card: a voice message must explain what is happening.
  bool get _voiceRequired => _selectedEmergencyTypes.values.any((p) => p.contains(IncidentCatalog.notSure));

  bool get _isFormValid =>
      !_compressingVideo &&
      canSubmitReport(
        hasActiveIncident: _hasActiveIncident,
        emergencyTypes: _selectedEmergencyTypes.keys,
        photoCount: _uploadedImages.length,
        voiceRequired: _voiceRequired,
        hasVoice: _voiceNote != null,
      );

  /// What is still missing, shown on the disabled send button.
  String get _missingHint {
    if (_compressingVideo) return 'Compressing video…';
    if (_selectedEmergencyTypes.isEmpty) return 'Select an emergency type to continue';
    if (_voiceRequired && _voiceNote == null) return 'You picked "Not sure": record a voice message';
    if (_uploadedImages.isEmpty) return 'Send evidence to continue';
    return 'Complete the form to continue';
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  Timer? _warningTimer;
  bool _warningOpen = false;

  /// An admin flagged one of this citizen's reports as a prank: show the warning
  /// (it can't be dismissed without acknowledging) and record this device's IP.
  Future<void> _checkPrankWarning() async {
    if (_warningOpen || !mounted) return;
    Map<String, dynamic>? warning;
    try {
      warning = await PrankWarning.pending();
    } catch (_) {
      return;
    }
    if (warning == null || !mounted) return;
    _warningOpen = true;
    final w = warning;
    SoundService.playPrankWarning();
    // The IP is recorded as soon as the warning appears, not when it's closed
    PrankWarning.publicIp().then((ip) => PrankWarning.recordSeen(w, ip)).catchError((_) {});
    const red = Color(0xFFDC2626);
    final ts = ThemeService.instance;
    final password = TextEditingController();
    String? error;
    bool hidden = true;
    bool busy = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false, // no back button, no tapping outside: only the password closes it
        child: StatefulBuilder(
          builder: (ctx, setD) {
            Future<void> tryUnlock() async {
              if (!PrankWarning.passwordMatches(w, password.text)) {
                setD(() => error = 'Incorrect password. Only authorized personnel can close this warning.');
                return;
              }
              setD(() => busy = true);
              try {
                await PrankWarning.unlock(w);
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (_) {
                setD(() {
                  busy = false;
                  error = "Couldn't close it. Check the internet connection and try again.";
                });
              }
            }

            return AlertDialog(
              backgroundColor: ts.cardBackground,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: red, width: 2),
              ),
              contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: red.withValues(alpha: 0.12), shape: BoxShape.circle),
                      child: const Icon(Icons.gpp_bad_rounded, color: red, size: 40),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Prank Report Warning',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: red),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${w['message'] ?? PrankWarning.defaultMessage}',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, height: 1.45, color: ts.textPrimary),
                    ),
                    if (w['reqId'] != null) ...[
                      const SizedBox(height: 8),
                      Text('Report #${w['reqId']}', style: TextStyle(fontSize: 12, color: ts.textMuted)),
                    ],
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: red.withValues(alpha: ts.isDark ? 0.15 : 0.06),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: red.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.lock_rounded, color: red, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'This app is locked. Only authorized personnel from the responding office can unlock it.',
                              style: TextStyle(fontSize: 12, height: 1.35, color: ts.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: password,
                      obscureText: hidden,
                      onSubmitted: (_) => busy ? null : tryUnlock(),
                      style: TextStyle(color: ts.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Unlock password',
                        hintStyle: TextStyle(color: ts.textMuted),
                        errorText: error,
                        errorMaxLines: 3,
                        prefixIcon: Icon(Icons.key_rounded, color: ts.textMuted, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(
                            hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                            color: ts.textMuted,
                            size: 20,
                          ),
                          onPressed: () => setD(() => hidden = !hidden),
                        ),
                        filled: true,
                        fillColor: ts.inputBackground,
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: ts.borderColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: red, width: 1.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              actions: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: red,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: busy ? null : tryUnlock,
                    icon: const Icon(Icons.lock_open_rounded, size: 18),
                    label: const Text('Unlock', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    // Not disposed here: the pop-up is still animating closed and using it; it is freed with the pop-up
    _warningOpen = false;
  }

  /// First login on this account: a short welcome explaining how to report.
  Future<void> _showWelcomeOnce() async {
    try {
      final path = 'user_settings/${FirebaseAuthRest.uid}/welcome_seen';
      if (await Rtdb.get(path) == true) return;
      await Rtdb.set(path, true);
    } catch (_) {
      return; // offline: try again next time
    }
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    final ts = ThemeService.instance;
    final first = _userName.trim().split(' ').first;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ts.cardBackground,
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ResqLogo(size: 64, radius: 18),
            const SizedBox(height: 16),
            ResqText(
              'Welcome to ResQ, $first!',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: ts.textPrimary),
            ),
            const SizedBox(height: 10),
            Text(
              'In an emergency, pick what happened, add a photo or video, and send your report. '
              'Responders will see your location, and you can follow your report from the bell at the top.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.45, color: ts.textSecondary),
            ),
            const SizedBox(height: 10),
            Text(
              'Tap your picture at the top right for settings.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: ts.textMuted),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: brandOrange,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Get started', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  /// Applies the dark mode choice saved on the Settings screen.
  Future<void> _loadTheme() async {
    try {
      final saved = await Rtdb.get('user_settings/${FirebaseAuthRest.uid}');
      if (saved is! Map) return;
      if (saved['theme_mode'] is String) ThemeService.instance.setThemeMode(saved['theme_mode']);
      DisplaySettings.load(Map<String, dynamic>.from(saved)); // map theme
    } catch (_) {}
  }

  @override
  void dispose() {
    ThemeService.instance.removeListener(_onThemeChanged);
    DisplaySettings.mapTheme.removeListener(_onThemeChanged);
    _warningTimer?.cancel();
    _activeCheckTimer?.cancel();
    _descriptionController.dispose();
    _pulseController?.dispose();
    _gpsStream?.cancel();
    _pinMoved.dispose();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false, // keyboard covers the screen instead of pushing it up
      backgroundColor: ThemeService.instance.pageBackground,
      // Header stays on top; a shadow appears only once content scrolls under it
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 76,
        titleSpacing: 16,
        backgroundColor: ThemeService.instance.pageBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 4,
        shadowColor: Colors.black26,
        title: CitizenHeader(userName: _userName),
      ),
      body: SafeArea(
        child: _hasActiveIncident
            // The form stays in place, greyed out and locked (it still scrolls); the banner sits on top
            ? Stack(
                fit: StackFit.expand,
                children: [
                  _greyedOut(_reportForm(locked: true), scrollable: true),
                  Positioned(
                    left: 16,
                    right: 16,
                    top: 8,
                    child: HelpIsOnTheWayBanner(
                      vehicleCode: _activeVehicleCode,
                      incidentStatus: _activeStatusStr,
                      onTap: _openActiveReport,
                    ),
                  ),
                ],
              )
            : _reportForm(),
      ),
      // Send button stays in thumb reach instead of at the end of a long form
      bottomNavigationBar: _hasActiveIncident ? _greyedOut(_sendBar()) : _sendBar(),
    );
  }

  // ─── layout pieces ──────────────────────────────────────────────────────

  /// An open report: only its status and a way to it, not a locked-out form.
  /// Locked and drained of colour while a report is open.
  Widget _greyedOut(Widget child, {bool scrollable = false}) => IgnorePointer(
    ignoring: !scrollable, // a scrollable form locks its own buttons instead
    child: Opacity(
      opacity: 0.45,
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.2126, 0.7152, 0.0722, 0, 0, //
          0.2126, 0.7152, 0.0722, 0, 0, //
          0.2126, 0.7152, 0.0722, 0, 0, //
          0, 0, 0, 1, 0,
        ]),
        child: child,
      ),
    ),
  );

  void _openActiveReport() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (context) => IncidentStatusScreen(
              citizenId: widget.citizenId,
              userName: _userName,
              emergencyId: _activeIncident!['Req_ID'].toString(),
              emergencyTypes: (_activeIncident!['incType'] ?? 'Emergency').toString(),
            ),
          ),
        )
        .then((_) => _checkActiveIncident());
  }

  /// Numbered step title; the number turns into a green tick once the step is done.
  Widget _stepHeader(int n, String title, {bool done = false, String? trailing, Color? trailingColor}) {
    final ts = ThemeService.instance;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: done ? const Color(0xFF16A34A) : brandOrange, shape: BoxShape.circle),
            child: done
                ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                : Text(
                    '$n',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: ts.textPrimary),
            ),
          ),
          if (trailing != null)
            Text(
              trailing,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: trailingColor ?? ts.textMuted),
            ),
        ],
      ),
    );
  }

  /// The report in three steps: what, where, proof.
  /// [locked]: a report is open, so it still scrolls but nothing in it can be tapped.
  Widget _reportForm({bool locked = false}) {
    final ts = ThemeService.instance;
    return SingleChildScrollView(
      // Locked: room at the top so the first step isn't hidden under the banner
      padding: EdgeInsets.fromLTRB(16, locked ? 96 : 8, 16, 24),
      child: IgnorePointer(
        ignoring: locked,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 1. What's happening ──
            _stepHeader(1, "What's happening?", done: _selectedEmergencyTypes.isNotEmpty),
            Row(
              children: [
                _buildCategoryCard(
                  IncidentData.generalEmergency,
                  agencySymbol('EOC').icon,
                  'Not sure? We route it',
                  agencySymbol('EOC').color,
                ),
                const SizedBox(width: 8),
                _buildCategoryCard('BFP', agencySymbol('BFP').icon, 'Fire', agencySymbol('BFP').color),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _buildCategoryCard('PNP', agencySymbol('PNP').icon, 'Police', agencySymbol('PNP').color),
                const SizedBox(width: 8),
                _buildCategoryCard(
                  'CDRRMO',
                  agencySymbol('CDRRMO').icon,
                  'Rescue & Medical',
                  agencySymbol('CDRRMO').color,
                ),
              ],
            ),
            const SizedBox(height: 24),

            // ── 2. Where ──
            _stepHeader(2, 'Where?', trailing: 'Tap the map to move the pin'),
            Container(
              height: 180,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: ts.borderColor),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: (_currentLocation.latitude.isFinite && _currentLocation.longitude.isFinite)
                          ? _currentLocation
                          : const LatLng(13.4210, 123.4142),
                      initialZoom: 16.0,
                      // Preview only: no panning or zooming here; tap to open the full map
                      interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                      onTap: (tapPosition, point) => _showFullScreenMapDialog(),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.resq',
                        tileBuilder: DisplaySettings.mapTileBuilder,
                      ),
                      MarkerLayer(markers: [_userPinMarker(brandOrange)]),
                    ],
                  ),

                  // Top Right Controls: GPS Recenter & Fullscreen Map
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Row(
                      children: [
                        if (!_hasActiveIncident)
                          _mapIconButton(Icons.my_location_rounded, 'Use my location', _useMyLocation),
                        _mapIconButton(Icons.fullscreen_rounded, 'Full screen map', _showFullScreenMapDialog),
                      ],
                    ),
                  ),

                  // Top left: tracking status with a blinking dot in the status colour
                  Positioned(top: 10, left: 10, child: _trackingPill()),

                  // Bottom right: the address on a shadow that fades in from the right
                  Positioned(
                    left: 90,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.bottomRight,
                        // Only as wide as the text, and light: just enough to read it
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(36, 6, 10, 6),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerRight,
                              end: Alignment.centerLeft,
                              colors: [
                                Colors.black.withValues(alpha: 0.45),
                                Colors.black.withValues(alpha: 0.2),
                                Colors.transparent,
                              ],
                              stops: const [0, 0.6, 1],
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  _currentAddressText,
                                  textAlign: TextAlign.right,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    shadows: [Shadow(color: Colors.black87, blurRadius: 3)],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.location_on_rounded, color: Colors.white, size: 14),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── 3. Add proof ──
            _stepHeader(
              3,
              'Add proof',
              done: _uploadedImages.isNotEmpty && (!_voiceRequired || _voiceNote != null),
              trailing: '${_uploadedImages.length}/$_maxEvidence',
              trailingColor: _uploadedImages.isNotEmpty ? brandOrange : null,
            ),
            // Voice (small tile) and photo/video (wide) side by side
            SizedBox(
              height: 92,
              child: LayoutBuilder(
                builder: (context, box) => Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Recording: grows to about two thirds; the photo button stays beside it
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 380),
                      curve: Curves.easeInOutCubic,
                      width: _voiceExpanded ? box.maxWidth * 0.68 : 88,
                      child: VoiceRecorderField(
                        key: _voiceKey,
                        compact: true,
                        required: _voiceRequired,
                        onChanged: (f) => setState(() => _voiceNote = f),
                        onExpandedChanged: (v) => setState(() => _voiceExpanded = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: _photoButton()),
                  ],
                ),
              ),
            ),
            if (_uploadedImages.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 110,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _uploadedImages.length,
                  itemBuilder: (context, index) {
                    final imgFile = _uploadedImages[index];
                    return Stack(
                      children: [
                        Container(
                          width: 100,
                          height: 100,
                          margin: const EdgeInsets.only(right: 10, top: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFCBD5E1)),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: IncidentData.isVideoFile(imgFile.path)
                              ? Container(
                                  color: const Color(0xFF1E293B),
                                  child: const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 34),
                                      SizedBox(height: 4),
                                      Text(
                                        'Video',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : Image.file(imgFile, fit: BoxFit.cover),
                        ),
                        if (!_hasActiveIncident)
                          Positioned(
                            top: 0,
                            right: 4,
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _uploadedImages.removeAt(index);
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
                                child: const Icon(Icons.close, color: Colors.white, size: 14),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
            if (_compressingVideo)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF6B00)),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Compressing video so it sends faster…',
                      style: TextStyle(fontSize: 12, color: Color(0xFFFF6B00)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),

            // Note: optional (orange) until written (green); opens a sheet to type in
            _noteTile(),
          ],
        ),
      ),
    );
  }

  /// Optional note: orange until something is written, then green with a preview.
  Widget _noteTile() {
    final ts = ThemeService.instance;
    final note = _descriptionController.text.trim();
    final done = note.isNotEmpty;
    final c = done ? const Color(0xFF16A34A) : brandOrange;
    return Material(
      color: c.withValues(alpha: ts.isDark ? 0.18 : 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.withValues(alpha: ts.isDark ? 0.8 : 0.5), width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openNoteSheet,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                child: Icon(done ? Icons.check_rounded : Icons.edit_note_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      done ? 'Note added' : 'Add a note',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: done ? c : ts.textPrimary),
                    ),
                    Text(
                      done ? note : 'Optional',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: done ? ts.textSecondary : c),
                    ),
                  ],
                ),
              ),
              Icon(done ? Icons.edit_rounded : Icons.add_rounded, color: c, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// Bottom sheet for the note, styled like the evidence picker. Sits above the keyboard.
  Future<void> _openNoteSheet() async {
    final ts = ThemeService.instance;
    final draft = TextEditingController(text: _descriptionController.text);
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ts.cardBackground,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(color: ts.borderColor, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: brandOrange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.edit_note_rounded, color: brandOrange, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Add a Note',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: ts.textPrimary),
                          ),
                          Text(
                            'Anything else responders should know',
                            style: TextStyle(fontSize: 12, color: ts.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: draft,
                  autofocus: true,
                  maxLines: 4,
                  maxLength: 300,
                  textCapitalization: TextCapitalization.sentences,
                  style: TextStyle(color: ts.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'e.g. Two people trapped on the second floor',
                    hintStyle: TextStyle(color: ts.textMuted),
                    filled: true,
                    fillColor: ts.inputBackground,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: ts.borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: brandOrange, width: 1.5),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (_descriptionController.text.isNotEmpty) ...[
                      Expanded(
                        child: SizedBox(
                          height: 50,
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(sheet, ''),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFFEF4444)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                            child: const Text(
                              'Remove',
                              style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      flex: 2,
                      child: SizedBox(
                        height: 50,
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(sheet, draft.text.trim()),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: brandOrange,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          child: const Text('Save note', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Closed by swiping down: keep the note as it was
    if (saved != null && mounted) setState(() => _descriptionController.text = saved);
  }

  /// Small square map control on a card; the tap area reaches past the card so it stays easy to hit.
  Widget _mapIconButton(IconData icon, String tooltip, VoidCallback onTap) => Tooltip(
    message: tooltip,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Material(
          color: ThemeService.instance.cardBackground,
          borderRadius: BorderRadius.circular(8),
          elevation: 1.5,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(
              icon,
              size: 18,
              color: icon == Icons.my_location_rounded ? brandOrange : ThemeService.instance.textPrimary,
            ),
          ),
        ),
      ),
    ),
  );

  /// "● Live location" status; the dot blinks in the tracking status colour.
  Widget _trackingPill() {
    final status = _locationStatus;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: _pulseController == null
                ? const AlwaysStoppedAnimation(1.0)
                : Tween(begin: 0.25, end: 1.0).animate(_pulseController!),
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: status.color,
                shape: BoxShape.circle,
                border: Border.all(color: Color.lerp(status.color, Colors.white, 0.5)!, width: 1.5),
                boxShadow: [BoxShadow(color: status.color.withValues(alpha: 0.7), blurRadius: 8)],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            status.text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: status.color,
              // Glows in its own status colour; the faint dark edge keeps it readable on light tiles
              shadows: [
                Shadow(color: status.color.withValues(alpha: 0.7), blurRadius: 8),
                Shadow(color: status.color.withValues(alpha: 0.4), blurRadius: 14),
                const Shadow(color: Colors.black26, blurRadius: 2),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Photo/video is required: red until something is added, then green.
  Widget _photoButton() {
    final ts = ThemeService.instance;
    final n = _uploadedImages.length;
    final done = n > 0;
    final full = n >= _maxEvidence;
    final c = done ? const Color(0xFF16A34A) : const Color(0xFFEF4444);
    // Same look as the admin cards: a pale tint of the colour inside, a brighter border
    return Material(
      color: c.withValues(alpha: ts.isDark ? 0.18 : 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.withValues(alpha: ts.isDark ? 0.8 : 0.5), width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: full ? null : _showAttachmentSourcePicker,
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth < 150
              // Squeezed beside the voice recorder: icon and a short label only
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                      child: Icon(
                        done ? Icons.check_rounded : Icons.photo_camera_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      done ? '$n/$_maxEvidence' : 'Photo',
                      maxLines: 1,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: c),
                    ),
                  ],
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                        child: Icon(
                          done ? Icons.check_rounded : Icons.photo_camera_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              done ? '$n of $_maxEvidence added' : 'Photo or video',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: done ? c : ts.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              done ? (full ? 'Maximum reached' : 'Tap to add more') : 'Required',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: done ? ts.textSecondary : c,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  /// Pinned send button; says what is missing until the report is ready.
  Widget _sendBar() {
    final ts = ThemeService.instance;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 10 + MediaQuery.paddingOf(context).bottom),
      decoration: BoxDecoration(
        color: ts.pageBackground,
        border: Border(top: BorderSide(color: ts.borderColor)),
      ),
      child: SizedBox(
        height: 56,
        child: ElevatedButton.icon(
          onPressed: _isFormValid ? _submitEmergencyAlert : null,
          icon: Icon(_isFormValid ? Icons.campaign_rounded : Icons.info_outline_rounded),
          label: Text(
            _isFormValid ? 'Send emergency alert' : _missingHint,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFEF4444),
            foregroundColor: Colors.white,
            disabledBackgroundColor: ts.borderColor,
            disabledForegroundColor: ts.textSecondary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    );
  }

  /// Every card opens its incident list. General Emergency lists all agencies'
  /// incidents but is sent to the EOC only, so it can't be combined with an agency.
  Future<void> _onCategoryTap(String type, IconData icon, String agency, Color color) async {
    final general = type == IncidentData.generalEmergency;
    final picks = await showIncidentPicker(
      context,
      title: 'What is happening?',
      subtitle: general ? 'Sent to the EOC, who decides who responds' : '$type · $agency',
      icon: icon,
      color: color,
      sections: general ? IncidentCatalog.allSections() : IncidentCatalog.sectionsFor(type),
      initial: _selectedEmergencyTypes[type] ?? const {},
    );
    if (!mounted || picks == null) return;
    setState(() {
      if (picks.isEmpty) {
        _selectedEmergencyTypes.remove(type);
      } else if (general) {
        _selectedEmergencyTypes
          ..clear()
          ..[type] = picks;
      } else {
        _selectedEmergencyTypes
          ..remove(IncidentData.generalEmergency)
          ..[type] = picks;
      }
    });
  }

  Widget _buildCategoryCard(String type, IconData icon, String agency, Color color) {
    final isSelected = _selectedEmergencyTypes.containsKey(type);
    final picks = _selectedEmergencyTypes[type];
    final incident = picks == null ? null : IncidentCatalog.summary(picks);
    return Expanded(
      child: Semantics(
        button: true,
        selected: isSelected,
        label: incident == null ? '$type, $agency' : '$type, $incident',
        child: GestureDetector(
          onTap: _hasActiveIncident ? null : () => _onCategoryTap(type, icon, agency, color),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            decoration: BoxDecoration(
              color: isSelected ? color.withValues(alpha: 0.08) : ThemeService.instance.cardBackground,
              border: Border.all(
                color: isSelected ? color : ThemeService.instance.borderColor,
                width: isSelected ? 2.5 : 1,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: isSelected
                  ? [BoxShadow(color: color.withValues(alpha: 0.15), blurRadius: 6, offset: const Offset(0, 2))]
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(icon, color: isSelected ? color : textSecondary, size: 28),
                      const SizedBox(height: 6),
                      Text(
                        type,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: isSelected ? color : ThemeService.instance.textPrimary,
                        ),
                      ),
                      Text(
                        incident ?? agency,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: incident == null ? FontWeight.normal : FontWeight.w600,
                          color: incident == null ? textSecondary : color,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                      child: const Icon(Icons.check, color: Colors.white, size: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
