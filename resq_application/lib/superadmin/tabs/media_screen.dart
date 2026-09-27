import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'dart:io';
import 'dart:async';
import '../../services/firebase_services.dart';
import '../../config.dart';

class MediaScreen extends StatefulWidget {
  // 1. Declare the search parameter variable
  final String searchFilter;

  // 2. Add it to the constructor parameters
  const MediaScreen({super.key, required this.searchFilter});

  @override
  State<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends State<MediaScreen> {
  int _selectedIncidentFilter = 0;
  bool _isGridView = true;
  bool _isLoading = true;
  late TextEditingController _searchController;
  io.Socket? _socket;

  // RxDart streams for reactive polling & buffered socket events
  StreamSubscription? _pollingSubscription;
  final PublishSubject<void> _socketEventSubject = PublishSubject<void>();
  StreamSubscription? _socketBufferSubscription;
  final BehaviorSubject<String> _searchSubject = BehaviorSubject<String>();
  StreamSubscription? _searchSubscription;

  List<Map<String, dynamic>> _incidentFilters = [];
  List<Map<String, dynamic>> _mediaItems = [];
  List<dynamic> _allIncidents = [];
  String _bottomTabFilter = 'Cancelled'; // 'Cancelled' | 'Completed'

  List<dynamic> get _cancelledIncidents => _allIncidents.where((inc) {
    if (inc is! Map) return false;
    final s = (inc['status'] ?? inc['reqStatus'] ?? inc['Status'] ?? '').toString().toLowerCase();
    return s == 'cancelled' || s == 'declined';
  }).toList();

  List<dynamic> get _completedIncidents => _allIncidents.where((inc) {
    if (inc is! Map) return false;
    final s = (inc['status'] ?? inc['reqStatus'] ?? inc['Status'] ?? '').toString().toLowerCase();
    return s == 'completed';
  }).toList();

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.searchFilter);
    _loadMediaData(showLoading: true);
    _setupRxDartStreams();
    _initWebSocket();
  }

  void _setupRxDartStreams() {
    // RxDart periodic polling every 10 seconds
    _pollingSubscription = Stream.periodic(const Duration(seconds: 10))
        .listen((_) => _loadMediaData(showLoading: false));

    // Buffer rapid socket events into 500ms windows
    _socketBufferSubscription = _socketEventSubject
        .bufferTime(const Duration(milliseconds: 500))
        .where((batch) => batch.isNotEmpty)
        .listen((_) => _loadMediaData(showLoading: false));

    // Debounce search input
    _searchSubscription = _searchSubject
        .debounceTime(const Duration(milliseconds: 300))
        .distinct()
        .listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pollingSubscription?.cancel();
    _socketBufferSubscription?.cancel();
    _socketEventSubject.close();
    _searchSubscription?.cancel();
    _searchSubject.close();
    _socket?.disconnect();
    _searchController.dispose();
    super.dispose();
  }

  void _initWebSocket() {
    try {
      _socket = io.io(AppConfig.apiBaseUrl.replaceAll('/api', ''), <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      });

      _socket!.on('refreshMediaGalleryEvent', (_) {
        if (mounted) {
          _socketEventSubject.add(null);
        }
      });

      _socket!.connect();
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant MediaScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchFilter != widget.searchFilter) {
      _searchController.text = widget.searchFilter;
    }
  }

  Future<void> _loadMediaData({bool showLoading = true}) async {
    if (mounted && showLoading) setState(() => _isLoading = true);
    
    try {
      // Fetch both media items and filters in parallel with timeout
      final results = await Future.wait([
        FirebaseService.getMediaGallery().timeout(const Duration(seconds: 10)),
        FirebaseService.getMediaFilters().timeout(const Duration(seconds: 10)),
        FirebaseService.getActiveIncidents().timeout(const Duration(seconds: 10)),
      ]);

      final newMediaItems = results[0].map((item) => item as Map<String, dynamic>).toList();
      final newIncidentFilters = results[1].map((item) => item as Map<String, dynamic>).toList();
      final incidentsData = results[2];

      if (mounted) {
        setState(() {
          _mediaItems = newMediaItems;
          _incidentFilters = newIncidentFilters;
          _allIncidents = incidentsData;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _mediaItems = [];
          _incidentFilters = [{'label': 'All Incidents', 'count': 0, 'color': null}];
          _selectedIncidentFilter = 0;
          _isLoading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> get _filteredMedia {
    final query = _searchController.text.toLowerCase().trim();
    final selectedIncidentLabel = _selectedIncidentFilter < _incidentFilters.length 
        ? _incidentFilters[_selectedIncidentFilter]['label'] 
        : 'All Incidents';

    // Optimized filtering with early returns
    return _mediaItems.where((item) {
      // Incident filter match by category (early return for performance)
      if (_selectedIncidentFilter != 0 && item['category']?.toString() != selectedIncidentLabel) {
        return false;
      }

      // Skip text query if empty (early return)
      if (query.isEmpty) {
        return true;
      }

      // Text query match across filename, incident ID, category, or tags
      return (item['filename']?.toString() ?? '').toLowerCase().contains(query) ||
          (item['incidentId']?.toString() ?? '').toLowerCase().contains(query) ||
          (item['category']?.toString() ?? '').toLowerCase().contains(query) ||
          (item['tags'] as List? ?? []).any((t) => t.toString().toLowerCase().contains(query));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filteredList = _filteredMedia;

    if (_isLoading) {
      return Container(
        color: const Color(0xFFF8FAFC),
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Container(
      color: const Color(0xFFF8FAFC),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // LEFT PANEL: GALLERY SUMMARY & BY INCIDENT
            SizedBox(
              width: 240,
              child: Column(
                children: [
                  _buildGallerySummaryCard(),
                  const SizedBox(height: 16),
                  _buildByIncidentCard(),
                  const SizedBox(height: 16),
                  _buildCancelledRequestsColumn(),
                ],
              ),
            ),
            const SizedBox(width: 20),

            // RIGHT PANEL: MEDIA GRID / LIST VIEW
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // GRID HEADER BAR
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "${filteredList.length} photos found",
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF64748B),
                        ),
                      ),
                      // GRID / LIST VIEW TOGGLE
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            _buildViewToggleBtn(
                              label: "Grid",
                              isSelected: _isGridView,
                              onTap: () => setState(() => _isGridView = true),
                            ),
                            _buildViewToggleBtn(
                              label: "List",
                              isSelected: !_isGridView,
                              onTap: () => setState(() => _isGridView = false),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // MEDIA GRID OR LIST
                  filteredList.isEmpty
                      ? Container(
                          padding: EdgeInsets.all(40),
                          alignment: Alignment.center,
                          child: Text(
                            "No evidence media matches your criteria.",
                            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                          ),
                        )
                      : _isGridView
                          ? GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                crossAxisSpacing: 16,
                                mainAxisSpacing: 16,
                                childAspectRatio: 0.88,
                              ),
                              itemCount: filteredList.length,
                              itemBuilder: (context, index) {
                                return InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () => _showImageDetailsModal(context, filteredList[index]),
                                  child: _buildMediaCard(filteredList[index]),
                                );
                              },
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: filteredList.length,
                              separatorBuilder: (context, index) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                return InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () => _showImageDetailsModal(context, filteredList[index]),
                                  child: _buildMediaListItem(filteredList[index]),
                                );
                              },
                            ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // GALLERY SUMMARY CARD
  // ==========================================
  Widget _buildGallerySummaryCard() {
    // Calculate dynamic statistics
    final photoCount = _mediaItems.length;
    final uniqueIncidents = _mediaItems.map((item) => item['incidentId']).toSet().length;
    final latestUpload = _mediaItems.isNotEmpty ? (_mediaItems.first['time']?.toString() ?? '--:--') : '--:--';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF1F5F9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "GALLERY SUMMARY",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Color(0xFF94A3B8),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.insert_photo_outlined, size: 14, color: Color(0xFF94A3B8)),
                  SizedBox(width: 6),
                  Text("Photo Evidence", style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                ],
              ),
              Text("$photoCount", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFFF5200))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Active Incidents", style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
              Text("$uniqueIncidents", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Latest Upload", style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
              Text(latestUpload, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================
  // BY INCIDENT FILTER CARD
  // ==========================================
  Widget _buildByIncidentCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF1F5F9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "BY INCIDENT",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Color(0xFF94A3B8),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 12),
          Column(
            children: List.generate(_incidentFilters.length, (index) {
              final item = _incidentFilters[index];
              final isSelected = _selectedIncidentFilter == index;
              final filterColor = _parseColor(item['color']);

              return Padding(
                padding: const EdgeInsets.only(bottom: 4.0),
                child: InkWell(
                  onTap: () => setState(() => _selectedIncidentFilter = index),
                  borderRadius: BorderRadius.circular(10),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFFFFF7ED) : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            if (item['color'] != null) ...[
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: filterColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Text(
                              item['label'],
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                color: isSelected ? const Color(0xFFFF5200) : const Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFFFF5200) : const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            "${item['count']}",
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: isSelected ? Colors.white : const Color(0xFF94A3B8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // PIXEL ACCURATE MEDIA CARD (GRID)
  // ==========================================
  Widget _buildMediaCard(Map<String, dynamic> item) {
    // Parse color strings to Color objects
    final categoryColor = _parseColor(item['categoryColor']);
    final bgColor = _parseColor(item['bgColor']);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF1F5F9), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Banner with Actual Image
          Container(
            height: 108,
            width: double.infinity,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(15),
                topRight: Radius.circular(15),
              ),
            ),
            child: Stack(
              children: [
                // Actual Image from Database
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(15),
                      topRight: Radius.circular(15),
                    ),
                    child: Image.network(
                      _getFullImageUrl(item['imagePath']?.toString() ?? item['image_path']?.toString() ?? ''),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        // Fallback to colored background if image fails to load
                        return Container(
                          color: bgColor,
                          child: const Center(
                            child: Icon(
                              Icons.broken_image_rounded,
                              size: 28,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                        );
                      },
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Container(
                          color: bgColor,
                          child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      item['category']?.toString() ?? 'General',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: categoryColor,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      item['ext']?.toString() ?? 'JPG',
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF475569),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Card Details
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item['filename']?.toString() ?? 'Unknown',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item['incidentId']?.toString() ?? '',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        children: List.generate(
                          (item['tags'] as List? ?? []).length,
                          (tIndex) => Text(
                            item['tags'][tIndex],
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        item['time']?.toString() ?? '--:--',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFFCBD5E1),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        item['size']?.toString() ?? 'Photo',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFFCBD5E1),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Helper method to parse color strings with caching
  final Map<String, Color> _colorCache = {};
  
  Color _parseColor(dynamic colorValue) {
    if (colorValue == null) return const Color(0xFF64748B);
    
    if (colorValue is Color) return colorValue;
    
    if (colorValue is String) {
      // Check cache first
      if (_colorCache.containsKey(colorValue)) {
        return _colorCache[colorValue]!;
      }
      
      // Handle hex color strings like "#FF5200"
      if (colorValue.startsWith('#')) {
        final color = Color(int.parse(colorValue.substring(1), radix: 16) + 0xFF000000);
        _colorCache[colorValue] = color;
        return color;
      }
    }
    
    return const Color(0xFF64748B);
  }

  // Helper method to get full image URL (same as incident_screen)
  String _getFullImageUrl(String? imagePath) {
    if (imagePath == null || imagePath.isEmpty) return '';
    if (imagePath.startsWith('http://') || imagePath.startsWith('https://')) {
      return imagePath;
    }
    final cleanPath = imagePath.startsWith('/') ? imagePath.substring(1) : imagePath;
    return '${AppConfig.baseUrl}/$cleanPath';
  }

  // ==========================================
  // IMAGE PREVIEW MODAL (FIGMA MATCH)
  // ==========================================
  void _showImageDetailsModal(BuildContext context, Map<String, dynamic> item) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Container(
            width: 480,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. TOP IMAGE BANNER WITH ACTUAL IMAGE & BADGE
                  SizedBox(
                    height: 220,
                    width: double.infinity,
                    child: Stack(
                      children: [
                        // Actual Image from Database
                        Positioned.fill(
                          child: Image.network(
                            _getFullImageUrl(item['imagePath']?.toString() ?? item['image_path']?.toString() ?? ''),
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              // Fallback to colored background if image fails to load
                              return Container(
                                color: _parseColor(item['bgColor']),
                                child: const Center(
                                  child: Icon(
                                    Icons.broken_image_rounded,
                                    size: 40,
                                    color: Color(0xFF94A3B8),
                                  ),
                                ),
                              );
                            },
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return Container(
                                color: _parseColor(item['bgColor']),
                                child: const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            },
                          ),
                        ),
                        // Close Button (Top Right)
                        Positioned(
                          top: 14,
                          right: 14,
                          child: InkWell(
                            onTap: () => Navigator.of(context).pop(),
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close_rounded,
                                size: 16,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ),
                        ),
                        // JPG · Size Badge (Bottom Left)
                        Positioned(
                          bottom: 14,
                          left: 14,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              "${item['ext']?.toString() ?? 'JPG'} · ${item['size']?.toString() ?? 'Photo'}",
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF475569),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 2. MODAL BODY DETAILS
                  Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Filename Title
                        Text(
                          item['filename']?.toString() ?? 'Unknown',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(height: 4),
                        // Subtitle Timestamp & Address
                        Text(
                          "Uploaded ${item['time']?.toString() ?? '--:--'} · ${item['location']?.toString() ?? 'Iriga City'}",
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // 2x2 Grid Info Box
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildModalInfoItem(
                                      "Incident ID",
                                      item['incidentId']?.toString() ?? 'N/A',
                                    ),
                                  ),
                                  Expanded(
                                    child: _buildModalInfoItem(
                                      "Type",
                                      item['category']?.toString() ?? 'General',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildModalInfoItem(
                                      "Uploaded By",
                                      item['reporterName'] ?? 'Unknown',
                                    ),
                                  ),
                                  Expanded(
                                    child: _buildModalInfoItem(
                                      "Location",
                                      item['location'] ?? 'Iriga City',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),

                        // TAGS HEADER
                        Row(
                          children: const [
                            Icon(Icons.sell_outlined,
                                size: 14, color: Color(0xFF94A3B8)),
                            SizedBox(width: 6),
                            Text(
                              "TAGS",
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF94A3B8),
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        // Hashtag Pills
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: (item['tags'] as List? ?? []).map<Widget>((tag) {
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF7ED),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                tag,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFEA580C),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 20),

                        // ACTION BUTTONS (View Full & Download)
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => _showFullScreenImage(item['imagePath']?.toString() ?? item['image_path']?.toString() ?? ''),
                                icon: const Icon(Icons.remove_red_eye_outlined,
                                    size: 16, color: Colors.white),
                                label: const Text(
                                  "View Full",
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2563EB),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => _downloadImage(item['imagePath']?.toString() ?? item['image_path']?.toString() ?? '', item['filename']?.toString() ?? 'download.jpg'),
                                icon: const Icon(Icons.download_rounded,
                                    size: 16, color: Colors.white),
                                label: const Text(
                                  "Download",
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF10B981),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 14),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildModalInfoItem(String label, String? value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: Color(0xFF94A3B8),
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value ?? 'N/A',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Color(0xFF0F172A),
          ),
        ),
      ],
    );
  }

  // ==========================================
  // MEDIA LIST ITEM (ALTERNATIVE VIEW)
  // ==========================================
  Widget _buildMediaListItem(Map<String, dynamic> item) {
    final bgColor = _parseColor(item['bgColor']);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF1F5F9)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                _getFullImageUrl(item['imagePath']?.toString() ?? item['image_path']?.toString() ?? ''),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(Icons.photo_camera_rounded, color: Color(0xFF1E293B), size: 20);
                },
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                },
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['filename']?.toString() ?? 'Unknown',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                ),
                const SizedBox(height: 2),
                Text(
                  "${item['incidentId']?.toString() ?? ''} · ${(item['tags'] as List? ?? []).join(' ')}",
                  style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
          ),
          Text(
            item['time']?.toString() ?? '--:--',
            style: const TextStyle(fontSize: 11, color: Color(0xFFCBD5E1)),
          ),
          const SizedBox(width: 16),
          Text(
            item['size']?.toString() ?? 'Photo',
            style: const TextStyle(fontSize: 11, color: Color(0xFFCBD5E1)),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // VIEW TOGGLE BUTTON
  // ==========================================
  Widget _buildViewToggleBtn({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFF5200) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: isSelected ? Colors.white : const Color(0xFF64748B),
          ),
        ),
      ),
    );
  }

  // ==========================================
  // FULL SCREEN IMAGE VIEW
  // ==========================================
  void _showFullScreenImage(String? imagePath) {
    if (imagePath == null || imagePath.isEmpty) return;
    
    final fullImageUrl = _getFullImageUrl(imagePath);
    
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.zero,
          child: Stack(
            children: [
              // Full screen image
              Center(
                child: InteractiveViewer(
                  child: Image.network(
                    fullImageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.broken_image_rounded, size: 64, color: Colors.white),
                            SizedBox(height: 16),
                            Text('Failed to load image', style: TextStyle(color: Colors.white)),
                          ],
                        ),
                      );
                    },
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      );
                    },
                  ),
                ),
              ),
              // Close button
              Positioned(
                top: 20,
                right: 20,
                child: InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 24,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ==========================================
  // DOWNLOAD IMAGE FUNCTIONALITY
  // ==========================================
  Future<void> _downloadImage(String? imagePath, String? filename) async {
    if (imagePath == null || imagePath.isEmpty) return;
    final safeFilename = (filename != null && filename.isNotEmpty) ? filename : 'download.jpg';
    
    try {
      final fullImageUrl = _getFullImageUrl(imagePath);
      
      // Show loading indicator
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Row(
          children: [
            SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 16),
            Text('Downloading image...'),
          ],
        )),
      );
      
      // Download the image
      final response = await http.get(Uri.parse(fullImageUrl));
      
      if (response.statusCode == 200) {
        // Get download directory
        final directory = await getDownloadsDirectory();
        
        if (directory == null) {
          throw Exception('Could not access downloads directory');
        }
        
        final file = File('${directory.path}/$safeFilename');
        
        // Save the file
        await file.writeAsBytes(response.bodyBytes);
        
        // Show success message
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Image saved to ${directory.path}'),
              backgroundColor: const Color(0xFF10B981),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else {
        throw Exception('Failed to download image: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to download image: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }
  }

  Widget _buildCancelledRequestsColumn() {
    final isCancelledTab = _bottomTabFilter == 'Cancelled';
    final list = isCancelledTab ? _cancelledIncidents : _completedIncidents;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isCancelledTab ? const Color(0xFFFFF5F5) : const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isCancelledTab ? const Color(0xFFFFDDE1) : const Color(0xFFBBF7D0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Cancelled Tab Pill
              InkWell(
                onTap: () => setState(() => _bottomTabFilter = 'Cancelled'),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isCancelledTab ? const Color(0xFFFFDDE1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.cancel_outlined, size: 13, color: Color(0xFFEB5757)),
                      const SizedBox(width: 4),
                      Text(
                        'Cancelled',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isCancelledTab ? const Color(0xFFEB5757) : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),

              // Completed Tab Pill
              InkWell(
                onTap: () => setState(() => _bottomTabFilter = 'Completed'),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: !isCancelledTab ? const Color(0xFFBBF7D0) : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline, size: 13, color: Color(0xFF16A34A)),
                      const SizedBox(width: 4),
                      Text(
                        'Completed',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: !isCancelledTab ? const Color(0xFF16A34A) : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isCancelledTab ? const Color(0xFFFFE5E5) : const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${list.length}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isCancelledTab ? const Color(0xFFEB5757) : const Color(0xFF16A34A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text(
                      isCancelledTab ? 'No cancelled requests' : 'No completed incidents',
                      style: const TextStyle(fontSize: 11, color: Color(0xFFA0A0A0)),
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: list.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final req = list[index];
                    return _buildCancelledCard(req);
                  },
                ),
        ],
      ),
    );
  }

  Widget _buildCancelledCard(dynamic req) {
    if (req is! Map) return const SizedBox.shrink();

    final reqId = req['Request_ID'] ?? req['Req_ID'] ?? req['reqId'] ?? req['id'] ?? req['emergency_id'];
    final reqIdStr = reqId != null ? (reqId.toString().startsWith('REQ-') ? reqId.toString() : 'REQ-${reqId.toString().padLeft(4, '0')}') : 'REQ-000';
    final type = (req['Emergency_Type'] ?? req['type'] ?? req['incType'] ?? 'Emergency').toString();
    final status = (req['Status'] ?? req['status'] ?? req['reqStatus'] ?? 'Declined').toString();
    final isCompleted = status.toLowerCase() == 'completed';

    final primaryColor = isCompleted ? const Color(0xFF16A34A) : const Color(0xFFEB5757);
    final badgeBgColor = isCompleted ? const Color(0xFFF0FDF4) : const Color(0xFFFFF0F0);

    final filterText = reqId != null ? 'INC-$reqId' : type;
    final isSelected = _searchController.text.toLowerCase().trim() == filterText.toLowerCase().trim();

    return InkWell(
      onTap: () {
        setState(() {
          if (isSelected) {
            _searchController.clear();
          } else {
            _searchController.text = filterText;
          }
        });
        _searchSubject.add(_searchController.text);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? (isCompleted ? const Color(0xFFDCFCE7) : const Color(0xFFFFEAEA)) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? primaryColor : const Color(0xFFEEEEEE),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isCompleted ? Icons.check_circle_outline : Icons.cancel_outlined,
              size: 14,
              color: primaryColor,
            ),
            const SizedBox(width: 6),
            Text(
              reqIdStr,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFF212121),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                type,
                style: const TextStyle(fontSize: 11, color: Color(0xFF757575)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: badgeBgColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                status,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: primaryColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}