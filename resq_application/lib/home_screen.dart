import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/firebase_services.dart';
import 'services/session_service.dart';
import 'shared/resq_logo.dart';

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
  File? _uploadedImage;
  final TextEditingController _descriptionController = TextEditingController();

  String _currentAddressText = "Detecting location...";
  LatLng _currentLocation = const LatLng(13.4210, 123.4142);
  final MapController _mapController = MapController();
  bool _isLoadingLocation = false;

  AnimationController? _pulseController;
  Animation<double>? _pulseAnimation;

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

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _requestDashboardPermissions();
      await _initializeLiveTracking();
    });
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
              title: const Text('Take Real-Time Photo'),
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
              title: const Text('Choose from Photo Gallery'),
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
    final XFile? image = await picker.pickImage(
      source: source,
      imageQuality: 85,
    );
    if (image != null && mounted) {
      setState(() => _uploadedImage = File(image.path));
    }
  }

  Future<void> _submitEmergencyAlert() async {
    if (!_isFormValid) return;

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
            'Are you sure you want to broadcast a critical $_formattedEmergencyTypes alert to emergency dispatchers?',
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
      await FirebaseService.createIncident(
        citizenId: widget.citizenId,
        incidentType: _formattedEmergencyTypes,
        description: _descriptionController.text.trim(),
        latitude: _currentLocation.latitude,
        longitude: _currentLocation.longitude,
        image: _uploadedImage,
      );

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      if (!mounted) return;

      setState(() {
        _selectedEmergencyTypes.clear();
        _uploadedImage = null;
        _descriptionController.clear();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '🚨 Alert Broadcasted! Responders are being dispatched.',
          ),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
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
      _selectedEmergencyTypes.isNotEmpty && _uploadedImage != null;

  @override
  void dispose() {
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const ResqLogo(size: 44, radius: 12),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Hello, ${widget.userName} 👋",
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                          Text(
                            "Stay safe",
                            style: TextStyle(
                              color: textSecondary,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.logout,
                          color: Color(0xFFEF4444),
                        ),
                        onPressed: () async {
                          await SessionService.clearSession();
                          if (context.mounted) {
                            Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      CircleAvatar(
                        backgroundColor: Colors.white,
                        child: Icon(
                          Icons.notifications_none_outlined,
                          color: Color(0xFFFF6B00),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
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
              const Text(
                "🚨 Select Emergency Types",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
              ),
              const SizedBox(height: 12),
              Row(
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
              const SizedBox(height: 20),
              GestureDetector(
                onTap: _showAttachmentSourcePicker,
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
                  child: _uploadedImage == null
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.cloud_upload_outlined,
                              color: textSecondary,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              "Add Photo Evidence Required",
                              style: TextStyle(
                                color: textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            _uploadedImage!,
                            height: 140,
                            fit: BoxFit.contain,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                "Short Description (Optional)",
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _descriptionController,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: "Briefly describe the situation if possible...",
                  filled: true,
                  fillColor: Colors.white,
                  enabledBorder: OutlineInputBorder(
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
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isFormValid ? _submitEmergencyAlert : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: disabledGray,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    _isFormValid
                        ? "🚨 BROADCAST EMERGENCY ALERT"
                        : "Select emergency type and add photo evidence to continue",
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
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
      onTap: () {
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
