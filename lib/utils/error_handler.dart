import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';

/// Centralized translator for system, network, and I/O exceptions
/// into clear, user-friendly messages for the cockpit HUD.
class HyperPulseErrorHandler {
  static String getFriendlyMessage(dynamic error) {
    if (error == null) return 'حدث خطأ غير معروف';

    if (error is SocketException) {
      return 'فشل الاتصال بالشبكة، حاول مرة أخرى';
    }

    if (error is TimeoutException) {
      return 'انتهت مهلة الانتظار أثناء الاتصال بالخادم، يرجى إعادة المحاولة';
    }

    if (error is FileSystemException) {
      if (error.message.toLowerCase().contains('permission')) {
        return 'تعذر حفظ الملف بسبب نقص صلاحيات التخزين، تم التحويل للمجلد الآمن';
      }
      if (error.message.toLowerCase().contains('space') || error.osError?.errorCode == 28) {
        return 'لا توجد مساحة كافية على قرص التخزين لإتمام التحميل';
      }
      return 'حدث خطأ أثناء كتابة البيانات على القرص';
    }

    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return 'فشل الاتصال بالشبكة، حاول مرة أخرى';

        case DioExceptionType.connectionError:
          return 'فشل الاتصال بالشبكة، تأكد من اتصال الإنترنت وحاول مجدداً';

        case DioExceptionType.badResponse:
          final statusCode = error.response?.statusCode;
          if (statusCode == 404) {
            return 'الرابط المطلوب غير موجود أو تم حذفه من المصدر (404)';
          } else if (statusCode == 403 || statusCode == 401) {
            return 'الخادم يمنع التحميل (قد يتطلب الرابط تسجيل دخول أو انتهت صلاحيته)';
          } else if (statusCode == 416) {
            return 'الخادم لا يدعم تجزئة النطاق المطلوب (Range Not Satisfiable)';
          } else if (statusCode != null && statusCode >= 500) {
            return 'خادم الموقع يواجه مشكلة فنية حالياً ($statusCode)';
          }
          return 'استجاب الخادم برمز خطأ غير متوقع ($statusCode)';

        case DioExceptionType.cancel:
          return 'تم إلغاء عملية التحميل بنجاح';

        default:
          return 'فشل الاتصال بالشبكة، حاول مرة أخرى';
      }
    }

    if (error is FormatException) {
      return 'صيغة الرابط غير صحيحة، يرجى التأكد من الرابط المدخل';
    }

    final raw = error.toString();
    if (raw.toLowerCase().contains('network') ||
        raw.toLowerCase().contains('failed host lookup') ||
        raw.toLowerCase().contains('connection refused')) {
      return 'فشل الاتصال بالشبكة، حاول مرة أخرى';
    }

    return 'حدث خطأ غير متوقع أثناء المعالجة: $raw';
  }
}
