# InstagramDash1440p

Ultra High-Definition (1440p / 2K) VP9 DASH Video Streaming & Quality Forcing Engine for Instagram on iOS (LiveContainer, TrollStore & Sideloading compatible).

## Features
- **Active 1440p Video Playback**: Forces 1440p (2560x1440 / 2K) DASH video streams on supported Reels and Stories using root-level manifest pruning and adaptive bitrate override.
- **Embedded VP9 Decoder**: Unlocks hardware/multithreaded VP9 decoding within Instagram's FNF (Facebook/Network/Framework) player stack.
- **Cellular-to-Wi-Fi Spoofing**: Transparent 3-tier network spoofer that prevents Instagram from downscaling videos on cellular connections.
- **Interactive DASH Quality Pill**: Draggable floating pill showing active stream resolution (`1440p` / `1080p` / `OFF`) and active representation ID, with tap-to-cycle mode toggling.
- **Hardware Performance Telemetry**: Companion real-time badge displaying CPU%, GPU%, RAM, and network throughput.

## 3-Mode Architecture
1. **Wi-Fi Only (Mode 1 - Default)**: Streams in 1440p on Wi-Fi; automatically caps to 1080p on cellular data.
2. **Always 1440p (Mode 2)**: Forces maximum 1440p streaming unconditionally across both Wi-Fi and Cellular.
3. **IG Default (Mode 3)**: Leaves DASH manifests unmodified for standard Instagram behavior.

## Compilation
```bash
./build.sh
```
