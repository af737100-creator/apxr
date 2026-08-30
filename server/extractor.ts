import axios from 'axios';

export interface ExtractionResult {
  success: boolean;
  direct_url?: string;
  title?: string;
  format?: string;
  size?: number;
  duration?: number;
  thumbnail?: string;
  uploader?: string;
  provider?: string;
  error?: string;
}

// User-Agent presets to avoid bot blocks
const BROWSER_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';
const MOBILE_UA =
  'Mozilla/5.0 (Linux; Android 14; Mobile; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.6613.127 Mobile Safari/537.36';

// Helper to extract YouTube video ID
export function extractYouTubeId(url: string): string | null {
  const match = url.match(/(?:youtu\.be\/|youtube\.com\/(?:embed\/|v\/|shorts\/|live\/|watch\?v=|watch\?.+&v=))([\w-]{11})/i);
  return match ? match[1] : null;
}

// -------------------------------------------------------------
// YouTube Extractors
// -------------------------------------------------------------

async function extractYouTubeSaveTube(videoId: string, rawUrl: string): Promise<ExtractionResult | null> {
  const endpoints = [
    'https://cdn51.savetube.me/info',
    'https://cdn35.savetube.me/info',
    'https://cdn54.savetube.me/info',
  ];

  for (const ep of endpoints) {
    try {
      const resp = await axios.get(ep, {
        params: { url: `https://www.youtube.com/watch?v=${videoId}` },
        timeout: 4000,
        headers: { 'User-Agent': BROWSER_UA },
      });

      if (resp.status === 200 && resp.data?.data) {
        const data = resp.data.data;
        const formats = data.video_formats || [];
        if (formats.length > 0) {
          const chosen = formats[0]; // Best progressive
          if (chosen.url) {
            return {
              success: true,
              direct_url: chosen.url,
              title: (data.title || `YouTube_${videoId}`).replace(/[\\/:*?"<>|]/g, '_'),
              format: 'mp4',
              thumbnail: data.thumbnail,
              duration: data.duration,
              provider: 'SaveTube CDN ⚡',
            };
          }
        }
      }
    } catch (_) {}
  }
  return null;
}

async function extractYouTubeInvidious(videoId: string): Promise<ExtractionResult | null> {
  const instances = [
    'https://inv.tux.pizza',
    'https://invidious.nerdvpn.de',
    'https://invidious.private.coffee',
    'https://yewtu.be',
    'https://iv.melmac.space',
    'https://vid.puffyan.us',
    'https://invidious.protokolla.fi',
  ];

  const requests = instances.map(async (host) => {
    try {
      const resp = await axios.get(`${host}/api/v1/videos/${videoId}`, {
        timeout: 4000,
        headers: { 'User-Agent': BROWSER_UA },
      });

      if (resp.status === 200 && resp.data) {
        const data = resp.data;
        const formatStreams = data.formatStreams || [];
        if (formatStreams.length > 0) {
          // Look for 720p or highest progressive
          let chosen = formatStreams[0];
          for (const f of formatStreams) {
            if (f.qualityLabel?.includes('720') || f.resolution?.includes('720')) {
              chosen = f;
              break;
            }
          }
          if (chosen?.url) {
            let directUrl = chosen.url;
            if (directUrl.startsWith('/')) directUrl = `${host}${directUrl}`;
            return {
              success: true,
              direct_url: directUrl,
              title: (data.title || `YouTube_${videoId}`).replace(/[\\/:*?"<>|]/g, '_'),
              format: 'mp4',
              thumbnail: `https://img.youtube.com/vi/${videoId}/hqdefault.jpg`,
              duration: data.lengthSeconds,
              provider: `Invidious (${host})`,
            } as ExtractionResult;
          }
        }
      }
    } catch (_) {}
    return null;
  });

  try {
    const winner = await Promise.any(requests);
    if (winner && winner.direct_url) return winner;
  } catch (_) {}

  return null;
}

async function extractYouTubePiped(videoId: string): Promise<ExtractionResult | null> {
  const instances = [
    'https://pipedapi.kavin.rocks',
    'https://api.piped.privacydev.net',
    'https://pipedapi.tokhmi.xyz',
  ];

  for (const host of instances) {
    try {
      const resp = await axios.get(`${host}/streams/${videoId}`, {
        timeout: 4000,
        headers: { 'User-Agent': BROWSER_UA },
      });

      if (resp.status === 200 && resp.data?.videoStreams) {
        const streams = resp.data.videoStreams;
        const mp4Stream = streams.find((s: any) => s.format === 'mp4' || s.url?.includes('.mp4')) || streams[0];
        if (mp4Stream?.url) {
          return {
            success: true,
            direct_url: mp4Stream.url,
            title: (resp.data.title || `YouTube_${videoId}`).replace(/[\\/:*?"<>|]/g, '_'),
            format: 'mp4',
            thumbnail: resp.data.thumbnailUrl || `https://img.youtube.com/vi/${videoId}/hqdefault.jpg`,
            duration: resp.data.duration,
            provider: `Piped API (${host})`,
          };
        }
      }
    } catch (_) {}
  }
  return null;
}

// -------------------------------------------------------------
// TikTok Extractors
// -------------------------------------------------------------

async function extractTikTokTikWM(url: string): Promise<ExtractionResult | null> {
  try {
    const resp = await axios.get('https://www.tikwm.com/api/', {
      params: { url, hd: 1 },
      timeout: 4500,
      headers: {
        'User-Agent': BROWSER_UA,
        Referer: 'https://www.tikwm.com/',
      },
    });

    if (resp.status === 200 && resp.data?.code === 0 && resp.data?.data) {
      const data = resp.data.data;
      let playUrl = data.play || data.hdplay || data.wmplay;
      if (playUrl) {
        if (playUrl.startsWith('/')) playUrl = `https://www.tikwm.com${playUrl}`;
        return {
          success: true,
          direct_url: playUrl,
          title: (data.title || `TikTok_${Date.now()}`).replace(/[\\/:*?"<>|]/g, '_').slice(0, 60),
          format: 'mp4',
          size: data.size || 0,
          duration: data.duration || 0,
          thumbnail: data.cover,
          uploader: data.author?.nickname || data.author?.unique_id,
          provider: 'TikWM HD (No Watermark)',
        };
      }
    }
  } catch (_) {}
  return null;
}

async function extractTikTokTiklydown(url: string): Promise<ExtractionResult | null> {
  try {
    const resp = await axios.get('https://api.tiklydown.eu.org/api/download', {
      params: { url },
      timeout: 4500,
      headers: { 'User-Agent': BROWSER_UA },
    });

    if (resp.status === 200 && resp.data?.video) {
      const directUrl = resp.data.video.noWatermark || resp.data.video.watermark;
      if (directUrl) {
        return {
          success: true,
          direct_url: directUrl,
          title: (resp.data.title || `TikTok_${Date.now()}`).replace(/[\\/:*?"<>|]/g, '_').slice(0, 60),
          format: 'mp4',
          thumbnail: resp.data.video.cover,
          provider: 'Tiklydown Engine',
        };
      }
    }
  } catch (_) {}
  return null;
}

async function extractTikTokLoveTik(url: string): Promise<ExtractionResult | null> {
  try {
    const params = new URLSearchParams();
    params.append('query', url);

    const resp = await axios.post('https://lovetik.com/api/ajax/search', params, {
      timeout: 4500,
      headers: {
        'User-Agent': BROWSER_UA,
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      },
    });

    if (resp.status === 200 && resp.data?.links?.length > 0) {
      const link = resp.data.links[0]?.a;
      if (link) {
        return {
          success: true,
          direct_url: link,
          title: (resp.data.desc || `TikTok_${Date.now()}`).replace(/[\\/:*?"<>|]/g, '_').slice(0, 60),
          format: 'mp4',
          thumbnail: resp.data.cover,
          provider: 'LoveTik Engine',
        };
      }
    }
  } catch (_) {}
  return null;
}

// -------------------------------------------------------------
// Instagram, Facebook, Threads, Twitter, Reddit & Universal Extractors
// -------------------------------------------------------------

// Helper to resolve shortlinks & redirects (fb.watch, facebook.com/share, etc.)
async function resolveCanonicalUrl(url: string): Promise<string> {
  const lower = url.toLowerCase();
  if (
    lower.includes('fb.watch') ||
    lower.includes('facebook.com/share/') ||
    lower.includes('instagram.com/share/') ||
    lower.includes('vm.tiktok.com') ||
    lower.includes('vt.tiktok.com') ||
    lower.includes('youtu.be/') ||
    lower.includes('bit.ly/') ||
    lower.includes('t.co/')
  ) {
    try {
      const resp = await axios.get(url, {
        maxRedirects: 5,
        timeout: 3500,
        headers: { 'User-Agent': BROWSER_UA },
      });
      if (resp.request?.res?.responseUrl) {
        return resp.request.res.responseUrl;
      }
    } catch (_) {}
  }
  return url;
}

async function extractInstagramMulti(rawUrl: string): Promise<ExtractionResult | null> {
  const url = await resolveCanonicalUrl(rawUrl);

  // Method 1: SaveClip
  try {
    const resp = await axios.post(
      'https://api.saveclip.app/v1/get',
      { url },
      {
        timeout: 5000,
        headers: { 'User-Agent': BROWSER_UA, Accept: 'application/json' },
      }
    );

    if (resp.status === 200 && resp.data?.data?.length > 0) {
      const first = resp.data.data[0];
      const directUrl = first.url || first.video_url;
      if (directUrl && String(directUrl).startsWith('http')) {
        return {
          success: true,
          direct_url: directUrl,
          title: `Instagram_Media_${Date.now()}`,
          format: 'mp4',
          thumbnail: first.thumbnail,
          provider: 'SaveClip Instagram Engine 📸',
        };
      }
    }
  } catch (_) {}

  // Method 2: FastDL / SnapInsta scraper
  try {
    const params = new URLSearchParams();
    params.append('q', url);
    params.append('t', 'media');
    params.append('lang', 'en');

    const resp = await axios.post('https://v3.fastdl.app/api/convert', params, {
      timeout: 5000,
      headers: {
        'User-Agent': BROWSER_UA,
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'X-Requested-With': 'XMLHttpRequest',
      },
    });

    if (resp.status === 200 && resp.data?.html) {
      const html = resp.data.html;
      const match = html.match(/href="([^"]+)"[^>]*title="Download Video"/i) ||
                    html.match(/href="(https:\/\/[^"]+\.mp4[^"]*)"/i) ||
                    html.match(/class="btn-download[^"]*"[^>]*href="([^"]+)"/i);
      if (match && match[1]) {
        return {
          success: true,
          direct_url: match[1].replace(/&amp;/g, '&'),
          title: `Instagram_Reel_${Date.now()}`,
          format: 'mp4',
          provider: 'FastDL Instagram Engine ⚡',
        };
      }
    }
  } catch (_) {}

  // Method 3: SaveIG API
  try {
    const params = new URLSearchParams();
    params.append('q', url);
    params.append('t', 'media');
    params.append('lang', 'en');

    const resp = await axios.post('https://saveig.app/api/ajaxSearch', params, {
      timeout: 4500,
      headers: {
        'User-Agent': BROWSER_UA,
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'X-Requested-With': 'XMLHttpRequest',
      },
    });

    if (resp.status === 200 && resp.data?.data) {
      const html = resp.data.data;
      const match = html.match(/href="([^"]+)"[^>]*download/i) ||
                    html.match(/href="(https:\/\/[^"]+\.mp4[^"]*)"/i);
      if (match && match[1]) {
        return {
          success: true,
          direct_url: match[1].replace(/&amp;/g, '&'),
          title: `Instagram_Media_${Date.now()}`,
          format: 'mp4',
          provider: 'SaveIG Engine 📸',
        };
      }
    }
  } catch (_) {}

  // Method 4: Instagram Embed Scraper
  try {
    const shortcodeMatch = url.match(/instagram\.com\/(?:p|reel|reels)\/([A-Za-z0-9_-]+)/i);
    if (shortcodeMatch && shortcodeMatch[1]) {
      const embedUrl = `https://www.instagram.com/p/${shortcodeMatch[1]}/embed/captioned/`;
      const resp = await axios.get(embedUrl, {
        timeout: 4500,
        headers: { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15' },
      });

      if (resp.status === 200 && resp.data) {
        const body = String(resp.data);
        const match = body.match(/"video_url":"([^"]+)"/i) || body.match(/src="(https:\/\/[^"]+\.mp4[^"]*)"/i);
        if (match && match[1]) {
          const streamUrl = match[1].replace(/\\u0026/g, '&').replace(/\\\//g, '/').replace(/\\/g, '');
          return {
            success: true,
            direct_url: streamUrl,
            title: `Instagram_Reel_${Date.now()}`,
            format: 'mp4',
            provider: 'Instagram Embed Stream ⚡',
          };
        }
      }
    }
  } catch (_) {}

  // Method 5: Direct Instagram GraphQL Public endpoint
  try {
    let cleanIgUrl = url.split('?')[0];
    if (!cleanIgUrl.endsWith('/')) cleanIgUrl += '/';
    const jsonUrl = `${cleanIgUrl}?__a=1&__d=dis`;

    const resp = await axios.get(jsonUrl, {
      timeout: 4000,
      headers: {
        'User-Agent': MOBILE_UA,
        'Sec-Fetch-Site': 'same-origin',
        Accept: '*/*',
      },
    });

    if (resp.status === 200 && resp.data) {
      const items = resp.data.graphql?.shortcode_media || resp.data.items?.[0];
      const videoUrl = items?.video_url || items?.video_versions?.[0]?.url;
      if (videoUrl) {
        return {
          success: true,
          direct_url: videoUrl,
          title: `Instagram_${Date.now()}`,
          format: 'mp4',
          thumbnail: items?.display_url,
          provider: 'Instagram Direct CDN ⚡',
        };
      }
    }
  } catch (_) {}

  return null;
}

async function extractFacebookMulti(rawUrl: string): Promise<ExtractionResult | null> {
  const url = await resolveCanonicalUrl(rawUrl);

  // Method 1: SnapSave / FBDownloader API
  try {
    const params = new URLSearchParams();
    params.append('url', url);

    const resp = await axios.post('https://snapsave.app/action.php?lang=en', params, {
      timeout: 5000,
      headers: {
        'User-Agent': BROWSER_UA,
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'X-Requested-With': 'XMLHttpRequest',
      },
    });

    if (resp.status === 200 && resp.data) {
      const body = typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data);
      const match = body.match(/href=\\"([^\\"]+)\\"[^>]*class=\\"button is-success/i) ||
                    body.match(/(https:\/\/[^"'\\]+\.mp4[^"'\\]*)/i);
      if (match && match[1]) {
        let streamUrl = match[1].replace(/\\/g, '').replace(/&amp;/g, '&');
        return {
          success: true,
          direct_url: streamUrl,
          title: `Facebook_Video_${Date.now()}`,
          format: 'mp4',
          provider: 'SnapSave Facebook HD ⚡',
        };
      }
    }
  } catch (_) {}

  // Method 2: FBDownloader Ajax API
  try {
    const params = new URLSearchParams();
    params.append('q', url);
    params.append('t', 'media');
    params.append('lang', 'en');

    const resp = await axios.post('https://fbdownloader.to/api/ajaxSearch', params, {
      timeout: 4500,
      headers: {
        'User-Agent': BROWSER_UA,
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'X-Requested-With': 'XMLHttpRequest',
      },
    });

    if (resp.status === 200 && resp.data?.data) {
      const html = String(resp.data.data);
      const match = html.match(/href="([^"]+)"[^>]*class="button[^"]*is-success/i) ||
                    html.match(/href="(https:\/\/[^"]+\.mp4[^"]*)"/i);
      if (match && match[1]) {
        return {
          success: true,
          direct_url: match[1].replace(/&amp;/g, '&'),
          title: `Facebook_Video_${Date.now()}`,
          format: 'mp4',
          provider: 'FBDownloader Engine ⚡',
        };
      }
    }
  } catch (_) {}

  // Method 3: FDown / Getfvid Parser
  try {
    const params = new URLSearchParams();
    params.append('url', url);

    const resp = await axios.post('https://fdown.net/download.php', params, {
      timeout: 5000,
      headers: {
        'User-Agent': BROWSER_UA,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
    });

    if (resp.status === 200 && resp.data) {
      const body = resp.data.toString();
      const hdMatch = body.match(/id="hd"[\s\S]*?href="([^"]+)"/i);
      const sdMatch = body.match(/id="sd"[\s\S]*?href="([^"]+)"/i);
      const streamUrl = hdMatch?.[1] || sdMatch?.[1];

      if (streamUrl && streamUrl.startsWith('http')) {
        return {
          success: true,
          direct_url: streamUrl.replace(/&amp;/g, '&'),
          title: `Facebook_Video_${Date.now()}`,
          format: 'mp4',
          provider: 'FDown Facebook Engine ⚡',
        };
      }
    }
  } catch (_) {}

  // Method 4: GetFVid Parser
  try {
    const params = new URLSearchParams();
    params.append('url', url);

    const resp = await axios.post('https://www.getfvid.com/downloader', params, {
      timeout: 4500,
      headers: {
        'User-Agent': BROWSER_UA,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
    });

    if (resp.status === 200 && resp.data) {
      const html = resp.data.toString();
      const hdMatch = html.match(/href="([^"]+)"[^>]*class="btn btn-download[^"]*"/i) ||
                      html.match(/href="(https:\/\/[^"]+\.mp4[^"]*)"/i);
      if (hdMatch && hdMatch[1]) {
        return {
          success: true,
          direct_url: hdMatch[1].replace(/&amp;/g, '&'),
          title: `Facebook_Video_${Date.now()}`,
          format: 'mp4',
          provider: 'GetFVid Facebook Engine ⚡',
        };
      }
    }
  } catch (_) {}

  // Method 5: FB Video Mobile HTML scraper
  try {
    let mobileUrl = url.replace('www.facebook.com', 'm.facebook.com').replace('web.facebook.com', 'm.facebook.com');
    const resp = await axios.get(mobileUrl, {
      timeout: 4500,
      headers: {
        'User-Agent': MOBILE_UA,
        'Accept-Language': 'en-US,en;q=0.9',
      },
    });

    if (resp.status === 200 && resp.data) {
      const html = resp.data.toString();
      const hdMatch = html.match(/"playable_url_quality_hd":"([^"]+)"/i) || html.match(/"browser_native_hd_url":"([^"]+)"/i);
      const sdMatch = html.match(/"playable_url":"([^"]+)"/i) || html.match(/"browser_native_sd_url":"([^"]+)"/i) || html.match(/"sd_src":"([^"]+)"/i);
      let streamUrl = hdMatch?.[1] || sdMatch?.[1];

      if (streamUrl) {
        streamUrl = streamUrl.replace(/\\\//g, '/').replace(/\\u0026/g, '&').replace(/\\/g, '');
        return {
          success: true,
          direct_url: streamUrl,
          title: `Facebook_Video_${Date.now()}`,
          format: 'mp4',
          provider: 'Facebook Direct Stream ⚡',
        };
      }
    }
  } catch (_) {}

  return null;
}

async function extractTwitterTwitsave(url: string): Promise<ExtractionResult | null> {
  try {
    const resp = await axios.get('https://twitsave.com/info', {
      params: { url },
      timeout: 5000,
      headers: { 'User-Agent': BROWSER_UA },
    });

    if (resp.status === 200 && resp.data) {
      const match = resp.data.match(/href="(https:\/\/[^"]+\.mp4[^"]*)"/i);
      if (match && match[1]) {
        return {
          success: true,
          direct_url: match[1],
          title: `Twitter_X_Video_${Date.now()}`,
          format: 'mp4',
          provider: 'Twitsave X Engine ⚡',
        };
      }
    }
  } catch (_) {}
  return null;
}

// Universal All-In-One Downloader (Pinterest, Reddit, Threads, Snapchat, Dailymotion, Vimeo)
async function extractUniversalSocialMulti(url: string): Promise<ExtractionResult | null> {
  // Method 1: Cobalt Engine across instances
  const cobalt = await extractCobalt(url);
  if (cobalt && cobalt.direct_url) {
    return cobalt;
  }

  // Method 2: Public Media Downloader APIs
  const apiHosts = [
    {
      endpoint: 'https://api.vkrdownloader.com/server',
      params: { vkr: url },
    },
    {
      endpoint: 'https://api.savefrom.net/api/convert',
      params: { url: url },
    }
  ];

  for (const api of apiHosts) {
    try {
      const resp = await axios.get(api.endpoint, {
        params: api.params,
        timeout: 4500,
        headers: { 'User-Agent': BROWSER_UA },
      });

      if (resp.status === 200 && resp.data) {
        const d = resp.data;
        const directUrl = d.url || d.download_url || d.video_url || (d.downloads && d.downloads[0]?.url);
        if (directUrl && String(directUrl).startsWith('http')) {
          return {
            success: true,
            direct_url: directUrl,
            title: (d.title || `Media_${Date.now()}`).replace(/[\\/:*?"<>|]/g, '_'),
            format: 'mp4',
            thumbnail: d.thumbnail || d.thumb,
            provider: 'Universal Social Multi-Server 🌐',
          };
        }
      }
    } catch (_) {}
  }

  return null;
}

// -------------------------------------------------------------
// Cobalt Multi-Instance Extractor
// -------------------------------------------------------------

async function extractCobalt(url: string): Promise<ExtractionResult | null> {
  const instances = [
    'https://api.cobalt.tools',
    'https://cobalt.api.redteam.tools',
    'https://co.wuk.sh',
    'https://cobalt.stream',
    'https://cobalt.hyonsu.com',
  ];

  for (const host of instances) {
    try {
      const resp = await axios.post(
        host.endsWith('/') ? host : `${host}/`,
        {
          url,
          videoQuality: '1080',
          audioFormat: 'mp3',
        },
        {
          timeout: 4500,
          headers: {
            Accept: 'application/json',
            'Content-Type': 'application/json',
            'User-Agent': BROWSER_UA,
          },
        }
      );

      if (resp.status === 200 && resp.data) {
        const streamUrl = resp.data.url || (resp.data.picker && resp.data.picker[0]?.url);
        if (streamUrl) {
          return {
            success: true,
            direct_url: streamUrl,
            title: (resp.data.filename || `HyperPulse_Video_${Date.now()}`).replace(/[\\/:*?"<>|]/g, '_'),
            format: 'mp4',
            provider: `Cobalt Server (${host})`,
          };
        }
      }
    } catch (_) {}
  }
  return null;
}

// -------------------------------------------------------------
// Direct Link Prober (APK, ISO, MP4, ZIP, etc.)
// -------------------------------------------------------------

async function probeDirectLink(url: string): Promise<ExtractionResult | null> {
  try {
    const resp = await axios.head(url, {
      timeout: 5000,
      headers: {
        'User-Agent': BROWSER_UA,
        Accept: '*/*',
      },
      maxRedirects: 5,
    });

    const contentType = String(resp.headers['content-type'] || '');
    const contentLength = parseInt(String(resp.headers['content-length'] || '0'), 10);
    const contentDisposition = String(resp.headers['content-disposition'] || '');

    let filename = url.split('/').pop()?.split('?')[0] || `File_${Date.now()}`;
    const cdMatch = contentDisposition.match(/filename=["']?([^"';]+)["']?/i);
    if (cdMatch && cdMatch[1]) {
      filename = cdMatch[1];
    }

    let format = filename.split('.').pop() || 'bin';
    if (contentType.includes('video/mp4')) format = 'mp4';
    else if (contentType.includes('android.package-archive')) format = 'apk';
    else if (contentType.includes('zip')) format = 'zip';

    return {
      success: true,
      direct_url: url,
      title: filename.replace(/[\\/:*?"<>|]/g, '_'),
      format,
      size: contentLength,
      provider: 'Direct HTTP Stream (Turbo Range Capable)',
    };
  } catch (_) {
    // If HEAD fails, assume direct url is downloadable directly
    const filename = url.split('/').pop()?.split('?')[0] || `File_${Date.now()}`;
    const format = filename.split('.').pop() || 'bin';
    return {
      success: true,
      direct_url: url,
      title: filename.replace(/[\\/:*?"<>|]/g, '_'),
      format,
      provider: 'Direct Fallback Stream',
    };
  }
}

// -------------------------------------------------------------
// Main Universal Extraction Engine with Parallel Multi-Racers
// -------------------------------------------------------------

export async function extractUniversalMedia(rawUrl: string): Promise<ExtractionResult> {
  const cleanUrl = rawUrl.trim();
  if (!cleanUrl) {
    return { success: false, error: 'الرابط المدخل فارغ (URL is empty)' };
  }

  const lower = cleanUrl.toLowerCase();
  const ytId = extractYouTubeId(cleanUrl);

  // 1. DEDICATED YOUTUBE ENGINE RACE
  if (ytId) {
    console.log(`[UniversalExtractor] 🎯 Launching YouTube Turbo Engine for ID: ${ytId}`);

    // Race SaveTube + Invidious + Piped + Cobalt
    const ytRacers: Promise<ExtractionResult | null>[] = [
      extractYouTubeSaveTube(ytId, cleanUrl),
      extractYouTubeInvidious(ytId),
      extractYouTubePiped(ytId),
      extractCobalt(cleanUrl),
    ];

    try {
      const winner = await Promise.any(
        ytRacers.map((p) =>
          p.then((res) => {
            if (res && res.success && res.direct_url) return res;
            throw new Error('Not resolved');
          })
        )
      );
      if (winner && winner.direct_url) {
        console.log(`[UniversalExtractor] ✅ YouTube Winner: ${winner.provider}`);
        return winner;
      }
    } catch (_) {}
  }

  // 2. DEDICATED TIKTOK ENGINE RACE
  if (lower.includes('tiktok.com') || lower.includes('douyin.com')) {
    console.log(`[UniversalExtractor] 🎵 Launching TikTok Engine Race for: ${cleanUrl}`);
    const tikTokRacers = [
      extractTikTokTikWM(cleanUrl),
      extractTikTokTiklydown(cleanUrl),
      extractTikTokLoveTik(cleanUrl),
      extractCobalt(cleanUrl),
    ];

    try {
      const winner = await Promise.any(
        tikTokRacers.map((p) =>
          p.then((res) => {
            if (res && res.success && res.direct_url) return res;
            throw new Error('Not resolved');
          })
        )
      );
      if (winner && winner.direct_url) {
        console.log(`[UniversalExtractor] ✅ TikTok Winner: ${winner.provider}`);
        return winner;
      }
    } catch (_) {}
  }

  // 3. DEDICATED INSTAGRAM ENGINE RACE
  if (lower.includes('instagram.com')) {
    console.log(`[UniversalExtractor] 📸 Launching Instagram Multi Engine for: ${cleanUrl}`);
    const igResult = await extractInstagramMulti(cleanUrl);
    if (igResult && igResult.direct_url) return igResult;

    const cobaltResult = await extractCobalt(cleanUrl);
    if (cobaltResult && cobaltResult.direct_url) return cobaltResult;

    const universal = await extractUniversalSocialMulti(cleanUrl);
    if (universal && universal.direct_url) return universal;
  }

  // 4. DEDICATED FACEBOOK ENGINE RACE
  if (lower.includes('facebook.com') || lower.includes('fb.watch') || lower.includes('fb.com')) {
    console.log(`[UniversalExtractor] 📘 Launching Facebook Multi Engine for: ${cleanUrl}`);
    const fbResult = await extractFacebookMulti(cleanUrl);
    if (fbResult && fbResult.direct_url) return fbResult;

    const cobaltResult = await extractCobalt(cleanUrl);
    if (cobaltResult && cobaltResult.direct_url) return cobaltResult;

    const universal = await extractUniversalSocialMulti(cleanUrl);
    if (universal && universal.direct_url) return universal;
  }

  // 5. DEDICATED TWITTER / X ENGINE
  if (lower.includes('twitter.com') || lower.includes('x.com')) {
    console.log(`[UniversalExtractor] 🐦 Launching Twitter/X Engine for: ${cleanUrl}`);
    const twResult = await extractTwitterTwitsave(cleanUrl);
    if (twResult && twResult.direct_url) return twResult;

    const cobaltResult = await extractCobalt(cleanUrl);
    if (cobaltResult && cobaltResult.direct_url) return cobaltResult;

    const universal = await extractUniversalSocialMulti(cleanUrl);
    if (universal && universal.direct_url) return universal;
  }

  // 6. GENERAL ALL-PLATFORM SOCIAL ENGINE (Threads, Snapchat, Reddit, Pinterest, Vimeo, Dailymotion, etc.)
  if (
    lower.includes('threads.net') ||
    lower.includes('reddit.com') ||
    lower.includes('pinterest.com') ||
    lower.includes('pin.it') ||
    lower.includes('snapchat.com') ||
    lower.includes('vimeo.com') ||
    lower.includes('dailymotion.com') ||
    lower.includes('bilibili.com') ||
    lower.includes('soundcloud.com')
  ) {
    console.log(`[UniversalExtractor] 🌐 Launching Universal Social Racer for: ${cleanUrl}`);
    const universal = await extractUniversalSocialMulti(cleanUrl);
    if (universal && universal.direct_url) return universal;

    const cobaltRes = await extractCobalt(cleanUrl);
    if (cobaltRes && cobaltRes.direct_url) return cobaltRes;
  }

  // 7. GENERAL COBALT ENGINE BACKUP
  try {
    const cobaltRes = await extractCobalt(cleanUrl);
    if (cobaltRes && cobaltRes.direct_url) {
      return cobaltRes;
    }
  } catch (_) {}

  // 8. DIRECT FILE STREAM PROBE (APK, ISO, ZIP, MP4 direct, etc.)
  console.log(`[UniversalExtractor] 🌐 Probing Direct Link for: ${cleanUrl}`);
  const directProbe = await probeDirectLink(cleanUrl);
  if (directProbe && directProbe.direct_url) {
    return directProbe;
  }

  return {
    success: false,
    error: 'تعذر استخراج تيار الفيديو المباشر من هذا الرابط تلقائياً. يمكنك فتحه عبر المتصفح المدمج 🌐 لتشغيله والتقاطه فوراً.',
  };
}
