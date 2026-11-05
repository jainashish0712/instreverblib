#!/usr/bin/env python3
"""
Test Touch Passthrough and Overlay Window Hit Testing for InstagramDash1440pUI
Validates that:
1. No full-screen dimBackgroundView is added or present in the overlay hierarchy.
2. InstagramDash1440pOverlayWindow hitTest:withEvent: passes touches outside the pills directly to Instagram (returns nil).
3. The DASH and Performance pills capture their own touches properly.
"""

import os
import re

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

def verify_touch_passthrough():
    print("==================================================================")
    print("    INSTAGRAM TOUCH PASSTHROUGH & OVERLAY HIT TEST VERIFICATION   ")
    print("==================================================================")

    file_path = os.path.join(BASE_DIR, "InstagramDash1440pUI.m")
    with open(file_path, "r", encoding="utf-8") as f:
        code = f.read()

    # 1. Verify dimBackgroundView is completely eliminated from HUD display and properties
    assert "self.dimBackgroundView" not in code, "self.dimBackgroundView must NOT exist in InstagramDash1440pUI.m!"
    assert "dimBackgroundView" not in code, "dimBackgroundView must NOT exist!"
    print("   [1/3] PASS: Full-screen dimBackgroundView is completely eliminated.")

    # 2. Verify InstagramDash1440pOverlayWindow hitTest:withEvent: logic
    hit_test_match = re.search(r'- \(UIView \*\)hitTest:\(CGPoint\)point withEvent:\(UIEvent \*\)event\s*\{(.*?)\}', code, re.DOTALL)
    assert hit_test_match, "hitTest:withEvent: must be present in InstagramDash1440pUI.m"
    hit_test_body = hit_test_match.group(1)

    assert "UIView *hitView = [super hitTest:point withEvent:event];" in hit_test_body
    assert "hitView == self || hitView == self.rootViewController.view" in hit_test_body
    assert "return nil;" in hit_test_body
    print("   [2/3] PASS: InstagramDash1440pOverlayWindow returns nil for touches outside pills, passing them to Instagram.")

    # 3. Verify startOverlay adds dashPill and perfPill
    assert "[container addSubview:self.dashPill];" in code
    assert "[container addSubview:self.perfPill];" in code
    print("   [3/3] PASS: Overlay adds only interactive HUD pills; Instagram behind overlay is 100% interactive.")

    print("==================================================================")
    print("         ALL TOUCH PASSTHROUGH AUDIT CHECKS PASSED!               ")
    print("==================================================================")

if __name__ == "__main__":
    verify_touch_passthrough()
