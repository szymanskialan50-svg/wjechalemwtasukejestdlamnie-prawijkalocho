# HD Camera iPhone - iPhone as a USB webcam

iPhone app streams camera video over the USB cable; the Windows app turns it into a virtual webcam
called **HD Camera iPhone**.

## Build
Push to GitHub -> Actions -> *Build USC-CAM* -> download `USC-CAM-Package`
(contains `USC-CAM.ipa`, `USC-CAM.exe`, `driver/` and `Install-HD-Camera.bat`).

## Install / use
1. iPhone: sideload `USC-CAM.ipa` (Sideloadly / AltStore - unsigned). Open the app, allow the camera.
2. PC (one time): install **iTunes** or **Apple Devices** (USB driver).
3. PC (one time): run `Install-HD-Camera.bat` (admin) -> the webcam appears as **HD Camera iPhone**.
   (Without it the app falls back to OBS Studio's *OBS Virtual Camera*, which needs OBS installed.)
4. Plug in the iPhone, tap *Trust*, keep USC-CAM open, run `USC-CAM.exe`.
5. In Zoom / Discord / Teams etc. pick **HD Camera iPhone**.

## On the phone
The app shows the live camera image. Pick **Resolution** (720p / 1080p / 4K) and **Quality**
(Low / Medium / High) right on the screen - lower values = less lag. Default: 1080p, Medium.
On the PC you can additionally downscale the output.

Note: iOS pauses the camera when the app is in the background - keep it open (use *Dim screen* to save battery).

## v3 changes
- Virtual webcam is called **HD Camera iPhone** only (OBS fallback removed). The .exe installs the driver itself on first start (one Windows prompt).
- When the phone is not connected, the virtual camera shows a **"Waiting for camera"** screen with the app icon
  instead of an error / black picture.
- Less lag in the .exe: receive, decode and send now run in 3 separate threads, always keeping only the newest frame.
  Default output is 1920x1080 (stable size).
- Fixed the GitHub workflow (Xcode version, path conversion on Windows, driver DLL copy).

## v5 changes (lag + 120 fps)
- iPhone streams up to **120 fps** (picker: 120 / 60 / 30; unsupported rates are hidden, the app falls back to the best the camera can do). 1080p is the best size for 120 fps on most iPhones.
- Camera format is chosen explicitly (widest field of view, 8-bit), **video stabilization and video HDR are off** (both buffer frames = lag).
- **Flow control**: the PC acknowledges every frame, the iPhone keeps max 3 frames in flight. No more old frames piling up in the USB cable. The newest frame always wins.
- PC: preallocated receive buffers, preview limited to 15 fps, 1 ms Windows timer, higher process priority, virtual cam announces 120 fps.
- JPEG quality values re-tuned (Low 0.45 / Medium 0.6 / High 0.8) so 1080p120 fits through USB 2.0.

## v6 changes (H.264 + Wi-Fi)
- **H.264 instead of per-frame JPEG** (default). The iPhone's hardware encoder (low-latency, no B-frames) sends ~25-60 Mbit/s for 1080p120 instead of ~300 Mbit/s of JPEG: much sharper picture, no USB/Wi-Fi saturation, PC decodes in ~2 ms. MJPEG stays available in the app (CODEC picker).
- Quality = bitrate: Low ~25, Medium ~40, High ~62 Mbit/s at 1080p120 (scales with resolution and fps).
- **Wi-Fi mode**: the app shows the iPhone's IP. In USC-CAM.exe choose *Connection: Wi-Fi* and type the IP. Both devices on the same network (5 GHz, no guest network). Allow "Local Network" on the iPhone when asked.
- The PC acknowledges a frame only after decoding it, so the iPhone never sends faster than the PC can show.
- Window shows codec, Mbit/s and decode time. If "decode" is above ~7 ms at 120 fps the PC is the bottleneck - lower fps or output size.

## v7 changes (lag hunting on the PC side)
- Virtual camera is fed at a **fixed rhythm** (selectable 120 / 60 / 30 fps) with the newest decoded frame, instead of in bursts. Set the SAME fps in your app (OBS: Video Capture Device -> Resolution/FPS Type "Custom", FPS = same value; Zoom/Discord/Teams use 30).
- OBS tip: in the Video Capture Device properties turn **Use Buffering** off, and make the OBS Base/Output resolution match the stream (1920x1080) so the driver does not rescale every frame.
- Window shows 3 lines of diagnostics: in/out fps, decode ms, **vcam send ms**, **frame age ms**. A per-second log is written to `%TEMP%\usc-cam.log`.
- **Live window** (dropdown): the full picture in its own window that bypasses the virtual camera. In OBS use *Window Capture*. If this is smooth and the virtual camera is not, the driver/app chain is the cause.
