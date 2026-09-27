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
      setState(() {
        if (activeList.isNotEmpty) {
          _activeIncident = activeList.first;
          _activeStatusStr = (_activeIncident!['reqStatus'] ?? 'Pending').toString();
          final plate = _activeIncident!['plateNo'];
          final vType = _activeIncident!['vehicleType'];
          if (plate != null && plate.toString().isNotEmpty) {
            _activeVehicleCode = plate.toString();
          } else if (vType != null && vType.toString().isNotEmpty) {
            _activeVehicleCode = vType.toString();
          } else {
            _activeVehicleCode = "BFP-001";
          }
        } else {
          _activeIncident = null;
        }
      });
    }
  }

  Future<void> _requestDashboardPermissions() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    await [
      Permission.locationWhenInUse,
      Permission.camera,
      Permission.photos,
    ].request();
  }

  Future<void> _initializeLiveTracking() async {
    if (!mounted) return;
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

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      List<Placemark> placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      String barangay = placemarks.isNotEmpty
          ? (placemarks[0].subLocality ?? "")
          : "";
      String city = placemarks.isNotEmpty ? (placemarks[0].locality ?? "") : "";

      String formattedAddress = (barangay.isNotEmpty)
          ? "$barangay, $city"
          : city;

      if (!mounted) return;

      setState(() {
        _currentLocation = LatLng(position.latitude, position.longitude);
        _currentAddressText = formattedAddress.isNotEmpty
            ? formattedAddress
            : "Location Found";
        _isLoadingLocation = false;
      });

      _mapController.move(_currentLocation, 16.0);
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingLocation = false);
      }
    }
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

              // Map View
              Container(
                height: 180,
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
                        initialCenter: _currentLocation,
                        initialZoom: 15.5,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.none,
                        ),
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
                              point: _currentLocation,
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
                          ],
                        ),
                      ],
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
