# Video Extractor API Server

سيرفر مبني على Flask و yt-dlp لاستخراج الروابط المباشرة للفيديوهات.

---

## 1. التشغيل محلياً (Local Setup)

### المتطلبات:
- Python 3.9+

### خطوات التثبيت والتشغيل:
```bash
# الانتقال لمجلد السيرفر
cd server

# إنشاء بيئة وهمية وتفعيلها (اختياري لكن يُنصح به)
python -m venv venv
source venv/bin/activate  # لنظام Linux/macOS
# أو venv\Scripts\activate لنظام Windows

# تثبيت الحزم المطلوبة
pip install -r requirements.txt

# تشغيل السيرفر
python app.py
```
سيعمل السيرفر على: `http://localhost:8080`

### تجربة الاستخراج:
```bash
curl "http://localhost:8080/extract?url=https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

---

## 2. النشر على Railway (Deploy to Railway)

1. سجل الدخول إلى [Railway](https://railway.app/).
2. اختر **New Project** ثم **Deploy from GitHub repo**.
3. حدد المستودع والمجلد `server` (أو ارفع مجلد `server` كمستودع مستقل).
4. يتعرف Railway تلقائياً على `Procfile` و `requirements.txt`.
5. يقوم بتشغيل الأمر:
   ```bash
   gunicorn app:app -b 0.0.0.0:8080
   ```
6. من إعدادات الخدمة في Railway (Settings -> Networking)، اضغط **Generate Domain** للحصول على رابط السيرفر المباشر (HTTPS).
