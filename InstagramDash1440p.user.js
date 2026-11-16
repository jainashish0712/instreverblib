// ==UserScript==
// @name         InstagramDash1440p
// @namespace    com.instagramreverb.dash1440p
// @version      2.0.0
// @description  Ultra High-Definition (1440p / 2K) VP9 DASH Video Streaming Engine for Instagram. Forces 1440p DASH video playback with strict 1080p fallback for active Reels and feed prefetchers.
// @author       InstagramReverb
// @match        https://www.instagram.com/*
// @match        https://instagram.com/*
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_registerMenuCommand
// @run-at       document-start
// ==/UserScript==

(function () {
    'use strict';

    // ============================================================================
    // Mode Constants (mirrors InstagramDash1440pMode enum from .h / .mm)
    // ============================================================================
    const MODE_WIFI_OR_ETHERNET = 0; // 1440p Priority on WiFi/Ethernet; 1080p Max on Cellular
    const MODE_ALWAYS_1440P     = 1; // Unconditional 1440p Priority regardless of connection
    const MODE_DISABLED         = 2; // Disabled: Native Instagram ABR & Playback

    const MODE_NAMES = {
        [MODE_WIFI_OR_ETHERNET]: 'WiFi/Ethernet 1440p (default)',
        [MODE_ALWAYS_1440P]:     'Always 1440p (Forced)',
        [MODE_DISABLED]:         'Disabled (IG Default)',
    };

    const STORAGE_KEY = 'InstagramDash1440p_mode';
    const HUD_POS_KEY = 'InstagramDash1440p_hud_pos';

    // Cross-environment persistent storage helpers
    function getStoredValue(key, defaultVal) {
        if (typeof GM_getValue === 'function') {
            try { return GM_getValue(key, defaultVal); } catch (e) {}
        }
        try {
            const v = localStorage.getItem(key);
            return v !== null ? JSON.parse(v) : defaultVal;
        } catch (e) {
            return defaultVal;
        }
    }

    function setStoredValue(key, val) {
        if (typeof GM_setValue === 'function') {
            try { GM_setValue(key, val); } catch (e) {}
        }
        try {
            localStorage.setItem(key, JSON.stringify(val));
        } catch (e) {}
    }

    // ============================================================================
    // Global State & Telemetry (mirrors static globals in .mm lines 24-29)
    // ============================================================================
    let g_mode                 = parseInt(getStoredValue(STORAGE_KEY, MODE_WIFI_OR_ETHERNET), 10);
    if (isNaN(g_mode) || g_mode < 0 || g_mode > 2) g_mode = MODE_WIFI_OR_ETHERNET;

    let g_isActual1440p        = false;
    let g_currentQuality       = '1440p';
    let g_currentResolution    = '';
    let g_currentRepId         = 'ready';
    const g_repMetadataCache   = new Map(); // repId -> { width, height, tag, bw }

    // Cellular Detection (mirrors InstagramWifiSpoofer_IsCellularData() in .mm)
    function isCellularConnection() {
        if (g_mode === MODE_ALWAYS_1440P) return false;
        try {
            const conn = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
            if (conn) {
                if (conn.type === 'cellular') return true;
                if (conn.saveData) return true;
            }
        } catch (e) {}
        return false;
    }

    function isEnabled() {
        return g_mode !== MODE_DISABLED;
    }

    function setMode(mode) {
        g_mode = mode;
        setStoredValue(STORAGE_KEY, mode);
        notifyStateDidChange();
        updateBadge();
        console.log(`[InstagramDash1440p] Mode set to: ${MODE_NAMES[mode]}`);
    }

    function cycleMode() {
        const next = (g_mode + 1) % 3;
        setMode(next);
        return next;
    }

    function notifyStateDidChange() {
        try {
            window.dispatchEvent(new CustomEvent('InstagramDash1440pStateDidChange', {
                detail: {
                    mode: g_mode,
                    enabled: isEnabled(),
                    isActual1440p: g_isActual1440p,
                    quality: g_currentQuality,
                    resolution: g_currentResolution,
                    repId: g_currentRepId
                }
            }));
        } catch (e) {}
    }

    // ============================================================================
    // Representation Introspection & Classification (mirrors .mm lines 152-240, 424-439)
    // ============================================================================
    const KNOWN_1440P_REP_IDS = ['1539525017490074', '968238693007748'];

    function isAudioRepresentation(rep) {
        if (!rep) return false;
        if (rep.isAudio) return true;
        const mime = (rep.mimeType || '').toLowerCase();
        if (mime.includes('audio')) return true;
        if (rep.audioSamplingRate || (rep.codecs && rep.codecs.includes('mp4a'))) return true;
        const idStr = String(rep.id || '');
        if (idStr.endsWith('a')) return true;
        return false;
    }

    function is1440pRep(width, height, repId, encodingTag) {
        const minDim = Math.min(width, height);
        const maxDim = Math.max(width, height);
        const pixels = width * height;
        const idStr  = String(repId || '').toLowerCase();
        const tagStr = String(encodingTag || '').toLowerCase();

        return (
            minDim >= 1200 ||
            maxDim >= 2200 ||
            pixels >= 2800000 ||
            KNOWN_1440P_REP_IDS.some(k => idStr.includes(k)) ||
            idStr.includes('1440') ||
            idStr.includes('2k') ||
            tagStr.includes('1440') ||
            tagStr.includes('2k')
        );
    }

    function is1080pRep(width, height, repId, encodingTag) {
        if (is1440pRep(width, height, repId, encodingTag)) return false;
        const minDim = Math.min(width, height);
        const maxDim = Math.max(width, height);
        const pixels = width * height;
        const idStr  = String(repId || '').toLowerCase();
        const tagStr = String(encodingTag || '').toLowerCase();

        return (
            minDim >= 960 ||
            maxDim >= 1700 ||
            pixels >= 1600000 ||
            idStr.includes('1080') ||
            tagStr.includes('1080')
        );
    }

    // Cache metadata for reliable on-screen active telemetry (mirrors .mm CacheRepresentationMetadata)
    function cacheRepresentationMetadata(rep) {
        if (!rep || isAudioRepresentation(rep)) return;
        const repId = String(rep.id || '');
        if (!repId) return;

        g_repMetadataCache.set(repId, {
            width:  rep.width || 0,
            height: rep.height || 0,
            tag:    rep.encodingTag || '',
            bw:     rep.bandwidth || 0
        });
    }

    // ============================================================================
    // Core Target Representation Selector (mirrors SelectTargetRepresentation in .mm lines 399-494)
    // ============================================================================
    function selectTargetRepresentation(representations, isPrefetch) {
        if (!representations || !representations.length) return null;

        let rep1440p = null;
        let maxBw1440p = -1;

        let rep1080p = null;
        let maxBw1080p = -1;

        let repHighestUnder1440 = null;
        let maxPixelsUnder1440 = -1;
        let maxBwUnder1440 = -1;

        let repHighest = null;
        let maxPixelsGeneral = -1;
        let maxBwGeneral = -1;

        for (const rep of representations) {
            if (!rep || isAudioRepresentation(rep)) continue;

            cacheRepresentationMetadata(rep);

            const w = rep.width || 0;
            const h = rep.height || 0;
            const bw = rep.bandwidth || 0;
            const pixels = w * h;
            const repId = rep.id || '';
            const tag = rep.encodingTag || '';

            const is1440 = is1440pRep(w, h, repId, tag);
            const is1080 = is1080pRep(w, h, repId, tag);

            // 1. Evaluate 1440p pool (strictly prioritize resolution over bitrate inversion)
            if (is1440) {
                if (!rep1440p || bw > maxBw1440p) {
                    rep1440p = rep;
                    maxBw1440p = bw;
                }
            }

            // 2. Evaluate 1080p fallback floor
            if (is1080) {
                if (!rep1080p || bw > maxBw1080p) {
                    rep1080p = rep;
                    maxBw1080p = bw;
                }
            }

            // 3. Track highest resolution under 1440p (cellular max-cap ceiling)
            if (!is1440) {
                if (pixels > maxPixelsUnder1440) {
                    maxPixelsUnder1440 = pixels;
                    maxBwUnder1440 = bw;
                    repHighestUnder1440 = rep;
                } else if (pixels === maxPixelsUnder1440 && bw > maxBwUnder1440) {
                    maxBwUnder1440 = bw;
                    repHighestUnder1440 = rep;
                }
            }

            // 4. Evaluate general max pool for non-HD edge cases
            if (pixels > maxPixelsGeneral) {
                maxPixelsGeneral = pixels;
                maxBwGeneral = bw;
                repHighest = rep;
            } else if (pixels === maxPixelsGeneral && bw > maxBwGeneral) {
                maxBwGeneral = bw;
                repHighest = rep;
            }
        }

        const isCellular = isCellularConnection();
        let chosen = null;
        if (isCellular) {
            // ONLY ON CELLULAR DATA: 1080p Preferred & Max cap
            chosen = rep1080p || repHighestUnder1440 || rep1440p || representations[0];
        } else {
            // Wi-Fi / Ethernet unmetered: 1440p Priority, 1080p Fallback Floor
            chosen = rep1440p || rep1080p || repHighest || representations[0];
        }
        return chosen;
    }

    // ============================================================================
    // DOMParser-Based DASH MPD Manifest XML Pruning Engine
    // (Preserves 100% of XML structure, child tags, SegmentBase/Initialization)
    // ============================================================================
    function pruneManifestXml(xmlString) {
        if (!xmlString || typeof xmlString !== 'string' || !xmlString.includes('<Representation')) {
            return xmlString;
        }
        if (!isEnabled()) return xmlString;

        try {
            const parser = new DOMParser();
            let doc = parser.parseFromString(xmlString, 'application/xml');
            if (doc.querySelector('parsererror')) {
                doc = parser.parseFromString(xmlString, 'text/xml');
                if (doc.querySelector('parsererror')) return xmlString;
            }

            // Namespace-safe element retrieval
            const getElements = (parent, tag) => {
                if (typeof parent.getElementsByTagNameNS === 'function') {
                    const ns = parent.getElementsByTagNameNS('*', tag);
                    if (ns && ns.length) return Array.from(ns);
                }
                return Array.from(parent.getElementsByTagName(tag));
            };

            const adaptationSets = getElements(doc, 'AdaptationSet');
            if (!adaptationSets || !adaptationSets.length) return xmlString;

            let modified = false;

            adaptationSets.forEach(adapt => {
                const contentType = (adapt.getAttribute('contentType') || '').toLowerCase();
                const mimeType    = (adapt.getAttribute('mimeType') || '').toLowerCase();

                // Skip pure audio adaptation sets
                if (contentType === 'audio' || mimeType.includes('audio')) return;

                const repElements = getElements(adapt, 'Representation');
                if (!repElements.length) return;

                // Separate video and audio representations inside this adaptation set
                const videoReps = [];
                repElements.forEach(el => {
                    const elMime = (el.getAttribute('mimeType') || mimeType).toLowerCase();
                    const isAudio = elMime.includes('audio') ||
                                    el.hasAttribute('audioSamplingRate') ||
                                    (el.getAttribute('codecs') || '').includes('mp4a') ||
                                    (el.getAttribute('id') || '').endsWith('a');

                    if (isAudio) return;

                    const width       = parseInt(el.getAttribute('width') || '0', 10);
                    const height      = parseInt(el.getAttribute('height') || '0', 10);
                    const bandwidth   = parseInt(el.getAttribute('bandwidth') || '0', 10);
                    const id          = el.getAttribute('id') || '';
                    const encodingTag = el.getAttribute('encodingTag') || el.getAttribute('FBQualityLabel') || '';

                    // Must have dimensions or explicit video mime
                    if (width > 0 || height > 0 || elMime.includes('video')) {
                        videoReps.push({
                            element: el,
                            width,
                            height,
                            bandwidth,
                            id,
                            encodingTag
                        });
                    }
                });

                if (videoReps.length <= 1) return;

                // Select target representation using .mm logic
                const chosen = selectTargetRepresentation(videoReps, false);
                if (!chosen || !chosen.element) return;

                // Remove all other video representations from this AdaptationSet
                videoReps.forEach(r => {
                    if (r.element !== chosen.element && r.element.parentNode) {
                        r.element.parentNode.removeChild(r.element);
                        modified = true;
                    }
                });

                // Update adaptation set boundary attributes to match chosen stream
                if (chosen.width > 0) adapt.setAttribute('maxWidth', String(chosen.width));
                if (chosen.height > 0) adapt.setAttribute('maxHeight', String(chosen.height));

                // Update telemetry from chosen rep
                const is1440 = is1440pRep(chosen.width, chosen.height, chosen.id, chosen.encodingTag);
                const is1080 = is1080pRep(chosen.width, chosen.height, chosen.id, chosen.encodingTag);
                const minDim = Math.min(chosen.width, chosen.height);

                g_isActual1440p     = is1440;
                g_currentQuality    = is1440 ? '1440p' : (is1080 ? '1080p' : `${minDim > 0 ? minDim : 1080}p`);
                g_currentRepId      = chosen.id || 'ready';
                g_currentResolution = (chosen.width > 0 && chosen.height > 0)
                    ? `${chosen.width}x${chosen.height}`
                    : (is1440 ? '1440x2560' : '1080x1920');

                notifyStateDidChange();
                updateBadge();
            });

            if (!modified) return xmlString;
            return new XMLSerializer().serializeToString(doc);
        } catch (e) {
            console.error('[InstagramDash1440p] XML Pruning Error:', e);
            return xmlString;
        }
    }

    // ============================================================================
    // Recursive JSON Manifest & Video Versions Pruner
    // (Intercepts GraphQL / API JSON responses containing video_dash_manifest)
    // ============================================================================
    function pruneObjectManifests(obj) {
        if (!obj || typeof obj !== 'object' || !isEnabled()) return obj;

        try {
            if (Array.isArray(obj)) {
                for (let i = 0; i < obj.length; i++) {
                    obj[i] = pruneObjectManifests(obj[i]);
                }
                return obj;
            }

            for (const key of Object.keys(obj)) {
                const val = obj[key];
                if (!val) continue;

                // 1. DASH Manifest XML string inside JSON
                if ((key === 'video_dash_manifest' || key === 'dash_manifest') && typeof val === 'string') {
                    if (val.includes('<Representation')) {
                        obj[key] = pruneManifestXml(val);
                    }
                }
                // 2. Direct video versions fallback array (sort highest resolution first)
                else if (key === 'video_versions' && Array.isArray(val) && val.length > 1) {
                    val.sort((a, b) => {
                        const pxA = (a.width || 0) * (a.height || 0);
                        const pxB = (b.width || 0) * (b.height || 0);
                        return pxB - pxA; // descending
                    });
                }
                // 3. Recurse into nested structures
                else if (typeof val === 'object') {
                    obj[key] = pruneObjectManifests(val);
                }
            }
        } catch (e) {}
        return obj;
    }

    // ============================================================================
    // JSON.parse Interception: Deep Interception before React / Relay Store
    // ============================================================================
    const origJsonParse = JSON.parse;
    JSON.parse = function (text, reviver) {
        const result = origJsonParse.apply(this, arguments);
        if (isEnabled() && result && typeof result === 'object' && typeof text === 'string') {
            if (text.includes('video_dash_manifest') || text.includes('dash_manifest')) {
                try {
                    pruneObjectManifests(result);
                } catch (e) {}
            }
        }
        return result;
    };

    // ============================================================================
    // Network Interception: window.fetch + window.XMLHttpRequest
    // ============================================================================

    // --- fetch interception ---
    if (typeof window.fetch === 'function') {
        const origFetch = window.fetch;
        window.fetch = function (input, init) {
            return origFetch.call(this, input, init).then(async function (response) {
                if (!isEnabled()) return response;

                try {
                    const url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
                    const contentType = (response.headers.get('content-type') || '').toLowerCase();

                    const isXml  = contentType.includes('xml') || url.includes('.mpd');
                    const isJson = contentType.includes('json') || url.includes('graphql') || url.includes('/api/v1/');

                    if (!isXml && !isJson) return response;

                    const text = await response.clone().text();

                    // If pure MPD XML
                    if (isXml && text.includes('<Representation')) {
                        const prunedXml = pruneManifestXml(text);
                        if (prunedXml !== text) {
                            const headersCopy = {};
                            response.headers.forEach((v, k) => { headersCopy[k] = v; });
                            return new Response(prunedXml, {
                                status: response.status,
                                statusText: response.statusText,
                                headers: headersCopy
                            });
                        }
                    }

                    // If JSON containing embedded video_dash_manifest
                    if (isJson && (text.includes('video_dash_manifest') || text.includes('dash_manifest'))) {
                        const parsed = origJsonParse(text);
                        pruneObjectManifests(parsed);
                        const newJson = JSON.stringify(parsed);
                        const headersCopy = {};
                        response.headers.forEach((v, k) => { headersCopy[k] = v; });
                        return new Response(newJson, {
                            status: response.status,
                            statusText: response.statusText,
                            headers: headersCopy
                        });
                    }
                } catch (e) {}

                return response;
            });
        };
    }

    // --- XMLHttpRequest interception ---
    if (typeof window.XMLHttpRequest !== 'undefined') {
        const OrigXHR = window.XMLHttpRequest;
        window.XMLHttpRequest = function PatchedXHR() {
            const xhr = new OrigXHR();
            let _url = '';
            let _pruned = null;

            const origOpen = xhr.open;
            xhr.open = function (method, url, ...rest) {
                _url = url || '';
                _pruned = null;
                return origOpen.apply(xhr, [method, url, ...rest]);
            };

            xhr.addEventListener('load', function () {
                if (!isEnabled()) return;
                try {
                    let text = '';
                    if (xhr.responseType === '' || xhr.responseType === 'text') {
                        text = xhr.responseText;
                    } else if (xhr.responseType === 'arraybuffer' && xhr.response) {
                        text = new TextDecoder().decode(new Uint8Array(xhr.response));
                    } else {
                        return;
                    }

                    if (!text) return;

                    if (text.includes('<Representation')) {
                        const pruned = pruneManifestXml(text);
                        if (pruned !== text) _pruned = pruned;
                    } else if (text.includes('video_dash_manifest') || text.includes('dash_manifest')) {
                        const parsed = origJsonParse(text);
                        pruneObjectManifests(parsed);
                        _pruned = JSON.stringify(parsed);
                    }
                } catch (e) {}
            });

            return new Proxy(xhr, {
                get(target, prop) {
                    if (_pruned !== null && (prop === 'responseText' || prop === 'response')) {
                        return _pruned;
                    }
                    const val = target[prop];
                    return typeof val === 'function' ? val.bind(target) : val;
                },
                set(target, prop, val) {
                    target[prop] = val;
                    return true;
                }
            });
        };
        if (OrigXHR.prototype) {
            window.XMLHttpRequest.prototype = OrigXHR.prototype;
        }
    }

    // ============================================================================
    // MediaSource VP9 & Hardware Acceleration Enabler (mirrors .mm lines 798-830)
    // ============================================================================
    if (typeof MediaSource !== 'undefined' && typeof MediaSource.isTypeSupported === 'function') {
        const origIsTypeSupported = MediaSource.isTypeSupported;
        MediaSource.isTypeSupported = function (type) {
            if (isEnabled() && type && (type.includes('vp09') || type.includes('vp9'))) {
                return true;
            }
            return origIsTypeSupported.call(this, type);
        };
    }

    // ============================================================================
    // Active On-Screen Reel Video Player Telemetry
    // (mirrors UpdateActivePlaybackTelemetryFromPlayer in .mm lines 276-393)
    // Strictly tracks ONLY the currently playing on-screen reel, ignoring offscreen/prefetch.
    // ============================================================================
    function isVideoOnScreen(video) {
        if (!video || !video.isConnected) return false;
        if (video.offsetWidth === 0 || video.offsetHeight === 0) return false;
        try {
            const style = window.getComputedStyle(video);
            if (style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) < 0.01) {
                return false;
            }
        } catch (e) {}

        const rect = video.getBoundingClientRect();
        const winH = window.innerHeight || document.documentElement.clientHeight;
        const winW = window.innerWidth || document.documentElement.clientWidth;

        // Viewport intersection
        const visibleH = Math.min(rect.bottom, winH) - Math.max(rect.top, 0);
        const visibleW = Math.min(rect.right, winW) - Math.max(rect.left, 0);

        return visibleH > 50 && visibleW > 50;
    }

    function updateTelemetryFromActiveVideo() {
        const videos = Array.from(document.querySelectorAll('video'));
        if (!videos.length) return;

        // Strict Guard: Find playing video visible in viewport
        let activeVideo = null;
        let maxVisibleArea = 0;

        const winH = window.innerHeight || document.documentElement.clientHeight;
        const winW = window.innerWidth || document.documentElement.clientWidth;

        for (const v of videos) {
            const isPlaying = !v.paused && !v.ended && v.readyState >= 2;
            if (!isPlaying || !isVideoOnScreen(v)) continue;

            const rect = v.getBoundingClientRect();
            const visibleArea = (Math.min(rect.bottom, winH) - Math.max(rect.top, 0)) *
                                (Math.min(rect.right, winW) - Math.max(rect.left, 0));

            if (visibleArea > maxVisibleArea) {
                maxVisibleArea = visibleArea;
                activeVideo = v;
            }
        }

        if (!activeVideo) return;

        const w = activeVideo.videoWidth;
        const h = activeVideo.videoHeight;
        if (w <= 0 || h <= 0) return;

        const minDim = Math.min(w, h);
        const maxDim = Math.max(w, h);
        const pixels = w * h;

        const is1440 = (minDim >= 1200 || maxDim >= 2200 || pixels >= 2800000);
        const is1080 = (!is1440 && (minDim >= 960 || maxDim >= 1700 || pixels >= 1600000));

        const quality = is1440 ? '1440p' : (is1080 ? '1080p' : `${minDim > 0 ? minDim : 1080}p`);
        const resolution = `${w}x${h}`;

        if (g_isActual1440p !== is1440 ||
            g_currentQuality !== quality ||
            g_currentResolution !== resolution) {
            g_isActual1440p     = is1440;
            g_currentQuality    = quality;
            g_currentResolution = resolution;
            notifyStateDidChange();
            updateBadge();
        }
    }

    // Attach passive listeners for video events
    if (typeof document.addEventListener === 'function') {
        document.addEventListener('playing', updateTelemetryFromActiveVideo, true);
        document.addEventListener('timeupdate', updateTelemetryFromActiveVideo, true);
        document.addEventListener('loadedmetadata', updateTelemetryFromActiveVideo, true);
    }
    if (typeof window.addEventListener === 'function') {
        window.addEventListener('scroll', updateTelemetryFromActiveVideo, { passive: true });
        window.addEventListener('resize', updateTelemetryFromActiveVideo, { passive: true });
    }

    // ============================================================================
    // Draggable Floating Mini HUD (mirrors InstagramReverbUI / HUD in .mm)
    // ============================================================================
    let hudEl = null;
    let isMinimized = false;

    function createHud() {
        if (hudEl || !document.body) return;

        hudEl = document.createElement('div');
        hudEl.id = 'ig-dash-1440p-hud';
        hudEl.title = 'InstagramDash1440p Engine HUD\n• Click mode to cycle (WiFi/Ethernet 1440p → Always 1440p → Disabled)\n• Drag to reposition';

        // Load saved position
        const savedPos = getStoredValue(HUD_POS_KEY, { top: 12, right: 14 });

        Object.assign(hudEl.style, {
            position:       'fixed',
            top:            `${savedPos.top || 12}px`,
            right:          savedPos.left !== undefined ? 'auto' : `${savedPos.right || 14}px`,
            left:           savedPos.left !== undefined ? `${savedPos.left}px` : 'auto',
            zIndex:         '2147483647',
            background:     'rgba(18, 18, 18, 0.88)',
            color:          '#f0f0f0',
            font:           '11px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace',
            padding:        '6px 10px',
            borderRadius:   '8px',
            boxShadow:      '0 4px 18px rgba(0, 0, 0, 0.55), 0 0 0 1px rgba(255, 255, 255, 0.12)',
            backdropFilter: 'blur(8px)',
            webkitBackdropFilter: 'blur(8px)',
            cursor:         'grab',
            userSelect:     'none',
            webkitUserSelect: 'none',
            transition:     'border-color 0.25s ease, opacity 0.2s',
            pointerEvents:  'auto',
            minWidth:       '140px',
        });

        // Dragging implementation
        let isDragging = false;
        let startX = 0, startY = 0;
        let initLeft = 0, initTop = 0;

        hudEl.addEventListener('mousedown', function (e) {
            if (e.target.closest('.hud-btn')) return; // buttons take click
            isDragging = true;
            hudEl.style.cursor = 'grabbing';
            const rect = hudEl.getBoundingClientRect();
            startX = e.clientX;
            startY = e.clientY;
            initLeft = rect.left;
            initTop = rect.top;

            function onMouseMove(moveEv) {
                if (!isDragging) return;
                const dx = moveEv.clientX - startX;
                const dy = moveEv.clientY - startY;

                const newLeft = Math.max(4, Math.min(window.innerWidth - hudEl.offsetWidth - 4, initLeft + dx));
                const newTop  = Math.max(4, Math.min(window.innerHeight - hudEl.offsetHeight - 4, initTop + dy));

                hudEl.style.left  = `${newLeft}px`;
                hudEl.style.top   = `${newTop}px`;
                hudEl.style.right = 'auto';
            }

            function onMouseUp() {
                if (!isDragging) return;
                isDragging = false;
                hudEl.style.cursor = 'grab';
                window.removeEventListener('mousemove', onMouseMove);
                window.removeEventListener('mouseup', onMouseUp);

                // Persist new position
                const rect = hudEl.getBoundingClientRect();
                setStoredValue(HUD_POS_KEY, { left: Math.round(rect.left), top: Math.round(rect.top) });
            }

            window.addEventListener('mousemove', onMouseMove);
            window.addEventListener('mouseup', onMouseUp);
        });

        document.body.appendChild(hudEl);
        updateBadge();
    }

    function updateBadge() {
        if (!hudEl) return;

        const mode = g_mode;
        const enabled = mode !== MODE_DISABLED;

        // Accent Colors:
        // Vibrant Neon Green (#1DB954 / #50fa7b) for 1440p
        // Warm Orange (#ffb86c) for 1080p fallback
        // Crimson Red (#ff5555) for Disabled
        const accentColor =
            !enabled          ? '#ff5555' :
            g_isActual1440p   ? '#1DB954' : '#ffb86c';

        hudEl.style.border = `1px solid ${accentColor}`;

        if (isMinimized) {
            hudEl.innerHTML = `
                <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;">
                    <span style="color:${accentColor};font-weight:bold;cursor:pointer;" class="hud-toggle-btn">
                        ● 1440p ${enabled ? g_currentQuality : 'OFF'}
                    </span>
                    <span class="hud-btn hud-expand-btn" style="cursor:pointer;opacity:0.6;font-size:12px;">+</span>
                </div>
            `;
        } else {
            const qualityDisplay = enabled
                ? `<span style="color:${accentColor};font-weight:bold;">▲ ${g_currentQuality}</span>`
                : `<span style="color:#ff5555;font-weight:bold;">OFF (IG Default)</span>`;

            const resDisplay = g_currentResolution || (g_isActual1440p ? '1440x2560' : '1080x1920');

            hudEl.innerHTML = `
                <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:3px;">
                    <span style="color:${accentColor};font-weight:800;letter-spacing:0.5px;">1440p DASH</span>
                    <div style="display:flex;gap:6px;align-items:center;">
                        <span class="hud-btn hud-cycle-btn" style="cursor:pointer;font-size:10px;background:rgba(255,255,255,0.12);padding:1px 5px;border-radius:4px;" title="Cycle Mode">⚙️</span>
                        <span class="hud-btn hud-min-btn" style="cursor:pointer;opacity:0.65;font-size:11px;" title="Minimize HUD">—</span>
                    </div>
                </div>
                <div style="display:flex;align-items:baseline;gap:6px;margin-bottom:2px;">
                    ${qualityDisplay}
                    <span style="opacity:0.6;font-size:10px;">${resDisplay}</span>
                </div>
                <div class="hud-btn hud-mode-btn" style="cursor:pointer;opacity:0.85;font-size:9.5px;color:#a0a0a0;border-top:1px solid rgba(255,255,255,0.08);padding-top:3px;margin-top:2px;" title="Click to cycle mode">
                    ${MODE_NAMES[mode]}
                </div>
            `;
        }

        // Event bindings for buttons
        const minBtn = hudEl.querySelector('.hud-min-btn');
        if (minBtn) {
            minBtn.onclick = (e) => {
                e.stopPropagation();
                isMinimized = true;
                updateBadge();
            };
        }

        const expandBtn = hudEl.querySelector('.hud-expand-btn');
        if (expandBtn) {
            expandBtn.onclick = (e) => {
                e.stopPropagation();
                isMinimized = false;
                updateBadge();
            };
        }

        const modeBtn = hudEl.querySelector('.hud-mode-btn');
        if (modeBtn) {
            modeBtn.onclick = (e) => {
                e.stopPropagation();
                cycleMode();
            };
        }

        const cycleBtn = hudEl.querySelector('.hud-cycle-btn');
        if (cycleBtn) {
            cycleBtn.onclick = (e) => {
                e.stopPropagation();
                cycleMode();
            };
        }

        const toggleBtn = hudEl.querySelector('.hud-toggle-btn');
        if (toggleBtn) {
            toggleBtn.onclick = (e) => {
                e.stopPropagation();
                cycleMode();
            };
        }
    }

    // Insert HUD when DOM is ready
    if (document.body) {
        createHud();
    } else if (typeof document.addEventListener === 'function') {
        document.addEventListener('DOMContentLoaded', createHud, { once: true });
    }

    // ============================================================================
    // Tampermonkey / Violentmonkey Menu Commands
    // ============================================================================
    if (typeof GM_registerMenuCommand === 'function') {
        GM_registerMenuCommand('🎬 Cycle 1440p Mode', cycleMode);
        GM_registerMenuCommand('🌐 WiFi/Ethernet 1440p (default)', () => setMode(MODE_WIFI_OR_ETHERNET));
        GM_registerMenuCommand('⚡ Always 1440p (Forced)',         () => setMode(MODE_ALWAYS_1440P));
        GM_registerMenuCommand('❌ Disabled (IG Default)',         () => setMode(MODE_DISABLED));
        GM_registerMenuCommand('👁️ Toggle HUD Visibility', () => {
            if (hudEl) {
                hudEl.style.display = hudEl.style.display === 'none' ? 'block' : 'none';
            }
        });
    }

    // ============================================================================
    // Public Console & Window API (mirrors C interface in InstagramDash1440p.h)
    // ============================================================================
    window.InstagramDash1440p = {
        // Master Control
        isEnabled:                  isEnabled,
        setEnabled:                 (en) => setMode(en ? MODE_WIFI_OR_ETHERNET : MODE_DISABLED),
        toggleEnabled:              () => { cycleMode(); return isEnabled(); },

        // Mode Management
        getMode:                    () => g_mode,
        setMode:                    setMode,
        cycleMode:                  cycleMode,
        getModeName:                () => MODE_NAMES[g_mode],

        // Real-Time Telemetry
        isActual1440p:              () => g_isActual1440p,
        getCurrentQuality:          () => g_currentQuality,
        getCurrentResolution:       () => g_currentResolution,
        getCurrentRepresentationId: () => g_currentRepId,

        // Low-level Pruning Interfaces
        pruneManifestXml:           pruneManifestXml,
        pruneObjectManifests:       pruneObjectManifests,

        // Mode Enum Constants
        MODE_WIFI_OR_ETHERNET,
        MODE_ALWAYS_1440P,
        MODE_DISABLED
    };

    console.log(`[InstagramDash1440p] Engine active. Mode: ${MODE_NAMES[g_mode]}`);
})();
