import 'dart:io';
import 'package:flutter/material.dart';
import '../models/download_task.dart';
import '../engine/download_manager_service.dart';
import '../engine/android_system_bridge.dart';

/// [DownloadsCenterSheet] displays:
/// 1. Active downloads tab with real-time speed, pause, resume, cancel.
/// 2. Completed downloads tab with direct APK installation, Video player trigger, and file management.
class DownloadsCenterSheet extends StatefulWidget {
  final int initialTabIndex;

  const DownloadsCenterSheet({
    super.key,
    this.initialTabIndex = 0,
  });

  static Future<void> show(BuildContext context, {int initialTabIndex = 0}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DownloadsCenterSheet(initialTabIndex: initialTabIndex),
    );
  }

  @override
  State<DownloadsCenterSheet> createState() => _DownloadsCenterSheetState();
}

class _DownloadsCenterSheetState extends State<DownloadsCenterSheet>
    with SingleTickerProviderStateMixin {
  static const Color deepCarbon = Color(0xFF0D0B0E);
  static const Color surfaceCard = Color(0xFF181519);
  static const Color fieryAmber = Color(0xFFFF4F00);

  late final TabController _tabController;
  final DownloadManagerService _manager = DownloadManagerService();

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: deepCarbon,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(color: fieryAmber, width: 1.5),
        ),
      ),
      child: Column(
        children: [
          // Drag Handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF3B363A),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header Title & Tab Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: fieryAmber.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.folder_special, color: fieryAmber, size: 20),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'مركز التنزيلات // HyperPulse',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Color(0xFF8E888A), size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          // Custom Tabs
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFF151216),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2C272B)),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: fieryAmber,
                borderRadius: BorderRadius.circular(10),
              ),
              labelColor: Colors.white,
              unselectedLabelColor: const Color(0xFF8E888A),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              tabs: [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.downloading, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        'قيد التحميل (${_manager.activeTasks.length})',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.check_circle_outline, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        'المكتملة والتثبيت (${_manager.completedTasks.length})',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Tab Views
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildActiveTasksTab(),
                _buildCompletedTasksTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveTasksTab() {
    final active = _manager.activeTasks;
    if (active.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_download_outlined, size: 64, color: fieryAmber.withOpacity(0.4)),
            const SizedBox(height: 12),
            const Text(
              'لا توجد تنزيلات نشطة حالياً',
              style: TextStyle(color: Color(0xFFD6D0D3), fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'استخدم المتصفح الداخلي أو الصق رابط فيديو/APK لبدء التحميل الفوري',
              style: TextStyle(color: Color(0xFF7A7478), fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: active.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final task = active[index];
        final isPaused = task.status == DownloadStatus.paused;

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: surfaceCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isPaused ? const Color(0xFF4A4247) : fieryAmber.withOpacity(0.4),
              width: 1.2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _getFileIcon(task.fileName),
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
                              isPaused ? '⏸️ متوقف مؤقتاً' : '⚡ ${task.formattedSpeed}',
                              style: TextStyle(
                                color: isPaused ? const Color(0xFFFBBF24) : const Color(0xFF4ADE80),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              task.formattedTotalSize,
                              style: const TextStyle(color: Color(0xFF8E888A), fontSize: 11),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      isPaused ? Icons.play_arrow : Icons.pause,
                      color: fieryAmber,
                      size: 22,
                    ),
                    onPressed: () {
                      if (isPaused) {
                        _manager.resumeTask(task.id);
                      } else {
                        _manager.pauseTask(task.id);
                      }
                    },
                    tooltip: isPaused ? 'استئناف' : 'إيقاف مؤقت',
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFFF87171), size: 20),
                    onPressed: () => _manager.cancelTask(task.id),
                    tooltip: 'إلغاء التحميل',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: task.progress > 0 ? task.progress : null,
                  backgroundColor: const Color(0xFF262125),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isPaused ? const Color(0xFFFBBF24) : fieryAmber,
                  ),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${(task.progress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(color: Color(0xFFB5AFB2), fontSize: 10),
                  ),
                  Text(
                    task.status == DownloadStatus.downloading
                        ? 'جاري نقل البيانات بالأنوية...'
                        : isPaused
                            ? 'اضغط زر التشغيل للاستئناف'
                            : 'تهيئة...',
                    style: const TextStyle(color: Color(0xFF8E888A), fontSize: 10),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCompletedTasksTab() {
    final completed = _manager.completedTasks;
    if (completed.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open, size: 64, color: const Color(0xFF4A4247)),
            const SizedBox(height: 12),
            const Text(
              'لا توجد ملفات مكتملة بعد',
              style: TextStyle(color: Color(0xFFD6D0D3), fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'الملفات التي تنزلها ستظهر هنا لتثبيت التطبيقات وتشغيل الفيديوهات فوراً',
              style: TextStyle(color: Color(0xFF7A7478), fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: completed.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final task = completed[index];
        final isApk = task.fileName.toLowerCase().endsWith('.apk');
        final isVideo = task.fileName.toLowerCase().endsWith('.mp4') ||
            task.fileName.toLowerCase().endsWith('.mkv') ||
            task.fileName.toLowerCase().endsWith('.webm');

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: surfaceCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF2C272B)),
          ),
          child: Row(
            children: [
              _getFileIcon(task.fileName),
              const SizedBox(width: 12),
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
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          task.formattedTotalSize,
                          style: const TextStyle(color: Color(0xFF4ADE80), fontSize: 11),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          isApk
                              ? 'حزمة تطبيق جاهزة للتثبيت'
                              : isVideo
                                  ? 'فيديو في المعرض'
                                  : 'ملف جاهز',
                          style: const TextStyle(color: Color(0xFF8E888A), fontSize: 10),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Action Button (Install APK or Play/Open)
              if (isApk)
                ElevatedButton.icon(
                  onPressed: () => _manager.openOrInstallFile(task),
                  icon: const Icon(Icons.install_mobile, size: 16),
                  label: const Text(
                    'تثبيت APK',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                )
              else
                ElevatedButton.icon(
                  onPressed: () => _manager.openOrInstallFile(task),
                  icon: Icon(isVideo ? Icons.play_arrow : Icons.open_in_new, size: 16),
                  label: Text(
                    isVideo ? 'تشغيل' : 'فتح',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: fieryAmber,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),

              const SizedBox(width: 4),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Color(0xFF8E888A), size: 18),
                color: const Color(0xFF1C191D),
                onSelected: (val) {
                  if (val == 'delete') {
                    _manager.deleteCompletedTask(task);
                  } else if (val == 'open') {
                    _manager.openOrInstallFile(task);
                  }
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: 'open',
                    child: Row(
                      children: [
                        Icon(Icons.open_in_browser, color: Colors.white, size: 16),
                        SizedBox(width: 8),
                        Text('فتح الملف', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, color: Color(0xFFF87171), size: 16),
                        SizedBox(width: 8),
                        Text('حذف من الجهاز', style: TextStyle(color: Color(0xFFF87171), fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _getFileIcon(String filename) {
    final lower = filename.toLowerCase();
    IconData iconData = Icons.insert_drive_file;
    Color iconColor = const Color(0xFF60A5FA);

    if (lower.endsWith('.apk')) {
      iconData = Icons.android;
      iconColor = const Color(0xFF10B981);
    } else if (lower.endsWith('.mp4') || lower.endsWith('.mkv') || lower.endsWith('.webm')) {
      iconData = Icons.videocam;
      iconColor = fieryAmber;
    } else if (lower.endsWith('.mp3') || lower.endsWith('.m4a') || lower.endsWith('.wav')) {
      iconData = Icons.audiotrack;
      iconColor = const Color(0xFFA855F7);
    } else if (lower.endsWith('.zip') || lower.endsWith('.rar') || lower.endsWith('.7z')) {
      iconData = Icons.folder_zip;
      iconColor = const Color(0xFFFBBF24);
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: iconColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(iconData, color: iconColor, size: 20),
    );
  }
}
