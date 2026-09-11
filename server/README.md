# PulseSphere Extractor Server (Wispbyte Edition)

سيرفر استخراج روابط الفيديو المباشرة باستخدام **Flask** و **yt-dlp**، مضبوط بدقة للعمل على منصة **Wispbyte** في حدود ذاكرة **512MB RAM** دون أي انهيار (OOM).

---

## 📁 ملفات السيرفر الأربعة المرفوعة على Wispbyte:

1. `app.py`: كود السيرفر مع تفعيل جامع القمامة `gc.collect()` وتقييد العمليات المتزامنة وحظر تحميل الفيديو لتوفير الذاكرة.
2. `requirements.txt`: المكتبات الأساسية فقط (`flask`, `yt-dlp`, `gunicorn`).
3. `Procfile`: أمر تشغيل `gunicorn` بـ Worker واحد وخيطين (`--workers 1 --threads 2`) مع إعادة تدوير الذاكرة كل 100 طلب.
4. `README.md`: هذا الملف التوضيحي.

---

## ⚙️ إعدادات وخوارزمية حفظ الذاكرة (512MB Tuning):

- **Single Worker (`-w 1`)**: استهلاك ثابت للذاكرة (~65MB) بدلاً من تشغيل عدة Workers تستهلك الرام بالكامل.
- **Worker Recycling (`--max-requests 100`)**: إعادة تشغيل Worker تلقائياً بعد كل 100 طلب لتفريغ أي تسريب ذاكرة (Memory Leak).
- **Zero Disk Cache (`cachedir: False`)**: منع yt-dlp من إنشاء كاش على القرص.
- **Immediate Garbage Collection (`gc.collect()`)**: استدعاء فوري لمحرر الذاكرة في بايثون بعد كل استخراج.
- **Socket Timeout 8s**: إغلاق أي اتصال معلق فوراً خلال 8 ثوانٍ لحماية موارد السيرفر.

---

## 🚀 طريقة الرفع على منصة Wispbyte:

1. أنشئ تطبيقاً جديداً من لوحة تحكم **Wispbyte**.
2. اختر بيئة **Python 3.10+**.
3. ارفع الملفات الأربعة (`app.py`, `requirements.txt`, `Procfile`, `README.md`) في مجلد التطبيق الرئيسي.
4. اضغط على **Deploy** أو **Start Service**.
5. انسخ الرابط العام الناتج (مثلاً: `https://your-app.wispbyte.app`).
6. ضع الرابط في تطبيق Flutter داخل `MultiServerExtractor.wispbyteServerUrl`.

---

## 🧪 تجربة السيرفر (Testing Endpoints):

### 1. فحص الحالة (Health Check):
```bash
curl https://your-app.wispbyte.app/health
```
النتيجة المتوقعة:
```json
{
  "status": "online",
  "service": "PulseSphere Wispbyte Extractor",
  "ram_mode": "512MB-Optimized"
}
```

### 2. استخراج فيديو (YouTube / TikTok / etc):
```bash
curl "https://your-app.wispbyte.app/extract?url=https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```
النتيجة:
```json
{
  "success": true,
  "direct_url": "https://rr---sn-....googlevideo.com/videoplayback?...",
  "title": "Rick Astley - Never Gonna Give You Up",
  "format": "mp4",
  "size": 34891230,
  "provider": "Wispbyte yt-dlp SpeedCore ⚡"
}
```
