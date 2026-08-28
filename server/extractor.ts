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
// Instagram & Twitter / X Extractors
// -------------------------------------------------------------

async function extractInstagramSaveClip(url: string): Promise<ExtractionResult | null> {
  try {
    const resp = await axios.post(
      'https://api.saveclip.app/v1/get',
      { url },
      {
        timeout: 5000,
        headers: { 'User-Agent': BROWSER_UA },
      }
    );

    if (resp.status === 200 && resp.data?.data?.length > 0) {
      const first = resp.data.data[0];
      const directUrl = first.url || first.video_url;
      if (directUrl) {
        return {
          success: true,
          direct_url: directUrl,
          title: `Instagram_Reel_${Date.now()}`,
          format: 'mp4',
          thumbnail: first.thumbnail,
          provider: 'SaveClip Instagram HD',
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
          provider: 'Twitsave X Engine',
        };
      }
    }
  } catch (_) {}
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

  // 3. DEDICATED INSTAGRAM ENGINE
  if (lower.includes('instagram.com')) {
    console.log(`[UniversalExtractor] 📸 Launching Instagram Engine for: ${cleanUrl}`);
    const igResult = await extractInstagramSaveClip(cleanUrl);
    if (igResult && igResult.direct_url) return igResult;

    const cobaltResult = await extractCobalt(cleanUrl);
    if (cobaltResult && cobaltResult.direct_url) return cobaltResult;
  }

  // 4. DEDICATED TWITTER / X ENGINE
  if (lower.includes('twitter.com') || lower.includes('x.com')) {
    console.log(`[UniversalExtractor] 🐦 Launching Twitter/X Engine for: ${cleanUrl}`);
    const twResult = await extractTwitterTwitsave(cleanUrl);
    if (twResult && twResult.direct_url) return twResult;

    const cobaltResult = await extractCobalt(cleanUrl);
    if (cobaltResult && cobaltResult.direct_url) return cobaltResult;
  }

  // 5. GENERAL COBALT ENGINE (Facebook, Reddit, Vimeo, Pinterest, etc.)
  try {
    const cobaltRes = await extractCobalt(cleanUrl);
    if (cobaltRes && cobaltRes.direct_url) {
      return cobaltRes;
    }
  } catch (_) {}

  // 6. DIRECT FILE STREAM PROBE (APK, ISO, ZIP, MP4 direct, etc.)
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
