import os
import gc
import time
import threading
from flask import Flask, request, jsonify
import yt_dlp

app = Flask(__name__)
app.config['JSON_AS_ASCII'] = False

# Strict concurrency lock for 512MB RAM environments (prevents OOM crashes)
EXTRACTION_SEMAPHORE = threading.Semaphore(2)

# Memory-optimized yt-dlp configuration for 512MB RAM
YDL_BASE_OPTIONS = {
    'format': 'b/best[protocol^=http]/18/22/136/140/best',
    'quiet': True,
    'no_warnings': True,
    'noplaylist': True,
    'skip_download': True,
    'cachedir': False,                 # Do not use disk cache to save RAM
    'extract_flat': 'discard_in_playlist',
    'no_color': True,
    'socket_timeout': 10,             # 10-second socket timeout
}

def extract_stream_info(url, max_retries=2):
    """
    Extracts direct media stream info with minimal memory footprint.
    Forces Python garbage collection immediately after extraction.
    """
    last_error = None

    # Limit concurrent extractions to protect 512MB RAM
    with EXTRACTION_SEMAPHORE:
        for attempt in range(1, max_retries + 1):
            try:
                with yt_dlp.YoutubeDL(YDL_BASE_OPTIONS) as ydl:
                    info = ydl.extract_info(url, download=False)
                    if not info:
                        raise Exception("No video information returned")

                    # Extract direct stream URL
                    direct_url = info.get('url')
                    format_ext = info.get('ext', 'mp4')
                    filesize = info.get('filesize') or info.get('filesize_approx') or 0
                    title = info.get('title', 'Video_Stream')
                    thumbnail = info.get('thumbnail') or ''

                    # Inspect formats list if top-level direct URL is missing
                    if not direct_url and info.get('formats'):
                        formats = info.get('formats', [])
                        # Prefer mp4 formats with both video & audio or standard stream
                        valid_formats = [f for f in formats if f.get('url')]
                        if valid_formats:
                            chosen = valid_formats[-1]
                            direct_url = chosen.get('url')
                            format_ext = chosen.get('ext', format_ext)
                            filesize = chosen.get('filesize') or chosen.get('filesize_approx') or filesize

                    if not direct_url:
                        raise Exception("Could not resolve a direct media stream URL")

                    return {
                        "success": True,
                        "direct_url": direct_url,
                        "title": title,
                        "format": format_ext,
                        "size": filesize,
                        "thumbnail": thumbnail,
                        "provider": "Wispbyte yt-dlp SpeedCore ⚡",
                        "status": "stream"
                    }

            except Exception as e:
                last_error = str(e)
                if attempt < max_retries:
                    time.sleep(0.5)
            finally:
                # Force garbage collection immediately to keep memory under 512MB
                gc.collect()

    return {
        "success": False,
        "error": last_error or "Extraction failed on Wispbyte server"
    }

@app.route('/', methods=['GET'])
@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint for platform monitoring & uptime probes."""
    return jsonify({
        "status": "online",
        "service": "PulseSphere Wispbyte Extractor",
        "ram_mode": "512MB-Optimized",
        "timestamp": int(time.time())
    }), 200

@app.route('/extract', methods=['GET', 'POST'])
def extract_endpoint():
    """
    Main extraction endpoint.
    Accepts GET /extract?url=... or POST JSON { "url": "..." }
    """
    url = ''
    if request.method == 'POST':
        data = request.get_json(silent=True) or {}
        url = (data.get('url') or '').strip()
    
    if not url:
        url = request.args.get('url', '').strip()

    if not url:
        return jsonify({
            "success": False,
            "error": "Missing 'url' parameter"
        }), 400

    result = extract_stream_info(url, max_retries=2)
    status_code = 200 if result.get("success") else 500
    return jsonify(result), status_code

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    # Threaded mode on port, single worker development fallback
    app.run(host='0.0.0.0', port=port, threaded=True)
