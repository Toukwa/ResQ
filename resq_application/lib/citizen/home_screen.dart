import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/firebase_services.dart';
import 'citizen_header.dart';
import 'incident_status_screen.dart';

class HelpIsOnTheWayBanner extends StatelessWidget {
  final String vehicleCode;
  final String incidentStatus;
  final VoidCallback? onTap;

  const HelpIsOnTheWayBanner({
    super.key,
    this.vehicleCode = "BFP-001",
    this.incidentStatus = "Pending",
    this.onTap,
  });

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
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.info_outline_rounded,
                color: Colors.white,
                size: 18,
              ),
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
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.4),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    incidentStatus,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
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

  const HomeScreen({
    super.key,
    required this.citizenId,
    required this.userName,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final Set<String> _selectedEmergencyTypes = {};
  String get _formattedEmergencyTypes => _selectedEmergencyTypes.join(', ');
  final List<File> _uploadedImages = [];
  final TextEditingController _descriptionController = TextEditingController();

  String _currentAddressText = "Detecting location...";
  LatLng _currentLocation = const LatLng(13.4210, 123.4142);
  final MapController _mapController = MapController();
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

  @override
  void initState() {
    super.initState();
    _descriptionController.addListener(() => setState(() {}));

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 8.0, end: 24.0).animate(
      CurvedAnimation(parent: _pulseController!, curve: Curves.easeInOut),
    );

    _checkActiveIncident();
    _activeCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _checkActiveIncident();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _requestDashboardPermissions();
      await _initializeLiveTracking();
    });
  }

  Future<void> _checkActiveIncident() async {
    final reqs = await FirebaseService.getCitizenEmergencyRequests(widget.citizenId);
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

            // Lock pin to reported active incident coordinates
            final rawLat = double.tryParse((_activeIncident!['latitude'] ?? '').toString());
            final rawLng = double.tryParse((_activeIncident!['longitude'] ?? '').toString());
            if (rawLat != null && rawLng != null && rawLat.isFinite && rawLng.isFinite && !rawLat.isNaN && !rawLng.isNaN) {
              _currentLocation = LatLng(rawLat, rawLng);
            }
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _activeIncident = null;
            _dispatchedVehicles = [];
          });
        }
      }
    }
  }

  List<Marker> _buildDispatchedVehicleMarkers() {
    if (!_hasActiveIncident || _dispatchedVehicles.isEmpty) return [];

    final List<Marker> markers = [];
    for (int i = 0; i < _dispatchedVehicles.length; i++) {
      final v = _dispatchedVehicles[i];
      if (v is! Map) continue;
      final rawLat = double.tryParse((v['latitude'] ?? '').toString());
      final rawLng = double.tryParse((v['longitude'] ?? '').toString());

      // If live GPS coordinates are missing, position slightly offset from emergency pin for visibility
      double vLat = (rawLat != null && rawLat.isFinite && !rawLat.isNaN)
          ? rawLat
          : (_currentLocation.latitude + (0.0015 * (i + 1)));
      double vLng = (rawLng != null && rawLng.isFinite && !rawLng.isNaN)
          ? rawLng
          : (_currentLocation.longitude + (0.0015 * (i + 1)));

      if (!vLat.isFinite || !vLng.isFinite || vLat.isNaN || vLng.isNaN) continue;

      final plate = (v['plate_no'] ?? v['vehicle_type'] ?? 'Unit').toString();
      final type = (v['vehicle_type'] ?? v['deptName'] ?? '').toString().toUpperCase();

      Color color = const Color(0xFFEF4444); // BFP Red
      IconData icon = Icons.local_fire_department_rounded;
      if (type.contains('MED') || type.contains('AMBULANCE') || type.contains('CDRRMO')) {
        color = const Color(0xFF2563EB); // CDRRMO Blue
        icon = Icons.medical_services_rounded;
      } else if (type.contains('POL') || type.contains('CRIME') || type.contains('PNP')) {
        color = const Color(0xFF1E40AF); // PNP Navy
        icon = Icons.local_police_rounded;
      }

      markers.add(
        Marker(
          point: LatLng(vLat, vLng),
          width: 90,
          height: 65,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 4,
                    ),
                  ],
                  border: Border.all(color: color, width: 1.5),
                ),
                child: Text(
                  plate,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 16),
              ),
            ],
          ),
        ),
      );
    }
    return markers;
  }

  Future<void> _requestDashboardPermissions() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    await [
      Permission.locationWhenInUse,
      Permission.camera,
      Permission.photos,
    ].request();
  }

  Future<void> _updateLocationFromLatLng(LatLng point) async {
    if (!mounted) return;
    // Citizens cannot change/update location while an active incident is in progress
    if (_hasActiveIncident) return;

    LatLng safePoint = point;
    if (!point.latitude.isFinite || !point.longitude.isFinite || point.latitude.isNaN || point.longitude.isNaN) {
      safePoint = const LatLng(13.4210, 123.4142);
    }

    setState(() {
      _currentLocation = safePoint;
      _isLoadingLocation = true;
    });
    _mapController.move(safePoint, 16.0);

    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(
        safePoint.latitude,
        safePoint.longitude,
      );

      String barangay = placemarks.isNotEmpty
          ? (placemarks[0].subLocality ?? placemarks[0].name ?? "")
          : "";
      String city = placemarks.isNotEmpty ? (placemarks[0].locality ?? placemarks[0].subAdministrativeArea ?? "") : "";

      String formattedAddress = (barangay.isNotEmpty && city.isNotEmpty)
          ? "$barangay, $city"
          : (barangay.isNotEmpty ? barangay : (city.isNotEmpty ? city : "Iriga City"));

      if (mounted) {
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
    if (_hasActiveIncident) return;
    setState(() => _isLoadingLocation = true);

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _currentAddressText = "Location Access Denied";
            _isLoadingLocation = false;
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
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 10),
        ),
      );

      _updateLocationFromLatLng(LatLng(position.latitude, position.longitude));
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingLocation = false);
      }
    }
  }

  void _showFullScreenMapDialog() {
    final LatLng safeLocation = (_currentLocation.latitude.isFinite &&
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
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.all,
                        ),
                        onTap: _hasActiveIncident
                            ? null
                            : (tapPosition, point) {
                                if (point.latitude.isFinite &&
                                    point.longitude.isFinite &&
                                    !point.latitude.isNaN &&
                                    !point.longitude.isNaN) {
                                  _updateLocationFromLatLng(point);
                                  setDialogState(() {});
                                }
                              },
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.resq',
                        ),
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: safeLocation,
                              width: 60,
                              height: 60,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: brandOrange.withValues(alpha: 0.3),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const Icon(
                                    Icons.location_on_rounded,
                                    color: Color(0xFFFF5200),
                                    size: 38,
                                  ),
                                ],
                              ),
                            ),
                            ..._buildDispatchedVehicleMarkers(),
                          ],
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
                            await _initializeLiveTracking();
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

  Future<void> _showAttachmentSourcePicker() async {
    if (_hasActiveIncident || _uploadedImages.length >= 5) return;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Take Photo with Camera'),
              onTap: () async {
                Navigator.pop(context);
                var status = await Permission.camera.request();
                if (status.isGranted) {
                  _pickImage(ImageSource.camera);
                } else {
                  _showPermissionDeniedSnackBar('Camera');
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Select Photos from Gallery'),
              onTap: () async {
                Navigator.pop(context);
                var status = await Permission.photos.request();
                if (status.isGranted || status.isLimited) {
                  _pickImage(ImageSource.gallery);
                } else {
                  var storageStatus = await Permission.storage.request();
                  if (storageStatus.isGranted) {
                    _pickImage(ImageSource.gallery);
                  } else {
                    _showPermissionDeniedSnackBar('Gallery/Storage');
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showPermissionDeniedSnackBar(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '❌ $feature permission is required to upload evidence. Please enable it in system settings.',
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.red,
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    final ImagePicker picker = ImagePicker();
    if (source == ImageSource.gallery) {
      final List<XFile> pickedList = await picker.pickMultiImage(imageQuality: 85);
      if (pickedList.isNotEmpty && mounted) {
        setState(() {
          for (var item in pickedList) {
            if (_uploadedImages.length < 5) {
              _uploadedImages.add(File(item.path));
            }
          }
        });
      }
    } else {
      final XFile? image = await picker.pickImage(
        source: source,
        imageQuality: 85,
      );
      if (image != null && mounted) {
        setState(() {
          if (_uploadedImages.length < 5) {
            _uploadedImages.add(File(image.path));
          }
        });
      }
    }
  }

  Future<void> _submitEmergencyAlert() async {
    if (_hasActiveIncident || !_isFormValid) return;

    bool confirmBroadcast = false;
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: const [
              Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFEF4444),
                size: 28,
              ),
              SizedBox(width: 10),
              Text(
                'Confirm Broadcast',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Text(
            'Are you sure you want to broadcast a critical $_formattedEmergencyTypes alert with ${_uploadedImages.length} photo(s) to emergency dispatchers?',
            style: const TextStyle(fontSize: 15),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Cancel',
                style: TextStyle(
                  color: Color(0xFF64748B),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                confirmBroadcast = true;
                Navigator.of(context).pop();
              },
              child: const Text(
                'Confirm',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );

    if (!confirmBroadcast) return;
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF6B00)),
        ),
      ),
    );

    try {
      final typesSelected = _formattedEmergencyTypes;
      final emergencyId = await FirebaseService.createIncident(
        citizenId: widget.citizenId,
        incidentType: typesSelected,
        description: _descriptionController.text.trim(),
        latitude: _currentLocation.latitude,
        longitude: _currentLocation.longitude,
        images: _uploadedImages,
      );

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      if (!mounted) return;

      setState(() {
        _selectedEmergencyTypes.clear();
        _uploadedImages.clear();
        _descriptionController.clear();
      });

      await _checkActiveIncident();

      if (!mounted) return;

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => IncidentStatusScreen(
            citizenId: widget.citizenId,
            userName: widget.userName,
            emergencyId: emergencyId,
            emergencyTypes: typesSelected,
          ),
        ),
      ).then((_) => _checkActiveIncident());
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to broadcast critical alert packet: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  bool get _isFormValid =>
      !_hasActiveIncident &&
      _selectedEmergencyTypes.isNotEmpty &&
      _uploadedImages.isNotEmpty;

  @override
  void dispose() {
    _activeCheckTimer?.cancel();
    _descriptionController.dispose();
    _pulseController?.dispose();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Citizen Header
              CitizenHeader(userName: widget.userName),
              const SizedBox(height: 16),

              // HELP IS ON THE WAY BANNER
              if (_hasActiveIncident) ...[
                HelpIsOnTheWayBanner(
                  vehicleCode: _activeVehicleCode,
                  incidentStatus: _activeStatusStr,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => IncidentStatusScreen(
                          citizenId: widget.citizenId,
                          userName: widget.userName,
                          emergencyId: _activeIncident!['Req_ID'].toString(),
                          emergencyTypes: (_activeIncident!['incType'] ?? 'Emergency').toString(),
                        ),
                      ),
                    ).then((_) => _checkActiveIncident());
                  },
                ),
                const SizedBox(height: 16),
              ],

              // Location Status Bar
              Row(
                children: [
                  Icon(
                    Icons.location_on_outlined,
                    color: brandOrange,
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _currentAddressText,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF475569),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isLoadingLocation ? "Syncing..." : "● GPS Locked",
                    style: TextStyle(
                      color: _isLoadingLocation
                          ? Colors.orange
                          : const Color(0xFF16A34A),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
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
                        initialCenter: (_currentLocation.latitude.isFinite && _currentLocation.longitude.isFinite)
                            ? _currentLocation
                            : const LatLng(13.4210, 123.4142),
                        initialZoom: 16.0,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.all,
                        ),
                        onTap: _hasActiveIncident ? null : (tapPosition, point) => _updateLocationFromLatLng(point),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.resq',
                        ),
                        MarkerLayer(
                          markers: [
                            Marker(
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
                                      decoration: BoxDecoration(
                                        color: brandOrange.withValues(alpha: 0.25),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    Container(
                                      width: 14,
                                      height: 14,
                                      decoration: const BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Center(
                                        child: Container(
                                          width: 9,
                                          height: 9,
                                          decoration: BoxDecoration(
                                            color: brandOrange,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            ..._buildDispatchedVehicleMarkers(),
                          ],
                        ),
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
                                onTap: _initializeLiveTracking,
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
                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
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
                    "🚨 Select Emergency Types",
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
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildCategoryCard(
                        'Fire',
                        Icons.local_fire_department_outlined,
                        'BFP',
                        const Color(0xFFDC2626),
                      ),
                      _buildCategoryCard(
                        'Medical',
                        Icons.favorite_border_rounded,
                        'CDRRMO',
                        const Color(0xFF16A34A),
                      ),
                      _buildCategoryCard(
                        'Accident',
                        Icons.warning_amber_rounded,
                        'PNP',
                        const Color(0xFFEAB308),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // MULTI-PHOTO EVIDENCE SECTION
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "📷 Photo Evidence Required",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: _hasActiveIncident ? const Color(0xFF94A3B8) : const Color(0xFF1E293B),
                    ),
                  ),
                  Text(
                    "${_uploadedImages.length}/5 photos",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _uploadedImages.isNotEmpty ? const Color(0xFFFF6B00) : textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              Opacity(
                opacity: _hasActiveIncident ? 0.45 : 1.0,
                child: _uploadedImages.isEmpty
                    ? GestureDetector(
                        onTap: _hasActiveIncident ? null : _showAttachmentSourcePicker,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            vertical: 24,
                            horizontal: 16,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.cloud_upload_outlined,
                                color: textSecondary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _hasActiveIncident
                                      ? "Photo upload locked during active incident"
                                      : "Add Photo Evidence (Up to 5 Photos)",
                                  style: TextStyle(
                                    color: textSecondary,
                                    fontWeight: FontWeight.w500,
                                  ),
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
                          itemCount: _uploadedImages.length + (_uploadedImages.length < 5 && !_hasActiveIncident ? 1 : 0),
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
                                  child: Image.file(
                                    imgFile,
                                    fit: BoxFit.cover,
                                  ),
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
                                        child: const Icon(
                                          Icons.close,
                                          color: Colors.white,
                                          size: 14,
                                        ),
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

              // Short Description Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Short Description (Optional)",
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
                      ? "Active incident in progress — description locked until resolved."
                      : "Briefly describe the situation if possible...",
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
              const SizedBox(height: 28),

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
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    _hasActiveIncident
                        ? "⚠️ ACTIVE INCIDENT IN PROGRESS — RESOLVE CURRENT EMERGENCY FIRST"
                        : (_isFormValid
                            ? "🚨 BROADCAST EMERGENCY ALERT"
                            : "Select emergency type and add photo evidence to continue"),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryCard(
    String type,
    IconData icon,
    String agency,
    Color color,
  ) {
    bool isSelected = _selectedEmergencyTypes.contains(type);
    return GestureDetector(
      onTap: _hasActiveIncident
          ? null
          : () {
              setState(() {
                if (isSelected) {
                  _selectedEmergencyTypes.remove(type);
                } else {
                  _selectedEmergencyTypes.add(type);
                }
              });
            },
      child: Container(
        width: MediaQuery.of(context).size.width * 0.28,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.08) : Colors.white,
          border: Border.all(
            color: isSelected ? color : const Color(0xFFE2E8F0),
            width: isSelected ? 2.5 : 1,
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.15),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  )
                ]
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
                    agency,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: textSecondary),
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
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check,
                    color: Colors.white,
                    size: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
