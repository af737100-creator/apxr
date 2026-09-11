import os
import time
from flask import Flask, request, jsonify
import yt_dlp

app = Flask(__name__)

# yt-dlp base options
YDL_OPTIONS = {
    'format': 'best[ext=mp4]/best',
    'quiet': True,
    'no_warnings': True,
    'noplaylist': True,
    'skip_download': True,
}

def extract_with_retry(url, max_retries=3):
    last_error = None
    for attempt in range(1, max_retries + 1):
        try:
            with yt_dlp.YoutubeDL(YDL_OPTIONS) as ydl:
                info = ydl.extract_info(url, download=False)
                if not info:
                    raise Exception("No video info returned")

                # Determine direct URL
                direct_url = info.get('url')
                format_ext = info.get('ext', 'mp4')
                filesize = info.get('filesize') or info.get('filesize_approx') or 0

                # Fallback to formats list if top-level url is not present
                if not direct_url and info.get('formats'):
                    formats = info.get('formats', [])
                    valid_formats = [f for f in formats if f.get('url')]
                    if valid_formats:
                        chosen = valid_formats[-1]
                        direct_url = chosen.get('url')
                        format_ext = chosen.get('ext', format_ext)
                        filesize = chosen.get('filesize') or chosen.get('filesize_approx') or filesize

                if not direct_url:
                    raise Exception("Could not find a direct stream URL")

                title = info.get('title', 'Video')
                return {
                    "success": True,
                    "direct_url": direct_url,
                    "title": title,
                    "format": format_ext,
                    "size": filesize
                }
        except Exception as e:
            last_error = str(e)
            if attempt < max_retries:
                time.sleep(1)

    return {
        "success": False,
        "error": last_error or "Extraction failed after 3 retries"
    }

@app.route('/extract', methods=['GET'])
def extract_endpoint():
    url = request.args.get('url', '').strip()
    if not url:
        return jsonify({
            "success": False,
            "error": "Missing 'url' query parameter"
        }), 400

    result = extract_with_retry(url, max_retries=3)
    status_code = 200 if result.get("success") else 500
    return jsonify(result), status_code

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port)
