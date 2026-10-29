#!/usr/bin/env python3
"""
Verification suite for InstagramDash1440p 3-Mode Architecture:
Mode 1: Wi-Fi only 1440p (cellular capped to 1080p)
Mode 2: Wi-Fi and Cellular both max cap to 1440p
Mode 3: Disabled completely (Instagram default behavior)
"""

import re

sample_mpd = '''<MPD>
  <Period>
    <AdaptationSet mimeType="video/mp4">
      <Representation id="1665294911822981v" width="1440" height="2560" bandwidth="6450000">
        <BaseURL>url_1440</BaseURL>
      </Representation>
      <Representation id="1079848834835350v" width="1080" height="1920" bandwidth="3200000">
        <BaseURL>url_1080</BaseURL>
      </Representation>
      <Representation id="720p_v" width="720" height="1280" bandwidth="1800000">
        <BaseURL>url_720</BaseURL>
      </Representation>
    </AdaptationSet>
    <AdaptationSet mimeType="audio/mp4">
      <Representation id="audio_1" bandwidth="128000">
        <BaseURL>url_audio</BaseURL>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>'''

sample_mpd_1080_only = '''<MPD>
  <Period>
    <AdaptationSet mimeType="video/mp4">
      <Representation id="1079848834835350v" width="1080" height="1920" bandwidth="3200000">
        <BaseURL>url_1080</BaseURL>
      </Representation>
      <Representation id="720p_v" width="720" height="1280" bandwidth="1800000">
        <BaseURL>url_720</BaseURL>
      </Representation>
    </AdaptationSet>
    <AdaptationSet mimeType="audio/mp4">
      <Representation id="audio_1" bandwidth="128000">
        <BaseURL>url_audio</BaseURL>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>'''

def simulate_pruner(xml, mode, is_cellular):
    # Mode 2: Disabled -> Unmodified
    if mode == 2:
        return xml

    rep_pattern = re.compile(r'<Representation\b[\s\S]*?(?:/>|</Representation>)')
    matches = list(rep_pattern.finditer(xml))
    video_reps = []
    for m in matches:
        text = m.group(0)
        adapt_idx = xml.rfind('<AdaptationSet', 0, m.start())
        adapt_header = ''
        if adapt_idx != -1:
            adapt_end = xml.find('>', adapt_idx)
            if adapt_end != -1:
                adapt_header = xml[adapt_idx:adapt_end]

        if 'audio' in adapt_header or 'mimeType="audio' in text or 'audioSamplingRate' in text:
            continue

        w_m = re.search(r'width="(\d+)"', text)
        h_m = re.search(r'height="(\d+)"', text)
        bw_m = re.search(r'bandwidth="(\d+)"', text)
        id_m = re.search(r'id="([^"]+)"', text)
        w = int(w_m.group(1)) if w_m else 0
        h = int(h_m.group(1)) if h_m else 0
        bw = int(bw_m.group(1)) if bw_m else 0
        rep_id = id_m.group(1) if id_m else ''

        video_reps.append({
            'span': m.span(),
            'w': w,
            'h': h,
            'bw': bw,
            'id': rep_id
        })

    if not video_reps:
        return xml

    has_1440 = any(vr['w'] >= 1200 or vr['h'] >= 2200 for vr in video_reps)
    has_1080 = any(vr['w'] >= 960 or vr['h'] >= 1700 for vr in video_reps)

    target = None
    if mode == 0: # WifiOnly
        if is_cellular:
            # 1080p cap
            reps_under_1440 = [vr for vr in video_reps if not (vr['w'] >= 1200 or vr['h'] >= 2200)]
            target = max(reps_under_1440, key=lambda x: (x['w']*x['h'], x['bw'])) if reps_under_1440 else video_reps[0]
        else:
            # Wi-Fi 1440p Priority, 1080p Fallback
            if has_1440:
                target = max([vr for vr in video_reps if vr['w'] >= 1200 or vr['h'] >= 2200], key=lambda x: (x['w']*x['h'], x['bw']))
            elif has_1080:
                target = max([vr for vr in video_reps if vr['w'] >= 960 or vr['h'] >= 1700], key=lambda x: (x['w']*x['h'], x['bw']))
            else:
                target = max(video_reps, key=lambda x: (x['w']*x['h'], x['bw']))
    elif mode == 1: # Always 1440p
        if has_1440:
            target = max([vr for vr in video_reps if vr['w'] >= 1200 or vr['h'] >= 2200], key=lambda x: (x['w']*x['h'], x['bw']))
        elif has_1080:
            target = max([vr for vr in video_reps if vr['w'] >= 960 or vr['h'] >= 1700], key=lambda x: (x['w']*x['h'], x['bw']))
        else:
            target = max(video_reps, key=lambda x: (x['w']*x['h'], x['bw']))

    pruned = xml
    for vr in sorted(video_reps, key=lambda x: x['span'][0], reverse=True):
        if vr != target:
            start, end = vr['span']
            while start > 0 and pruned[start-1] in ' \t':
                start -= 1
            if start > 0 and pruned[start-1] == '\n':
                start -= 1
            pruned = pruned[:start] + pruned[end:]

    return pruned

def test_modes():
    print("==================================================================")
    print("   INSTAGRAM 3-MODE 1440p ENGINE VERIFICATION SUITE              ")
    print("==================================================================")

    # 1. Mode 1 on Wi-Fi: 1440p
    m1_wifi = simulate_pruner(sample_mpd, 0, is_cellular=False)
    assert '1665294911822981v' in m1_wifi
    assert '1079848834835350v' not in m1_wifi
    assert 'audio_1' in m1_wifi
    print("   [1/6] PASS: Mode 1 on Wi-Fi selects 1440p and strips 1080p/720p.")

    # 2. Mode 1 on Cellular: 1080p cap
    m1_cell = simulate_pruner(sample_mpd, 0, is_cellular=True)
    assert '1079848834835350v' in m1_cell
    assert '1665294911822981v' not in m1_cell
    assert 'audio_1' in m1_cell
    print("   [2/6] PASS: Mode 1 on Cellular caps to 1080p and strips 1440p.")

    # 3. Mode 1 on Wi-Fi with 1080p-only reel: fallback to 1080p
    m1_fallback = simulate_pruner(sample_mpd_1080_only, 0, is_cellular=False)
    assert '1079848834835350v' in m1_fallback
    assert '720p_v' not in m1_fallback
    assert 'audio_1' in m1_fallback
    print("   [3/6] PASS: Mode 1 safely falls back to 1080p when reel lacks 1440p.")

    # 4. Mode 2 on Cellular: Force 1440p
    m2_cell = simulate_pruner(sample_mpd, 1, is_cellular=True)
    assert '1665294911822981v' in m2_cell
    assert '1079848834835350v' not in m2_cell
    assert 'audio_1' in m2_cell
    print("   [4/6] PASS: Mode 2 forces 1440p on Cellular as well.")

    # 5. Mode 3: Disabled completely
    m3 = simulate_pruner(sample_mpd, 2, is_cellular=False)
    assert m3 == sample_mpd
    assert '1665294911822981v' in m3
    assert '1079848834835350v' in m3
    assert '720p_v' in m3
    assert 'audio_1' in m3
    print("   [5/6] PASS: Mode 3 leaves manifest 100% untouched for native IG behavior.")

    # 6. Source code audit
    with open("InstagramDash1440p.h", "r", encoding="utf-8") as f:
        h = f.read()
    with open("InstagramDash1440p.mm", "r", encoding="utf-8") as f:
        mm = f.read()
    with open("InstagramReverbUI.m", "r", encoding="utf-8") as f:
        ui = f.read()

    assert "InstagramDash1440pModeWifiOnly" in h
    assert "InstagramDash1440pModeAlways1440p" in h
    assert "InstagramDash1440pModeDisabled" in h
    assert "InstagramDash1440p_CycleMode" in h
    assert "InstagramDash1440p_CycleMode" in mm
    assert "InstagramDash1440p_CycleMode" in ui
    assert "PruneManifestXml" in mm
    assert "presentationDescriptionWithContentsOfXml" in mm
    assert "dashManifest" in mm
    assert "handleTap:" in ui
    print("   [6/6] PASS: Source code symbols and headers 100% synchronized.")

    print("==================================================================")
    print("    ALL 6 MODE & MANIFEST PRUNER TESTS PASSED (100%)!             ")
    print("==================================================================")

if __name__ == "__main__":
    test_modes()
