import os
import logging
from flask import Flask, request, jsonify
from flask_cors import CORS
import yt_dlp

# Configure structured logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("HyperPulseServer")

app = Flask(__name__)
CORS(app)  # Allow cross-origin requests from Flutter Web & native apps

@app.route("/", methods=["GET"])
@app.route("/health", methods=["GET"])
def health_check():
    return jsonify({
        "status": "online",
        "service": "HyperPulse Primary Rocket Extractor",
        "engine": "yt-dlp",
        "version": yt_dlp.version.__version__
    }), 200

@app.route("/extract", methods=["GET"])
def extract_media():
    url = request.args.get("url", "").strip()
    if not url:
        return jsonify({
            "success": False,
            "error": "يرجى تزويد رابط الوسائط في المعامل url (Missing 'url' query parameter)"
        }), 400

    logger.info(f"Incoming extraction request for URL: {url}")

    # yt-dlp configuration optimized for fast direct stream URL resolution
    ydl_opts = {
        'format': 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best',
        'noplaylist': True,
        'quiet': True,
        'no_warnings': True,
        'skip_download': True,
        'socket_timeout': 10,
        'geo_bypass': True,
        'extract_flat': False,
        'cachedir': False,
        # Common User-Agent to avoid immediate bot detection
        'http_headers': {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
            'Accept-Language': 'en-US,en;q=0.9,ar;q=0.8',
        }
    }

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
            if not info:
                return jsonify({
                    "success": False,
                    "error": "فشل استخراج معلومات الوسائط من الرابط المعطى"
                }), 422

            # Find direct playback / download URL
            direct_url = None
            format_ext = info.get('ext', 'mp4')
            filesize = info.get('filesize') or info.get('filesize_approx') or 0

            # Direct stream URL or highest quality URL in formats list
            if info.get('url'):
                direct_url = info.get('url')
            elif info.get('formats'):
                # Pick the best progressive or video format with direct URL
                formats = info.get('formats', [])
                valid_formats = [f for f in formats if f.get('url') and (f.get('vcodec') != 'none' or f.get('ext') in ['mp4', 'm4a', 'mp3'])]
                if valid_formats:
                    chosen = valid_formats[-1]  # Highest quality
                    direct_url = chosen.get('url')
                    format_ext = chosen.get('ext', format_ext)
                    filesize = chosen.get('filesize') or chosen.get('filesize_approx') or filesize

            if not direct_url:
                return jsonify({
                    "success": False,
                    "error": "لم يتم العثور على تيار بث مباشر قابل للتحميل"
                }), 422

            title = info.get('title', 'HyperPulse_Video')
            duration = info.get('duration', 0)
            thumbnail = info.get('thumbnail', '')
            uploader = info.get('uploader', '')

            logger.info(f"Successfully extracted: '{title}' ({format_ext})")

            return jsonify({
                "success": True,
                "direct_url": direct_url,
                "title": title,
                "format": format_ext,
                "size": filesize,
                "duration": duration,
                "thumbnail": thumbnail,
                "uploader": uploader,
                "extractor": info.get('extractor', 'generic')
            }), 200

    except yt_dlp.utils.DownloadError as de:
        logger.warning(f"yt-dlp download error for {url}: {de}")
        return jsonify({
            "success": False,
            "error": f"فشل الاستخراج: {str(de).split(':')[-1].strip()}"
        }), 400
    except Exception as e:
        logger.error(f"Unexpected error extracting {url}: {e}", exc_info=True)
        return jsonify({
            "success": False,
            "error": f"خطأ داخلي في الخادم: {str(e)}"
        }), 500

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)
