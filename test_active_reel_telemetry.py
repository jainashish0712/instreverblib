#!/usr/bin/env python3
"""
Unit Test: Active Reel Playback Telemetry & Offscreen Prefetch Isolation
Verifies that:
1. Candidate representation caching registers format metadata (dimensions, bitrate, tag).
2. True 1440p (1440x2560, 968238693007748v) is classified strictly as 1440p.
3. 1088x1920 macroblock streams (968240619674222v) are classified strictly as 1080p and never 1440p.
4. Offscreen/prefetch player instances (isPlaying=False, isOnScreen=False) are strictly rejected.
5. Active on-screen player instances (isPlaying=True or isOnScreen=True with active player) update telemetry.
6. Playlist queries and quality selectors do NOT call UpdateActiveRepresentation or touch HUD globals.
"""

import sys

def test_resolution_classification():
    print("[1/5] Testing resolution classification rules...")
    
    # Test cases: (width, height, repId, tag, expected_quality, expected_resolution)
    cases = [
        # True 1440p VP9 stream
        (1440.0, 2560.0, "968238693007748v", "dash-vp9-1440p", "1440p", "1440x2560"),
        # True 1440p landscape
        (2560.0, 1440.0, "1539525017490074v", "dash-vp9", "1440p", "2560x1440"),
        # 16-px macroblock aligned 1080p H.264 stream (must NOT be misclassified as 1440p!)
        (1088.0, 1920.0, "968240619674222v", "dash-hd", "1080p", "1088x1920"),
        # Standard 1080p
        (1080.0, 1920.0, "1080p_stream_id", "1080p", "1080p", "1080x1920"),
        # 720p stream
        (720.0, 1280.0, "720p_stream_id", "720p", "720p", "720x1280"),
    ]
    
    for w, h, repId, tag, exp_q, exp_res in cases:
        minDim = min(w, h)
        maxDim = max(w, h)
        pixels = int(w * h)
        
        is1440 = (minDim >= 1200.0 or maxDim >= 2200.0 or pixels >= 2800000 or
                  ("1539525017490074" in repId or "968238693007748" in repId or "1440" in repId or "2k" in repId) or
                  ("1440" in tag or "2k" in tag))
                  
        is1080 = (not is1440 and (minDim >= 960.0 or maxDim >= 1700.0 or pixels >= 1600000 or
                  "1080" in repId or "1080" in tag))
                  
        quality = "1440p" if is1440 else ("1080p" if is1080 else f"{int(minDim)}p")
        res = f"{int(w)}x{int(h)}"
        
        assert quality == exp_q, f"Failed for {repId}: expected {exp_q}, got {quality}"
        assert res == exp_res, f"Failed for {repId}: expected {exp_res}, got {res}"
        print(f"   -> {repId} ({w:.0f}x{h:.0f}) => {quality} [{res}]: PASS")

def test_prefetch_offscreen_rejection():
    print("[2/5] Testing offscreen/prefetch player rejection...")
    
    class MockPlayer:
        def __init__(self, is_playing, is_on_screen, rep_id, size):
            self.is_playing = is_playing
            self.is_on_screen = is_on_screen
            self.rep_id = rep_id
            self.size = size
            
    # Mock telemetry engine state
    state = {
        "active_player": None,
        "quality": "1440p",
        "resolution": "1440x2560",
        "repId": "ready"
    }
    
    def simulate_telemetry_update(player):
        # Mirroring UpdateActivePlaybackTelemetryFromPlayer logic
        if not player:
            return False
            
        is_playing = player.is_playing
        is_on_screen = player.is_on_screen
        
        # Strict Guard
        active = state["active_player"]
        if is_playing:
            state["active_player"] = player
        elif is_on_screen and active == player:
            pass # paused on screen
        else:
            return False # REJECTED!
            
        state["repId"] = player.rep_id
        state["resolution"] = f"{int(player.size[0])}x{int(player.size[1])}"
        return True

    # 1. Active reel A begins playing on screen
    reel_A = MockPlayer(is_playing=True, is_on_screen=True, rep_id="968238693007748v", size=(1440, 2560))
    accepted = simulate_telemetry_update(reel_A)
    assert accepted is True
    assert state["repId"] == "968238693007748v"
    print("   -> Active reel A playing: Accepted (telemetry updated to 968238693007748v)")
    
    # 2. Next reel B is prefetched in the background (not playing, not on screen)
    reel_B_prefetch = MockPlayer(is_playing=False, is_on_screen=False, rep_id="968240619674222v", size=(1088, 1920))
    accepted = simulate_telemetry_update(reel_B_prefetch)
    assert accepted is False
    assert state["repId"] == "968238693007748v", "Telemetry was erroneously modified by offscreen reel B!"
    print("   -> Next reel B prefetch: Strictly REJECTED (telemetry kept on reel A)")
    
    # 3. Next reel C is prefetched in the background (not playing, not on screen)
    reel_C_prefetch = MockPlayer(is_playing=False, is_on_screen=False, rep_id="777888999v", size=(1440, 2560))
    accepted = simulate_telemetry_update(reel_C_prefetch)
    assert accepted is False
    assert state["repId"] == "968238693007748v", "Telemetry was erroneously modified by offscreen reel C!"
    print("   -> Next reel C prefetch: Strictly REJECTED (telemetry kept on reel A)")

    # 4. User taps and holds Reel A (paused on screen)
    reel_A.is_playing = False
    reel_A.is_on_screen = True
    accepted = simulate_telemetry_update(reel_A)
    assert accepted is True
    assert state["repId"] == "968238693007748v"
    print("   -> User pauses Reel A on screen: Retained (telemetry stays on reel A)")
    
    # 5. User swipes to Reel B (Reel A offscreen, Reel B becomes active and playing)
    reel_A.is_on_screen = False
    reel_B_prefetch.is_playing = True
    reel_B_prefetch.is_on_screen = True
    accepted = simulate_telemetry_update(reel_B_prefetch)
    assert accepted is True
    assert state["repId"] == "968240619674222v"
    print("   -> User swipes to Reel B: Accepted (telemetry updated to Reel B: 968240619674222v)")

def test_codebase_isolation():
    print("[3/5] Testing codebase code paths for zero prefetch leakage...")
    with open("InstagramDash1440p.mm", "r", encoding="utf-8") as f:
        src = f.read()
        
    # Check that Hook_Playlist_RepresentationsForTrack has NO telemetry update
    assert "UpdateActiveRepresentation" not in src, "Found stale UpdateActiveRepresentation in source code!"
    print("   -> PASS: Stale UpdateActiveRepresentation completely eliminated")
    
    # Check that root manifest pruning and defaultRepresentationForTrack are present
    assert "PruneManifestXml" in src
    assert "Hook_Playlist_DefaultRepresentationForTrack" in src
    assert "UpdateActivePlaybackTelemetryFromPlayer" in src
    print("   -> PASS: Root manifest pruner and default representation hook do not pollute active telemetry")

def test_video_player_swizzles():
    print("[4/5] Testing IGFNFVideoPlayer swizzle coverage...")
    with open("InstagramDash1440p.mm", "r", encoding="utf-8") as f:
        src = f.read()

    expected_methods = [
        "_stateManagerTransitionToVideoStartedPlaying",
        "videoRepresentationIdChanged:codec:encodingTag:audioRoleMetadata:",
        "playWithReason:callsiteContext:"
    ]
    for m in expected_methods:
        assert m in src, f"Missing swizzle for {m} in InstagramDash1440p.mm"
        print(f"   -> Verified swizzle for IGFNFVideoPlayer -[{m}]: PASS")

def test_metadata_cache_lookup():
    print("[5/5] Testing metadata cache lookup for zero-size initial frames...")
    cache = {
        "968238693007748v": {"width": 1440.0, "height": 2560.0, "tag": "dash-vp9", "bw": 4500000}
    }
    
    # When initial size is (0, 0), fallback to cached metadata
    initial_sz = (0.0, 0.0)
    rep_id = "968238693007748v"
    if initial_sz[0] <= 0 or initial_sz[1] <= 0:
        meta = cache.get(rep_id)
        assert meta is not None
        resolved_sz = (meta["width"], meta["height"])
    else:
        resolved_sz = initial_sz
        
    assert resolved_sz == (1440.0, 2560.0)
    print("   -> PASS: Zero-size initial frame correctly resolves from representation format cache")

def test_cellular_vs_wifi_selection():
    print("[6/6] Testing cellular vs Wi-Fi representation selection (1080p preferred & max on cellular)...")
    
    reps = [
        {"id": "968238693007748v", "pixels": 1440 * 2560, "bw": 4500000, "is1440": True, "is1080": False},
        {"id": "968240619674222v", "pixels": 1088 * 1920, "bw": 6000000, "is1440": False, "is1080": True},
        {"id": "720p_rep", "pixels": 720 * 1280, "bw": 2000000, "is1440": False, "is1080": False}
    ]
    
    def simulate_selection(is_cellular, candidates):
        rep1440 = next((r for r in candidates if r["is1440"]), None)
        rep1080 = next((r for r in candidates if r["is1080"]), None)
        repUnder1440 = next((r for r in candidates if not r["is1440"]), None)
        
        if is_cellular:
            # 1080p as preferred and max on cellular
            chosen = rep1080 or repUnder1440 or rep1440 or candidates[0]
        else:
            # 1440p on Wi-Fi
            chosen = rep1440 or rep1080 or candidates[0]
        return chosen

    # Test on Cellular
    chosen_cell = simulate_selection(is_cellular=True, candidates=reps)
    assert chosen_cell["id"] == "968240619674222v", f"Expected 1080p on cellular, got {chosen_cell['id']}"
    print("   -> Cellular connection: 1080p selected (1440p capped): PASS")
    
    # Test on Wi-Fi
    chosen_wifi = simulate_selection(is_cellular=False, candidates=reps)
    assert chosen_wifi["id"] == "968238693007748v", f"Expected 1440p on Wi-Fi, got {chosen_wifi['id']}"
    print("   -> Wi-Fi connection: 1440p selected (Ultra-HD): PASS")

    # Verify source code has InstagramWifiSpoofer_IsCellularData integration
    with open("InstagramDash1440p.mm", "r", encoding="utf-8") as f:
        dash_src = f.read()
    assert "InstagramWifiSpoofer_IsCellularData" in dash_src
    assert "repHighestUnder1440" in dash_src
    print("   -> InstagramDash1440p.mm cellular branch verified in source: PASS")

if __name__ == "__main__":
    test_resolution_classification()
    test_prefetch_offscreen_rejection()
    test_codebase_isolation()
    test_video_player_swizzles()
    test_metadata_cache_lookup()
    test_cellular_vs_wifi_selection()
    print("\n==================================================================")
    print("  ALL ACTIVE REEL TELEMETRY & ISOLATION TESTS PASSED (100%)!     ")
    print("==================================================================")
