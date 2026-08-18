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
  final Dio dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.stream,
      headers: {
        'Range': 'bytes=${params.startByte}-${params.endByte}',
        'User-Agent': 'HyperPulse-Turbo-Engine/1.0.0 (Flutter; High-Speed Core)',
        'Accept-Encoding': 'identity', // Prevent gzip re-compression on range requests
        ...?params.customHeaders,
      },
    ),
  );

  int currentOffset = params.startByte;

  try {
    final response = await dio.get<ResponseBody>(params.url);
    final stream = response.data?.stream;

    if (stream == null) {
      params.mainSendPort.send(
        ChunkWorkerPacket(
          segmentIndex: params.segmentIndex,
          offset: currentOffset,
          error: 'Empty response stream from server.',
        ),
      );
      return;
    }

    await for (final List<int> rawChunk in stream) {
      final Uint8List bytes = Uint8List.fromList(rawChunk);
      params.mainSendPort.send(
        ChunkWorkerPacket(
          segmentIndex: params.segmentIndex,
          offset: currentOffset,
          data: bytes,
        ),
      );
      currentOffset += bytes.lengthInBytes;
    }

    // Emit completion signal
    params.mainSendPort.send(
      ChunkWorkerPacket(
        segmentIndex: params.segmentIndex,
        offset: currentOffset,
        isCompleted: true,
      ),
    );
  } catch (err) {
    params.mainSendPort.send(
      ChunkWorkerPacket(
        segmentIndex: params.segmentIndex,
        offset: currentOffset,
        error: err.toString(),
      ),
    );
  }
}
