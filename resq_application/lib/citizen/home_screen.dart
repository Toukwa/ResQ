import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';
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
import 'incident_status_screen.dart';
import '../shared/resq_toast.dart';

class HelpIsOnTheWayBanner extends StatelessWidget {
  final String vehicleCode;
  final String incidentStatus;
  final VoidCallback? onTap;

  const HelpIsOnTheWayBanner({super.key, this.vehicleCode = "BFP-001", this.incidentStatus = "Pending", this.onTap});

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
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Help is on the way!",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
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
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    incidentStatus,
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

  /// The "Help is on the way" banner floats over the form: its height reserves room at
  /// the top, and once content scrolls under it the banner turns slightly see-through.
  double _bannerHeight = 72;
  bool _contentUnderBanner = false;

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
  String _activeVehicleCode = "BFP-001";
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
    _descriptionController.addListener(() => setState(() {}));

    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat(reverse: true);

    _pulseAnimation = Tween<double>(
      begin: 8.0,
      end: 24.0,
    ).animate(CurvedAnimation(parent: _pulseController!, curve: Curves.easeInOut));

    _checkActiveIncident();
    _activeCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) {
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
      return s != 'completed' && s != 'denied' && s != 'declined' && s != 'cancelled';
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
              _activeVehicleCode = "BFP-001";
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
      List<Placemark> placemarks = await placemarkFromCoordinates(point.latitude, point.longitude);

      String barangay = placemarks.isNotEmpty ? (placemarks[0].subLocality ?? placemarks[0].name ?? "") : "";
      String city = placemarks.isNotEmpty ? (placemarks[0].locality ?? placemarks[0].subAdministrativeArea ?? "") : "";

      String formattedAddress = (barangay.isNotEmpty && city.isNotEmpty)
          ? "$barangay, $city"
          : (barangay.isNotEmpty ? barangay : (city.isNotEmpty ? city : "Iriga City"));

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
            appBar: AppBar(
              backgroundColor: Colors.white,
              elevation: 1,
              leading: IconButton(
                icon: const Icon(Icons.close_rounded, color: Color(0xFF0F172A)),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _hasActiveIncident ? "Active Incident Location" : "Location Selector Map",
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                  ),
                  Text(
                    _hasActiveIncident
                        ? "Location locked for current emergency report"
                        : "Tap anywhere on map to set emergency pin",
                    style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                  ),
                ],
              ),
              actions: [
                if (!_hasActiveIncident)
                  TextButton.icon(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.check_circle_rounded, color: Color(0xFFFF5200)),
                    label: const Text(
                      "Confirm Location",
                      style: TextStyle(color: Color(0xFFFF5200), fontWeight: FontWeight.bold),
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
                          tileBuilder: ThemeService.instance.isDark
                              ? (context, tileWidget, tile) => ColorFiltered(
                                  colorFilter: const ColorFilter.matrix(<double>[
                                    -0.2126,
                                    -0.7152,
                                    -0.0722,
                                    0,
                                    255,
                                    -0.2126,
                                    -0.7152,
                                    -0.0722,
                                    0,
                                    255,
                                    -0.2126,
                                    -0.7152,
                                    -0.0722,
                                    0,
                                    255,
                                    0,
                                    0,
                                    0,
                                    1,
                                    0,
                                  ]),
                                  child: tileWidget,
                                )
                              : null,
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
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF0F172A),
                          onPressed: () async {
                            await _useMyLocation();
                            if (_currentLocation.latitude.isFinite && _currentLocation.longitude.isFinite) {
                              fullScreenMapController.move(_currentLocation, 16.5);
                            }
                            setDialogState(() {});
                          },
                          icon: const Icon(Icons.my_location_rounded, color: Color(0xFFFF5200)),
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
    final picker = ImagePicker();
    // Photos are shrunk by the camera picker (1600 px, quality 70: a few hundred KB)
    final XFile? file = video
        ? await picker.pickVideo(
            source: ImageSource.camera,
            maxDuration: const Duration(seconds: _maxVideoSeconds),
          )
        : await picker.pickImage(source: ImageSource.camera, imageQuality: 70, maxWidth: 1600, maxHeight: 1600);
    if (file == null || !mounted || _uploadedImages.length >= _maxEvidence) return;
    var evidence = File(file.path);
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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

  @override
  void dispose() {
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
      backgroundColor: const Color(0xFFF8FAFC),
      // Header stays on top; a shadow appears only once content scrolls under it
      appBar: AppBar(
        automaticallyImplyLeading: false,
        toolbarHeight: 76,
        titleSpacing: 16,
        backgroundColor: const Color(0xFFF8FAFC),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 4,
        shadowColor: Colors.black26,
        title: CitizenHeader(userName: _userName),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              // Notices when the form scrolls under the banner
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
                    final under = n.metrics.pixels > 8;
                    if (under != _contentUnderBanner) setState(() => _contentUnderBanner = under);
                  }
                  return false; // let the header's scroll shadow see it too
                },
                child: SingleChildScrollView(
                  // Room at the top so nothing starts hidden under the banner
                  padding: EdgeInsets.fromLTRB(16, _hasActiveIncident ? _bannerHeight + 16 : 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Location Status Bar
                      Row(
                        children: [
                          Icon(Icons.location_on_outlined, color: brandOrange, size: 18),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              _currentAddressText,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '● ${_locationStatus.text}',
                            style: TextStyle(color: _locationStatus.color, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // Map View with Moveable Map & Fullscreen Option
                      Container(
                        height: 200,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          children: [
                            FlutterMap(
                              mapController: _mapController,
                              options: MapOptions(
                                initialCenter:
                                    (_currentLocation.latitude.isFinite && _currentLocation.longitude.isFinite)
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
                                ),
                                MarkerLayer(markers: [_userPinMarker(brandOrange)]),
                              ],
                            ),

                            // Top Right Controls: GPS Recenter & Fullscreen Map
                            Positioned(
                              top: 10,
                              right: 10,
                              child: Row(
                                children: [
                                  if (!_hasActiveIncident) ...[
                                    Material(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(10),
                                      elevation: 2,
                                      child: InkWell(
                                        onTap: _useMyLocation,
                                        borderRadius: BorderRadius.circular(10),
                                        child: const Padding(
                                          padding: EdgeInsets.all(8),
                                          child: Icon(Icons.my_location_rounded, size: 20, color: Color(0xFFFF5200)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Material(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(10),
                                    elevation: 2,
                                    child: InkWell(
                                      onTap: _showFullScreenMapDialog,
                                      borderRadius: BorderRadius.circular(10),
                                      child: const Padding(
                                        padding: EdgeInsets.all(8),
                                        child: Icon(Icons.fullscreen_rounded, size: 20, color: Color(0xFF0F172A)),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Bottom Left Touch Hint
                            Positioned(
                              bottom: 10,
                              left: 10,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      _hasActiveIncident ? Icons.lock_rounded : Icons.touch_app_rounded,
                                      size: 12,
                                      color: Colors.white70,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _hasActiveIncident
                                          ? "Active Emergency Location (Locked)"
                                          : "Moveable Map · Tap to set pin",
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Emergency Type Selection
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            "🚨 Select Emergency Type",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: _hasActiveIncident ? const Color(0xFF94A3B8) : const Color(0xFF1E293B),
                            ),
                          ),
                          if (_hasActiveIncident)
                            const Text(
                              "Locked while active",
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFEF4444)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Opacity(
                        opacity: _hasActiveIncident ? 0.45 : 1.0,
                        child: IgnorePointer(
                          ignoring: _hasActiveIncident,
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  _buildCategoryCard(
                                    IncidentData.generalEmergency,
                                    agencySymbol('EOC').icon,
                                    'Not sure? We route it',
                                    agencySymbol('EOC').color,
                                  ),
                                  const SizedBox(width: 10),
                                  _buildCategoryCard(
                                    'BFP',
                                    agencySymbol('BFP').icon,
                                    'Fire',
                                    agencySymbol('BFP').color,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  _buildCategoryCard(
                                    'PNP',
                                    agencySymbol('PNP').icon,
                                    'Police',
                                    agencySymbol('PNP').color,
                                  ),
                                  const SizedBox(width: 10),
                                  _buildCategoryCard(
                                    'CDRRMO',
                                    agencySymbol('CDRRMO').icon,
                                    'Rescue & Medical',
                                    agencySymbol('CDRRMO').color,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Voice message: optional, but required after picking "Not sure"
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _voiceRequired ? "🎙️ Voice Message (Required)" : "🎙️ Voice Message (Optional)",
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: _hasActiveIncident ? const Color(0xFF94A3B8) : const Color(0xFF1E293B),
                              ),
                            ),
                          ),
                          if (_voiceRequired && _voiceNote == null)
                            const Text(
                              'Tell us what is happening',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFEF4444)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      VoiceRecorderField(
                        key: _voiceKey,
                        enabled: !_hasActiveIncident,
                        required: _voiceRequired,
                        onChanged: (f) => setState(() => _voiceNote = f),
                      ),
                      const SizedBox(height: 20),

                      // MULTI-PHOTO EVIDENCE SECTION
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            "📷 Send Evidence (Required)",
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: _hasActiveIncident ? const Color(0xFF94A3B8) : const Color(0xFF1E293B),
                            ),
                          ),
                          Text(
                            "${_uploadedImages.length}/$_maxEvidence",
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _uploadedImages.isNotEmpty ? const Color(0xFFFF6B00) : textSecondary,
                            ),
                          ),
                        ],
                      ),
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

                      Opacity(
                        opacity: _hasActiveIncident ? 0.45 : 1.0,
                        child: _uploadedImages.isEmpty
                            ? GestureDetector(
                                onTap: _hasActiveIncident ? null : _showAttachmentSourcePicker,
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    border: Border.all(color: const Color(0xFFE2E8F0)),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.camera_alt_outlined, color: textSecondary),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          _hasActiveIncident
                                              ? "Evidence locked during active incident"
                                              : "Take a photo or record a video",
                                          style: TextStyle(color: textSecondary, fontWeight: FontWeight.w500),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : SizedBox(
                                height: 110,
                                child: ListView.builder(
                                  scrollDirection: Axis.horizontal,
                                  itemCount:
                                      _uploadedImages.length +
                                      (_uploadedImages.length < _maxEvidence && !_hasActiveIncident ? 1 : 0),
                                  itemBuilder: (context, index) {
                                    if (index == _uploadedImages.length) {
                                      // Add More (+) Card
                                      return GestureDetector(
                                        onTap: _showAttachmentSourcePicker,
                                        child: Container(
                                          width: 100,
                                          height: 100,
                                          margin: const EdgeInsets.only(right: 10),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFFF7ED),
                                            borderRadius: BorderRadius.circular(14),
                                            border: Border.all(color: brandOrange, width: 1.5),
                                          ),
                                          child: Column(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              Icon(Icons.add_a_photo_rounded, color: brandOrange, size: 28),
                                              const SizedBox(height: 4),
                                              Text(
                                                "Add More",
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                  color: brandOrange,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    }

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
                                                      Icon(
                                                        Icons.play_circle_fill_rounded,
                                                        color: Colors.white,
                                                        size: 34,
                                                      ),
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
                                                decoration: const BoxDecoration(
                                                  color: Color(0xFFEF4444),
                                                  shape: BoxShape.circle,
                                                ),
                                                child: const Icon(Icons.close, color: Colors.white, size: 14),
                                              ),
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                      ),
                      const SizedBox(height: 20),

                      // Additional Notes Section
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            "Additional Notes (Optional)",
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: _hasActiveIncident ? const Color(0xFF94A3B8) : const Color(0xFF1E293B),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _descriptionController,
                        enabled: !_hasActiveIncident,
                        maxLines: 3,
                        decoration: InputDecoration(
                          hintText: _hasActiveIncident
                              ? "Active incident in progress — notes locked until resolved."
                              : "Anything else responders should know...",
                          hintStyle: TextStyle(color: textSecondary, fontWeight: FontWeight.w500),
                          filled: true,
                          fillColor: _hasActiveIncident ? const Color(0xFFF1F5F9) : Colors.white,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                          disabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(color: brandOrange),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Broadcast Button
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: (!_hasActiveIncident && _isFormValid) ? _submitEmergencyAlert : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFEF4444),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: disabledGray,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          child: Text(
                            _hasActiveIncident
                                ? "⚠️ ACTIVE INCIDENT IN PROGRESS — RESOLVE CURRENT EMERGENCY FIRST"
                                : (_isFormValid ? "🚨 BROADCAST EMERGENCY ALERT" : _missingHint),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Floats over the form; slightly see-through once content scrolls under it
            if (_hasActiveIncident)
              Positioned(
                left: 16,
                right: 16,
                top: 8,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _contentUnderBanner ? 0.88 : 1,
                  child: _MeasureSize(
                    onChange: (size) {
                      if (mounted && size.height != _bannerHeight) setState(() => _bannerHeight = size.height);
                    },
                    child: HelpIsOnTheWayBanner(
                      vehicleCode: _activeVehicleCode,
                      incidentStatus: _activeStatusStr,
                      onTap: () {
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
                      },
                    ),
                  ),
                ),
              ),
          ],
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
              color: isSelected ? color.withValues(alpha: 0.08) : Colors.white,
              border: Border.all(color: isSelected ? color : const Color(0xFFE2E8F0), width: isSelected ? 2.5 : 1),
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
                          color: isSelected ? color : const Color(0xFF1E293B),
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

/// Reports its child's size after layout (used to reserve room under the floating banner).
class _MeasureSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChange;
  const _MeasureSize({required this.onChange, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureSize renderObject) => renderObject.onChange = onChange;
}

class _RenderMeasureSize extends RenderProxyBox {
  ValueChanged<Size> onChange;
  Size? _last;
  _RenderMeasureSize(this.onChange);

  @override
  void performLayout() {
    super.performLayout();
    if (size != _last) {
      _last = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onChange(size));
    }
  }
}
