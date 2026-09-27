import 'package:flutter/material.dart';
import '../config.dart';

/// Parses a comma-separated image path string into a list of fully-resolved URLs.
List<String> parseImageUrls(String? rawPath) {
  if (rawPath == null || rawPath.trim().isEmpty) return [];
  var cleanInput = rawPath.trim();
  // Handle JSON string array formatted input like ["path1", "path2"]
  if (cleanInput.startsWith('[') && cleanInput.endsWith(']')) {
    cleanInput = cleanInput.substring(1, cleanInput.length - 1).replaceAll('"', '').replaceAll("'", '');
  }
  final base = AppConfig.baseUrl.endsWith('/')
      ? AppConfig.baseUrl.substring(0, AppConfig.baseUrl.length - 1)
      : AppConfig.baseUrl;
  return cleanInput
      .split(',')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .map((p) {
        if (p.startsWith('http://') || p.startsWith('https://')) return p;
        final clean = p.startsWith('/') ? p : '/$p';
        return '$base$clean';
      })
      .toList();
}

/// Builds the first resolved URL (used for banner thumbnails).
String? resolveFirstImageUrl(String? rawPath) {
  final urls = parseImageUrls(rawPath);
  return urls.isEmpty ? null : urls.first;
}

// ---------------------------------------------------------------------------
// PagedImageGalleryBanner — interactive banner with Next/Prev & Page Counter
// ---------------------------------------------------------------------------
class PagedImageGalleryBanner extends StatefulWidget {
  final String rawImagePath;
  final double height;
  final String type;
  final String? title;

  const PagedImageGalleryBanner({
    super.key,
    required this.rawImagePath,
    this.height = 160,
    this.type = 'Emergency',
    this.title,
  });

  @override
  State<PagedImageGalleryBanner> createState() => _PagedImageGalleryBannerState();
}

class _PagedImageGalleryBannerState extends State<PagedImageGalleryBanner> {
  late PageController _pageController;
  late List<String> _urls;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _urls = parseImageUrls(widget.rawImagePath);
    _pageController = PageController(initialPage: 0);
  }

  @override
  void didUpdateWidget(covariant PagedImageGalleryBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rawImagePath != widget.rawImagePath) {
      _urls = parseImageUrls(widget.rawImagePath);
      _currentIndex = 0;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentIndex < _urls.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
  }

  void _previousPage() {
    if (_currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
  }

  Widget _buildPlaceholder() {
    IconData icon = Icons.camera_alt_outlined;
    switch (widget.type.toLowerCase()) {
      case 'fire':
        icon = Icons.local_fire_department_rounded;
        break;
      case 'medical':
        icon = Icons.medical_services_rounded;
        break;
      case 'police':
        icon = Icons.local_police_rounded;
        break;
    }
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 36, color: const Color(0xFFFF5C00)),
            const SizedBox(height: 6),
            Text(
              '${widget.type} Responder / Evidence Photo',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_urls.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: _buildPlaceholder(),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: Stack(
          children: [
            // PageView of images
            PageView.builder(
              controller: _pageController,
              itemCount: _urls.length,
              onPageChanged: (i) => setState(() => _currentIndex = i),
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () => showImageGalleryDialog(
                    context,
                    images: _urls,
                    initialIndex: index,
                  ),
                  child: Image.network(
                    _urls[index],
                    fit: BoxFit.cover,
                    loadingBuilder: (_, child, progress) {
                      if (progress == null) return child;
                      return Container(
                        color: const Color(0xFF1E293B),
                        child: const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFFFF5200),
                            strokeWidth: 2,
                          ),
                        ),
                      );
                    },
                    errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
                  ),
                );
              },
            ),

            // Left Previous Button (<)
            if (_urls.length > 1 && _currentIndex > 0)
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 16),
                      onPressed: _previousPage,
                      tooltip: 'Previous photo',
                    ),
                  ),
                ),
              ),

            // Right Next Button (>)
            if (_urls.length > 1 && _currentIndex < _urls.length - 1)
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white, size: 16),
                      onPressed: _nextPage,
                      tooltip: 'Next photo',
                    ),
                  ),
                ),
              ),

            // Bottom bar: Click to expand (Left) & Page counter (Right)
            Positioned(
              bottom: 8,
              left: 8,
              right: 8,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Click to expand badge
                  GestureDetector(
                    onTap: () => showImageGalleryDialog(
                      context,
                      images: _urls,
                      initialIndex: _currentIndex,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.zoom_in_rounded, color: Colors.white, size: 14),
                          SizedBox(width: 4),
                          Text(
                            'Click to expand',
                            style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Page Counter on Bottom (e.g. Page 1 of 3)
                  if (_urls.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'Page ${_currentIndex + 1} of ${_urls.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
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

// ---------------------------------------------------------------------------
// IncidentImageGallery — horizontal scrollable strip for multiple photos
// ---------------------------------------------------------------------------
class IncidentImageGallery extends StatefulWidget {
  /// Comma-separated image paths from the database.
  final String rawImagePath;

  /// Label shown below the gallery (e.g. "SUBMITTED PHOTO").
  final String label;

  /// Info text shown in the caption strip (e.g. citizen name + time).
  final String? captionLeft;
  final String? captionRight;

  /// Height of each image tile.
  final double imageHeight;

  const IncidentImageGallery({
    super.key,
    required this.rawImagePath,
    this.label = 'SUBMITTED PHOTO',
    this.captionLeft,
    this.captionRight,
    this.imageHeight = 180,
  });

  @override
  State<IncidentImageGallery> createState() => _IncidentImageGalleryState();
}

class _IncidentImageGalleryState extends State<IncidentImageGallery> {
  late List<String> _urls;

  @override
  void initState() {
    super.initState();
    _urls = parseImageUrls(widget.rawImagePath);
  }

  @override
  void didUpdateWidget(covariant IncidentImageGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rawImagePath != widget.rawImagePath) {
      _urls = parseImageUrls(widget.rawImagePath);
    }
  }

  void _openFullScreen(int initialIndex) {
    showImageGalleryDialog(context, images: _urls, initialIndex: initialIndex);
  }

  @override
  Widget build(BuildContext context) {
    if (_urls.isEmpty) return const SizedBox.shrink();

    final isSingle = _urls.length == 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label row
        Row(
          children: [
            Text(
              widget.label,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Color(0xFF94A3B8),
                letterSpacing: 0.5,
              ),
            ),
            if (!isSingle) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF5200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${_urls.length} photos',
                  style: const TextStyle(
                    fontSize: 9,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),

        // Image strip
        SizedBox(
          height: widget.imageHeight,
          child: isSingle
              ? _buildImageTile(0, double.infinity)
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: _urls.length,
                  separatorBuilder: (context, index) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => _buildImageTile(i, widget.imageHeight * 1.15),
                ),
        ),
      ],
    );
  }

  Widget _buildImageTile(int index, double width) {
    final url = _urls[index];
    return GestureDetector(
      onTap: () => _openFullScreen(index),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: width,
          height: widget.imageHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Image
              Image.network(
                url,
                fit: BoxFit.cover,
                loadingBuilder: (_, child, prog) {
                  if (prog == null) return child;
                  return Container(
                    color: const Color(0xFFF1F5F9),
                    child: const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFFFF6B00),
                        strokeWidth: 2,
                      ),
                    ),
                  );
                },
                errorBuilder: (context, error, stackTrace) => Container(
                  color: const Color(0xFFF1F5F9),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_rounded,
                            size: 32, color: Color(0xFFCBD5E1)),
                        SizedBox(height: 6),
                        Text('Image unavailable',
                            style: TextStyle(
                                fontSize: 11, color: Color(0xFF94A3B8))),
                      ],
                    ),
                  ),
                ),
              ),

              // Bottom gradient scrim
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.6),
                      ],
                      stops: const [0.55, 1.0],
                    ),
                  ),
                ),
              ),

              // Bottom caption (only on single or first tile)
              if (index == 0 &&
                  (widget.captionLeft != null || widget.captionRight != null))
                Positioned(
                  bottom: 8,
                  left: 10,
                  right: 10,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (widget.captionLeft != null)
                        Expanded(
                          child: Text(
                            widget.captionLeft!,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              shadows: [
                                Shadow(blurRadius: 4, color: Colors.black)
                              ],
                            ),
                          ),
                        ),
                      if (widget.captionRight != null)
                        Text(
                          widget.captionRight!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            shadows: [
                              Shadow(blurRadius: 4, color: Colors.black)
                            ],
                          ),
                        ),
                    ],
                  ),
                ),

              // Photo index badge (for multi-image)
              if (!isSingle)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${index + 1}/${_urls.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),

              // Expand icon
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.zoom_out_map_rounded,
                      size: 12, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get isSingle => _urls.length == 1;
}

// ---------------------------------------------------------------------------
// Full-screen swipeable gallery viewer with Next/Previous & Page Counter
// ---------------------------------------------------------------------------
class _FullScreenGallery extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;

  const _FullScreenGallery({required this.urls, required this.initialIndex});

  @override
  State<_FullScreenGallery> createState() => _FullScreenGalleryState();
}

class _FullScreenGalleryState extends State<_FullScreenGallery> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentIndex < widget.urls.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
  }

  void _previousPage() {
    if (_currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Swipeable image pages
          PageView.builder(
            controller: _pageController,
            itemCount: widget.urls.length,
            onPageChanged: (i) => setState(() => _currentIndex = i),
            itemBuilder: (_, i) => InteractiveViewer(
              child: Center(
                child: Image.network(
                  widget.urls[i],
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.broken_image_rounded,
                          size: 64, color: Colors.white54),
                      SizedBox(height: 12),
                      Text('Failed to load image',
                          style: TextStyle(color: Colors.white54)),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Onscreen Left Arrow Button (<)
          if (widget.urls.length > 1 && _currentIndex > 0)
            Positioned(
              left: 20,
              top: 0,
              bottom: 0,
              child: Center(
                child: Material(
                  color: Colors.black.withValues(alpha: 0.6),
                  shape: const CircleBorder(),
                  child: IconButton(
                    iconSize: 28,
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
                    onPressed: _previousPage,
                    tooltip: 'Previous photo',
                  ),
                ),
              ),
            ),

          // Onscreen Right Arrow Button (>)
          if (widget.urls.length > 1 && _currentIndex < widget.urls.length - 1)
            Positioned(
              right: 20,
              top: 0,
              bottom: 0,
              child: Center(
                child: Material(
                  color: Colors.black.withValues(alpha: 0.6),
                  shape: const CircleBorder(),
                  child: IconButton(
                    iconSize: 28,
                    icon: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white),
                    onPressed: _nextPage,
                    tooltip: 'Next photo',
                  ),
                ),
              ),
            ),

          // Top Bar (Close button)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 48, 16, 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.7),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 28),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  if (widget.urls.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        'Photo ${_currentIndex + 1} of ${widget.urls.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Bottom Bar with Page Navigation & Indicators
          Positioned(
            bottom: 24,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.urls.length > 1) ...[
                  // Bottom Counter & Prev/Next Controls
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: _previousPage,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Icon(
                              Icons.navigate_before_rounded,
                              color: _currentIndex > 0 ? Colors.white : Colors.white38,
                              size: 24,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Page ${_currentIndex + 1} of ${widget.urls.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: _nextPage,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Icon(
                              Icons.navigate_next_rounded,
                              color: _currentIndex < widget.urls.length - 1 ? Colors.white : Colors.white38,
                              size: 24,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Page indicator dots
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(widget.urls.length, (i) {
                      final isActive = i == _currentIndex;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: isActive ? 22 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: isActive ? const Color(0xFFFF5200) : Colors.white38,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      );
                    }),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper function to display the full-screen swipeable image gallery dialog.
void showImageGalleryDialog(BuildContext context, {required List<String> images, int initialIndex = 0}) {
  if (images.isEmpty) return;
  showDialog(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.9),
    builder: (context) => _FullScreenGallery(urls: images, initialIndex: initialIndex),
  );
}

