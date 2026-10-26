#!/usr/bin/env python3
"""
Test Touch Passthrough and Overlay Window Hit Testing for InstagramReverb
Validates that:
1. No full-screen dimBackgroundView is added or present in the overlay hierarchy.
2. InstagramReverbOverlayWindow hitTest:withEvent: passes touches outside the HUD/Button directly to Instagram (returns nil).
3. The HUD and Floating Button capture their own touches properly.
"""

import re

def verify_touch_passthrough():
    print("==================================================================")
    print("    INSTAGRAM TOUCH PASSTHROUGH & OVERLAY HIT TEST VERIFICATION   ")
    print("==================================================================")

    file_path = "D:/apps/com.spotify.client-9.1.94-eeveedecrypter/InstagramReverb/InstagramReverbUI.m"
    with open(file_path, "r", encoding="utf-8") as f:
        code = f.read()

    # 1. Verify dimBackgroundView is completely eliminated from HUD display and properties
    assert "self.dimBackgroundView" not in code, "self.dimBackgroundView must NOT exist in InstagramReverbUI.m!"
    assert "@property (nonatomic, strong) UIView *dimBackgroundView" not in code, "dimBackgroundView property must NOT exist!"
    assert "[container addSubview:self.dimBackgroundView]" not in code, "dimBackgroundView must not be added to container!"
    print("   [1/3] PASS: Full-screen dimBackgroundView is completely eliminated.")

    # 2. Verify InstagramReverbOverlayWindow hitTest:withEvent: logic
    hit_test_match = re.search(r'- \(UIView \*\)hitTest:\(CGPoint\)point withEvent:\(UIEvent \*\)event\s*\{(.*?)\}', code, re.DOTALL)
    assert hit_test_match, "hitTest:withEvent: must be present in InstagramReverbUI.m"
    hit_test_body = hit_test_match.group(1)

    assert "UIView *hitView = [super hitTest:point withEvent:event];" in hit_test_body
    assert "hitView == self || hitView == self.rootViewController.view" in hit_test_body
    assert "return nil;" in hit_test_body
    print("   [2/3] PASS: InstagramReverbOverlayWindow returns nil for touches outside HUD/Button, passing them to Instagram.")

    # 3. Verify showHUD adds ONLY self.hudView to container
    show_hud_match = re.search(r'- \(void\)showHUD\s*\{(.*?)\n- \(void\)hideHUD', code, re.DOTALL)
    assert show_hud_match, "showHUD method must be found"
    show_hud_body = show_hud_match.group(1)

    assert "[container addSubview:self.hudView];" in show_hud_body
    assert "addSubview" in show_hud_body
    # Ensure there is only 1 addSubview in show_hud_body
    assert show_hud_body.count("addSubview") == 1, f"Expected exactly 1 addSubview in showHUD, found {show_hud_body.count('addSubview')}"
    print("   [3/3] PASS: showHUD adds only self.hudView; Instagram behind popup is 100% interactive.")

    print("==================================================================")
    print("         ALL TOUCH PASSTHROUGH AUDIT CHECKS PASSED!               ")
    print("==================================================================")

if __name__ == "__main__":
    verify_touch_passthrough()
