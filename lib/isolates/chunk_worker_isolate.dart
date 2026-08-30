import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:dio/dio.dart';

/// Message sent to initialize a worker isolate.
class ChunkWorkerInitParams {
  final int segmentIndex;
  final String url;
  final int startByte;
  final int endByte;
  final SendPort mainSendPort;
  final Map<String, String>? customHeaders;

  ChunkWorkerInitParams({
    required this.segmentIndex,
    required this.url,
    required this.startByte,
    required this.endByte,
    required this.mainSendPort,
    this.customHeaders,
  });
}

/// Message payload emitted from worker isolate back to main thread.
class ChunkWorkerPacket {
  final int segmentIndex;
  final int offset;
  final Uint8List? data;
  final bool isCompleted;
  final String? error;

  ChunkWorkerPacket({
    required this.segmentIndex,
    required this.offset,
    this.data,
    this.isCompleted = false,
    this.error,
  });
}

/// Entry point function executed inside isolated background thread.
void chunkWorkerEntryPoint(ChunkWorkerInitParams params) async {
  int currentOffset = params.startByte;
  int retryAttempts = 0;
  const int maxWorkerRetries = 3;

  while (currentOffset <= params.endByte && retryAttempts < maxWorkerRetries) {
    final Dio dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 40),
        responseType: ResponseType.stream,
        headers: {
          'Range': 'bytes=$currentOffset-${params.endByte}',
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14; Mobile; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.6613.127 Mobile Safari/537.36',
          'Accept': '*/*',
          'Accept-Encoding': 'identity', // Prevent gzip re-compression on range requests
          'Connection': 'keep-alive',
          ...?params.customHeaders,
        },
      ),
    );

    try {
      final response = await dio.get<ResponseBody>(params.url);
      final stream = response.data?.stream;

      if (stream == null) {
        throw Exception('Empty response stream from server.');
      }

      await for (final List<int> rawChunk in stream) {
        final Uint8List bytes = rawChunk is Uint8List ? rawChunk : Uint8List.fromList(rawChunk);
        params.mainSendPort.send(
          ChunkWorkerPacket(
            segmentIndex: params.segmentIndex,
            offset: currentOffset,
            data: bytes,
          ),
        );
        currentOffset += bytes.lengthInBytes;
      }

      // If we downloaded up to or beyond endByte, emit completion signal and exit
      if (currentOffset > params.endByte) {
        params.mainSendPort.send(
          ChunkWorkerPacket(
            segmentIndex: params.segmentIndex,
            offset: currentOffset,
            isCompleted: true,
          ),
        );
        return;
      }
    } catch (err) {
      retryAttempts++;
      if (retryAttempts >= maxWorkerRetries) {
        params.mainSendPort.send(
          ChunkWorkerPacket(
            segmentIndex: params.segmentIndex,
            offset: currentOffset,
            error: err.toString(),
          ),
        );
        return;
      }
      await Future.delayed(Duration(milliseconds: 300 * retryAttempts));
    }
  }

  // Final check if finished
  params.mainSendPort.send(
    ChunkWorkerPacket(
      segmentIndex: params.segmentIndex,
      offset: currentOffset,
      isCompleted: true,
    ),
  );
}
