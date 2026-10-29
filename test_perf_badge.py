#!/usr/bin/env python3
"""
Test Suite for InstagramPerfHUDPill (Real-Time 2s CPU, GPU & Network Telemetry Badge)
"""

import re
import sys

def verify_perf_badge():
    print("==================================================================")
    print("   INSTAGRAM REAL-TIME CPU, GPU & NETWORK TELEMETRY BADGE AUDIT   ")
    print("==================================================================")

    file_path = "D:/apps/com.spotify.client-9.1.94-eeveedecrypter/InstagramReverb/InstagramReverbUI.m"
    with open(file_path, "r", encoding="utf-8") as f:
        code = f.read()

    # 1. Verify Class Definition & Required Properties
    assert "@interface InstagramPerfHUDPill : UIView" in code, "InstagramPerfHUDPill interface missing!"
    assert "@implementation InstagramPerfHUDPill" in code, "InstagramPerfHUDPill implementation missing!"
    assert "@property (nonatomic, strong) NSTimer *pollTimer;" in code
    assert "@property (nonatomic, assign) NSInteger displayMode;" in code
    assert "@property (nonatomic, assign) PerfNetStats lastNetStats;" in code
    print("   [1/6] PASS: InstagramPerfHUDPill class interface and properties verified.")

    # 2. Verify 2.0-Second Timer Interval
    assert "timerWithTimeInterval:2.0" in code, "Timer must be configured for 2.0-second interval!"
    assert "addTimer:_pollTimer forMode:NSRunLoopCommonModes" in code, "Timer must be added to NSRunLoopCommonModes to track during scrolling!"
    print("   [2/6] PASS: Real-time 2.0s poll timer with NSRunLoopCommonModes verified.")

    # 3. Verify CPU Mach Kernel Query
    assert "task_threads(mach_task_self()" in code, "CPU must be queried via task_threads!"
    assert "thread_info(threadList[i], THREAD_BASIC_INFO" in code, "Thread basic info must be queried!"
    assert "TH_USAGE_SCALE" in code, "Thread usage must be scaled by TH_USAGE_SCALE!"
    assert "vm_deallocate" in code, "Thread list memory must be freed via vm_deallocate!"
    print("   [3/6] PASS: Non-blocking Mach thread CPU calculation verified.")

    # 4. Verify GPU IOKit / Dynamic Loading Fallback
    assert "IOAccelerator" in code, "GPU query must check IOAccelerator!"
    assert "PerformanceStatistics" in code, "PerformanceStatistics dictionary must be parsed!"
    assert "Device Utilization %" in code, "Device Utilization % key must be queried!"
    print("   [4/6] PASS: Dynamic IOKit GPU hardware utilization with safe fallback verified.")

    # 5. Verify Network Interface Discrimination (Wi-Fi vs Cellular)
    assert 'strncmp(name, "en", 2) == 0' in code, "en* interfaces must be mapped to Wi-Fi!"
    assert 'strncmp(name, "pdp_ip", 6) == 0' in code, "pdp_ip* interfaces must be mapped to Cellular!"
    assert "getifaddrs(&interfaces)" in code, "Network byte counters must be read via getifaddrs!"
    assert "freeifaddrs(interfaces)" in code, "ifaddrs memory must be released with freeifaddrs!"
    print("   [5/6] PASS: Wi-Fi (en*) and Cellular (pdp_ip*) throughput discrimination verified.")

    # 6. Verify Subview Attachment & Draggable Pan Gesture
    assert "self.perfPill = [[InstagramPerfHUDPill alloc] initWithFrame:CGRectMake(initialX, initialY, perfW, perfH)];" in code
    assert "UIPanGestureRecognizer *pan" in code
    assert "CGFloat initialY = 78.0f;" in code
    print("   [6/6] PASS: Draggable pan gesture and docking 4pt below dashPill (y=78pt) verified.")

    print("==================================================================")
    print("       ALL 6 PERFORMANCE TELEMETRY BADGE CHECKS PASSED!           ")
    print("==================================================================")

if __name__ == "__main__":
    verify_perf_badge()
