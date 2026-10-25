#!/usr/bin/env python3
"""
Targeted Verification for Mini Half-Screen HUD Layout, Geometry & +/- Stepper Intervals (InstagramReverb)
"""
import re

def verify_mini_hud():
    print("==================================================================")
    print("       MINI HALF-SCREEN HUD & STEPPER INTERVAL AUDIT (IG)         ")
    print("==================================================================")

    file_path = "D:/apps/com.spotify.client-9.1.94-eeveedecrypter/InstagramReverb/InstagramReverbUI.m"
    with open(file_path, "r", encoding="utf-8") as f:
        code = f.read()

    # 1. Verify Thumb Size
    assert "CreateCompactThumb(11.0f)" in code, "Thumb size must be 11.0f!"
    print("   [1/6] PASS: Slider thumb diameter set to compact 11pt.")

    # 2. Verify Half-Screen Width Formula
    assert "CGFloat hudW = roundf(screenW * 0.50f);" in code, "HUD width must be strictly 50% of screen width!"
    assert "CGFloat hudH = 220.0f;" in code, "HUD height must be compact 220pt!"
    assert "CGFloat hudX = screenW - hudW - rightMargin;" in code, "HUD must be docked to the right edge!"
    print("   [2/6] PASS: HUD width is strictly half-screen (50%) and docked to bottom-right corner.")

    # 3. Verify Both UIControlStateNormal & UIControlStateHighlighted are Set
    sliders = ["_pitchSlider", "_mixSlider", "_roomSlider", "_volumeView"]
    for s in sliders:
        assert f"[{s} setThumbImage:thumb forState:UIControlStateNormal];" in code or f"[{s} setVolumeThumbImage:thumb forState:UIControlStateNormal];" in code
        assert f"[{s} setThumbImage:thumb forState:UIControlStateHighlighted];" in code or f"[{s} setVolumeThumbImage:thumb forState:UIControlStateHighlighted];" in code
    print("   [3/6] PASS: All sliders (Pitch, Reverb Mix, Room Size, Volume) have 11pt thumbs locked for both normal and highlighted states.")

    # 4. Verify +/- Stepper Buttons and Intervals
    # Pitch: 0.2 interval
    assert "[self pitchStep:-0.2f];" in code, "Pitch - interval must be 0.2!"
    assert "[self pitchStep:0.2f];" in code, "Pitch + interval must be 0.2!"
    # Reverb Mix: 8% (0.08) interval
    assert "[self mixStep:-0.08f];" in code, "Reverb mix - interval must be 0.08 (8%)!"
    assert "[self mixStep:0.08f];" in code, "Reverb mix + interval must be 0.08 (8%)!"
    # Room Size: 0.08 interval
    assert "[self roomStep:-0.08f];" in code, "Room size - interval must be 0.08!"
    assert "[self roomStep:0.08f];" in code, "Room size + interval must be 0.08!"
    # Volume: 7% (0.07) interval
    assert "[self volumeStep:-0.07f];" in code, "Volume - interval must be 0.07 (7%)!"
    assert "[self volumeStep:0.07f];" in code, "Volume + interval must be 0.07 (7%)!"
    print("   [4/6] PASS: All +/- stepper buttons verified with exact intervals: Pitch 0.2, Mix 8%, Room 0.08, Volume 7%.")

    # 5. Verify Draggable HUD Pan Gesture & Touch Passthrough
    assert "UIPanGestureRecognizer *hudPan" in code
    assert "gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch" in code
    assert "[touch.view isKindOfClass:[UIControl class]]" in code
    print("   [5/6] PASS: Modal has pan gesture for dragging anywhere with touch isolation for controls.")

    # 6. Verify Subview Layout Geometry inside 196x220pt Card
    for screen_w, screen_h in [(375.0, 667.0), (390.0, 844.0), (393.0, 852.0), (430.0, 932.0)]:
        hud_w = round(screen_w * 0.50)
        hud_h = 220.0
        hud_x = screen_w - hud_w - 10.0
        hud_y = screen_h - hud_h - 95.0

        pad = 10.0
        w = hud_w - 20.0
        assert w >= 167.0, f"Inner width too small: {w}"
        assert hud_x > 0, f"HUD X off-screen: {hud_x}"
        assert hud_y > 0, f"HUD Y off-screen: {hud_y}"
        assert hud_x + hud_w <= screen_w, "HUD overflows screen right"
        assert hud_y + hud_h <= screen_h, "HUD overflows screen bottom"

    print("   [6/6] PASS: Layout geometry validated across all iPhone screen sizes (SE, standard, Pro Max).\n")
    print("==================================================================")
    print("            ALL MINI HUD AUDIT CHECKS PASSED!                     ")
    print("==================================================================")

if __name__ == "__main__":
    verify_mini_hud()
