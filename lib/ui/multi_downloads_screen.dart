import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/download_task.dart';
import '../engine/download_manager_service.dart';
import '../engine/android_system_bridge.dart';

/// [MultiDownloadsScreen] is the dedicated cockpit management screen for:
/// 1. Real-time monitoring of multiple simultaneous downloads (e.g., 4+ concurrent tasks).
/// 2. Live Aggregate Bandwidth Speedometer & individual task speed gauges.
/// 3. Per-task controls: Pause, Resume, Cancel, Retry.
/// 4. Bulk Master Controls: Pause All, Resume All, Cancel All.
/// 5. Filter categories: All, APK Apps 📦, Videos 🎬, Audio 🎵, Documents & Archives 📁.
/// 6. Direct APK installation & media playback for completed files.
class MultiDownloadsScreen extends StatefulWidget {
  final int initialTabIndex;

  const MultiDownloadsScreen({
    super.key,
    this.initialTabIndex = 0,
  });

  static Future<void> open(BuildContext context, {int initialTabIndex = 0}) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => MultiDownloadsScreen(initialTabIndex: initialTabIndex),
      ),
    );
  }

  @override
  State<MultiDownloadsScreen> createState() => _MultiDownloadsScreenState();
}

class _MultiDownloadsScreenState extends State<MultiDownloadsScreen>
    with SingleTickerProviderStateMixin {
  static const Color deepCarbon = Color(0xFF0A0A0C);
  static const Color surfaceCard = Color(0xFF141216);
  static const Color surfaceCardElevated = Color(0xFF1C191E);
  static const Color fieryAmber = Color(0xFFFF4F00);
  static const Color neonCyan = Color(0xFF00E5FF);
  static const Color emeraldGreen = Color(0xFF10B981);

  late final TabController _tabController;
  final DownloadManagerService _manager = DownloadManagerService();
  String _selectedCategory = 'all'; // all, apk, video, audio, archive, doc
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTabIndex,
    );
    _manager.addListener(_onManagerUpdate);
    _manager.refreshCompletedDownloadsFromStorage();
  }

  void _onManagerUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerUpdate);
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<DownloadTask> _filterTasks(List<DownloadTask> tasks) {
    return tasks.where((task) {
      // Category filter
      if (_selectedCategory == 'apk' && !task.isApk) return false;
      if (_selectedCategory == 'video' && !task.isVideo) return false;
      if (_selectedCategory == 'audio' && !task.isAudio) return false;
      if (_selectedCategory == 'archive' && !task.isArchive) return false;
      if (_selectedCategory == 'doc' && !task.isDocument) return false;

      // Search filter
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        return task.fileName.toLowerCase().contains(query) ||
            task.sourceUrl.toLowerCase().contains(query);
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final activeTasks = _filterTasks(_manager.activeTasks);
    final completedTasks = _filterTasks(_manager.completedTasks);

    return Scaffold(
      backgroundColor: deepCarbon,
      body: SafeArea(
        child: Column(
          children: [
            // 1. Top Cockpit Header & Speed Banner
            _buildCockpitHeader(),

            // 2. Aggregate Bandwidth HUD
            _buildAggregateSpeedHud(),

            // 3. Tab Bar (Active vs Completed)
            _buildTabBar(),

            // 4. Category Filter Chips & Search Bar
            _buildFilterAndSearchBar(),

            // 5. Tasks List View
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  // Tab 0: Active Concurrent Downloads
                  _buildActiveDownloadsTab(activeTasks),

                  // Tab 1: Completed Downloads
                  _buildCompletedDownloadsTab(completedTasks),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCockpitHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: surfaceCard,
        border: Border(
          bottom: BorderSide(color: fieryAmber.withOpacity(0.2)),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: 'رجوع',
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: fieryAmber.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: fieryAmber.withOpacity(0.4)),
                ),
                child: const Icon(Icons.speed, color: fieryAmber, size: 20),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'قمرة التنزيلات المتعددة',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'تنزيل متزامن بلا حدود // HyperPulse Multi-Stream',
                    style: TextStyle(
                      color: const Color(0xFF8E888A),
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ],
          ),

          // Active count indicator pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _manager.activeCount > 0
                  ? fieryAmber.withOpacity(0.2)
                  : const Color(0xFF221F24),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _manager.activeCount > 0 ? fieryAmber : const Color(0xFF3B363A),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_manager.activeCount > 0) ...[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: fieryAmber,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  '${_manager.activeCount} نشط معاً',
                  style: TextStyle(
                    color: _manager.activeCount > 0 ? fieryAmber : const Color(0xFF8E888A),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAggregateSpeedHud() {
    final activeCount = _manager.activeCount;
    final totalSpeed = _manager.formattedTotalSpeed;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: activeCount > 0 ? fieryAmber.withOpacity(0.4) : const Color(0xFF262228),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: activeCount > 0
                      ? fieryAmber.withOpacity(0.15)
                      : const Color(0xFF221F24),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.bolt,
                  color: activeCount > 0 ? fieryAmber : const Color(0xFF6B6568),
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'إجمالي سرعة التنزيل المتزامنة',
                    style: TextStyle(color: Color(0xFF8E888A), fontSize: 11),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    activeCount > 0 ? totalSpeed : '0.0 MB/s (وضع الاستعداد)',
                    style: TextStyle(
                      color: activeCount > 0 ? Colors.white : const Color(0xFF6B6568),
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ],
          ),

          // Bulk Master Controls
          if (activeCount > 0)
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.pause_circle_outline, color: fieryAmber, size: 24),
                  tooltip: 'إيقاف الكل مؤقتاً',
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    _manager.pauseAll();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.play_circle_outline, color: emeraldGreen, size: 24),
                  tooltip: 'استئناف الكل',
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    _manager.resumeAll();
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF121014),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF262228)),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          color: fieryAmber,
          borderRadius: BorderRadius.circular(9),
        ),
        labelColor: Colors.white,
        unselectedLabelColor: const Color(0xFF8E888A),
        indicatorSize: TabBarIndicatorSize.tab,
        labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        tabs: [
          Tab(
            text: 'التنزيلات النشطة (${_manager.activeTasks.length})',
          ),
          Tab(
            text: 'المكتملة والمثبتة (${_manager.completedTasks.length})',
          ),
        ],
      ),
    );
  }

  Widget _buildFilterAndSearchBar() {
    final categories = [
      {'id': 'all', 'label': 'الكل', 'icon': Icons.apps},
      {'id': 'apk', 'label': 'تطبيقات APK 📦', 'icon': Icons.android},
      {'id': 'video', 'label': 'فيديوهات 🎬', 'icon': Icons.videocam},
      {'id': 'audio', 'label': 'صوتيات 🎵', 'icon': Icons.audiotrack},
      {'id': 'archive', 'label': 'مضغوطة 🗜️', 'icon': Icons.folder_zip},
      {'id': 'doc', 'label': 'مستندات 📄', 'icon': Icons.description},
    ];

    return Column(
      children: [
        // Categories Horizontal List
        SizedBox(
          height: 36,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            scrollDirection: Axis.horizontal,
            itemCount: categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final cat = categories[index];
              final isSelected = _selectedCategory == cat['id'];
              return ChoiceChip(
                label: Text(
                  cat['label'] as String,
                  style: TextStyle(
                    color: isSelected ? Colors.white : const Color(0xFF9E989B),
                    fontSize: 11,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                selected: isSelected,
                selectedColor: fieryAmber.withOpacity(0.35),
                backgroundColor: const Color(0xFF161418),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: isSelected ? fieryAmber : const Color(0xFF2C282C),
                  ),
                ),
                onSelected: (selected) {
                  setState(() {
                    _selectedCategory = cat['id'] as String;
                  });
                },
              );
            },
          ),
        ),

        // Search Input
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFF121014),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF242025)),
          ),
          child: TextField(
            controller: _searchController,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search, color: Color(0xFF6B6568), size: 16),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Color(0xFF8E888A), size: 16),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              hintText: 'بحث في التنزيلات باسم الملف أو الرابط...',
              hintStyle: const TextStyle(color: Color(0xFF6B6568), fontSize: 11),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.only(top: 8),
            ),
            onChanged: (val) => setState(() => _searchQuery = val),
          ),
        ),
      ],
    );
  }

  Widget _buildActiveDownloadsTab(List<DownloadTask> tasks) {
    if (tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.download_done_rounded, color: const Color(0xFF3B363A), size: 54),
            const SizedBox(height: 12),
            const Text(
              'لا توجد تنزيلات نشطة حالياً',
              style: TextStyle(color: Color(0xFF8E888A), fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              'أدخل رابطاً أو استخدم المتصفح لبدء عدة تنزيلات في الوقت نفسه',
              style: TextStyle(color: Color(0xFF6B6568), fontSize: 11),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: tasks.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final task = tasks[index];
        return _buildActiveTaskCard(task);
      },
    );
  }

  Widget _buildActiveTaskCard(DownloadTask task) {
    final isDownloading = task.status == DownloadStatus.downloading;
    final isPaused = task.status == DownloadStatus.paused;
    final isFailed = task.status == DownloadStatus.failed;

    Color statusColor = fieryAmber;
    if (isPaused) statusColor = const Color(0xFFFBBF24);
    if (isFailed) statusColor = const Color(0xFFEF4444);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDownloading ? fieryAmber.withOpacity(0.5) : const Color(0xFF262228),
          width: isDownloading ? 1.2 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // File Name & Extension Badge
          Row(
            children: [
              _buildFileTypeIcon(task),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.fileName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          _getTaskStatusDescription(task),
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (task.threadCount > 1)
                          Text(
                            '// ${task.threadCount} مسارات متوازية',
                            style: const TextStyle(
                              color: Color(0xFF6B6568),
                              fontSize: 10,
                              fontFamily: 'monospace',
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),

              // Individual Task Actions (Pause / Resume / Cancel / Retry)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isDownloading)
                    IconButton(
                      icon: const Icon(Icons.pause_circle, color: fieryAmber, size: 26),
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        _manager.pauseTask(task.id);
                      },
                      tooltip: 'إيقاف مؤقت',
                    )
                  else if (isPaused)
                    IconButton(
                      icon: const Icon(Icons.play_circle, color: emeraldGreen, size: 26),
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        _manager.resumeTask(task.id);
                      },
                      tooltip: 'استئناف',
                    )
                  else if (isFailed)
                    IconButton(
                      icon: const Icon(Icons.refresh, color: fieryAmber, size: 24),
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        _manager.retryTask(task.id);
                      },
                      tooltip: 'إعادة المحاولة',
                    ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF6B6568), size: 20),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      _manager.cancelTask(task.id);
                    },
                    tooltip: 'إلغاء التنزيل',
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Linear Progress Indicator
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: task.totalSizeBytes > 0 ? task.progress : null,
              minHeight: 5,
              backgroundColor: const Color(0xFF221F24),
              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
            ),
          ),

          const SizedBox(height: 8),

          // Telemetry Row: Speed, Downloaded / Total, Percentage
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${(task.progress * 100).toStringAsFixed(0)}% مكتمل',
                style: TextStyle(
                  color: statusColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                _formatTaskDownloadedSize(task),
                style: const TextStyle(
                  color: Color(0xFF9E989B),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                isDownloading ? task.formattedSpeed : (isPaused ? 'متوقف مؤقتاً' : 'فشل'),
                style: TextStyle(
                  color: isDownloading ? Colors.white : const Color(0xFF8E888A),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),

          if (task.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                task.error!,
                style: const TextStyle(color: Color(0xFFEF4444), fontSize: 10),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCompletedDownloadsTab(List<DownloadTask> tasks) {
    if (tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open_outlined, color: const Color(0xFF3B363A), size: 54),
            const SizedBox(height: 12),
            const Text(
              'لا توجد ملفات مكتملة',
              style: TextStyle(color: Color(0xFF8E888A), fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: tasks.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final task = tasks[index];
        return _buildCompletedTaskCard(task);
      },
    );
  }

  Widget _buildCompletedTaskCard(DownloadTask task) {
    final isApk = task.isApk;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF262228)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildFileTypeIcon(task),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.fileName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${task.formattedTotalSize} // تم الحفظ في ${task.destinationDirectory.split('/').last}',
                      style: const TextStyle(color: Color(0xFF8E888A), fontSize: 10),
                    ),
                  ],
                ),
              ),

              // Delete button
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Color(0xFF6B6568), size: 18),
                onPressed: () => _manager.deleteCompletedTask(task),
                tooltip: 'حذف من السجل والذاكرة',
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Action Buttons: Install APK or Play/Open
          Row(
            children: [
              if (isApk)
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      HapticFeedback.heavyImpact();
                      final success = await _manager.openOrInstallFile(task);
                      if (!success && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('تعذر فتح حزمة التثبيت. تأكد من اكتمال تنزيل الملف.')),
                        );
                      }
                    },
                    icon: const Icon(Icons.android, size: 16),
                    label: const Text(
                      'تثبيت التطبيق فـوراً (Install APK)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: fieryAmber,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _manager.openOrInstallFile(task),
                    icon: Icon(
                      task.isVideo ? Icons.play_arrow : Icons.open_in_new,
                      size: 16,
                    ),
                    label: Text(
                      task.isVideo ? 'تشغيل الفيديو 🎬' : (task.isAudio ? 'تشغيل الصوت 🎵' : 'فتح الملف 📄'),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF221F24),
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFF3B363A)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFileTypeIcon(DownloadTask task) {
    IconData iconData = Icons.insert_drive_file;
    Color iconColor = const Color(0xFF9E989B);

    if (task.isApk) {
      iconData = Icons.android;
      iconColor = const Color(0xFF3DDC84);
    } else if (task.isVideo) {
      iconData = Icons.movie;
      iconColor = fieryAmber;
    } else if (task.isAudio) {
      iconData = Icons.audiotrack;
      iconColor = neonCyan;
    } else if (task.isArchive) {
      iconData = Icons.folder_zip;
      iconColor = const Color(0xFFF59E0B);
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: iconColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(iconData, color: iconColor, size: 20),
    );
  }

  String _getTaskStatusDescription(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.analyzing:
        return 'جاري فحص الرابط وفك التشفير...';
      case DownloadStatus.preparingSegments:
        return 'جاري تقسيم الملف للتحميل المتوازي...';
      case DownloadStatus.downloading:
        return 'جاري التحميل المتزامن ⚡';
      case DownloadStatus.paused:
        return 'متوقف مؤقتاً';
      case DownloadStatus.merging:
        return 'جاري دمج الأجزاء والفحص النهائي...';
      case DownloadStatus.completed:
        return 'اكتمل التنزيل بنجاح ✅';
      case DownloadStatus.failed:
        return 'فشل التنزيل // اضغط لإعادة المحاولة';
      default:
        return 'في الانتظار';
    }
  }

  String _formatTaskDownloadedSize(DownloadTask task) {
    final dlMb = (task.downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
    if (task.totalSizeBytes <= 0) {
      return '$dlMb MB / تيار';
    }
    final totMb = (task.totalSizeBytes / (1024 * 1024)).toStringAsFixed(1);
    return '$dlMb MB / $totMb MB';
  }
}
