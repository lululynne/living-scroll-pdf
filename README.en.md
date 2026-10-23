<p align="center"><img src="assets/icon-1024.png" width="160" alt="Living Scroll PDF"></p>

# Living Scroll PDF 卷轴PDF

[中文](README.md) | **English**

*Scroll* means both a rolled-up scroll and the act of scrolling: Living Scroll PDF scrolls through a conversation and rolls it up into one long record. Its Chinese name, 卷轴PDF (juǎnzhóu), means "scroll PDF".

A scrolling screenshot tool for macOS: **pin a window, draw a region, and scroll — it captures as you go**, stitching everything into one long image saved as PDF + PNG, plus a record file with timestamps and SHA-256 hashes.

Why it exists: more and more work happens inside cloud agents (web-based assistants, cloud-desktop bots) that have no exportable raw log — just a chat page. When you want to keep the prompts, the generation process and the back-and-forth exactly as they happened, screenshotting screen by screen and stitching by hand is exhausting, and copy-paste loses images and layout. Living Scroll PDF captures the whole conversation as-is into a PDF, together with a record file — useful as proof of a creative process, for project handoff, or just for archiving. Many AI art and writing open calls ask for original creation records; this is one of the things it's good for.

## How it differs from ordinary "scrolling capture"

- **Captures the window, not the screen.** ScreenCaptureKit grabs only the selected window's own pixels: other windows on top of it, the capture frame and the control bar never end up in the image. Move the window and the red frame follows.
- **Just scroll by hand.** It samples a frame every 0.12 s, works out how many pixels the content moved, and appends only the newly revealed rows. Scrolling back, pausing, uneven speed — all fine. Or press "Auto-scroll to bottom" and let it scroll; it wraps up when nothing moves anymore.
- **Built for chat interfaces:**
  - fixed headers and fixed input boxes appear once, not repeated in every segment;
  - a blinking caret or a fading scrollbar is not mistaken for content;
  - at normal scrolling speed, floating "jump to latest" buttons and rounded window corners appear only at the very end, not at every seam (scroll almost a full screen in one go and a button may be left in the middle);
  - the region is split into vertical strips aligned independently, so local changes (scrollbar, sidebar avatars) don't break the match;
  - if you really scroll too fast to match, that frame is not taken and the status bar asks you to scroll back a little; scroll back and it joins up again by itself — never pasted in blind, never repeated. A capture that ends before joining up again is saved with "partial" in its name.
- **Archive-friendly output:** every capture saves a long PNG and a PDF. By default the PDF is one tall page, seamless like the PNG (it only continues on a new page, at a blank row, past the 200-inch PDF page limit); under PDF Pages in the menu you can switch to A4-proportioned pages for printing, again breaking on blank rows so text isn't cut in half; a `.json` with the same name records the app, window title, start/end time, frame count, dropped-frame count, whether it is partial, and the SHA-256 of the PNG and PDF.

A note on evidence: the SHA-256 shows a file is the same one produced at capture time only if you keep the hash somewhere else (send it to someone right away, put it in an email or another system). The `.json` sitting next to the files proves nothing by itself — edit the image, recompute the hash, and it matches again. Timestamps and window details are not signed either.

## Usage

1. Run `./build-app.sh` to get `dist/Living Scroll PDF.app`, drag it into Applications and open it. A scroll icon appears in the menu bar.
2. On first launch, enable Living Scroll PDF under **System Settings › Privacy & Security › Screen & System Audio Recording**, then reopen it.
3. Press **⌃⌥S** (or menu bar → Start Capture):
   - hover over the window you want — it gets a blue highlight — and click to select it;
   - drag a region inside the window (framing just the chat content works best); a plain click takes the whole window; Esc goes back / cancels;
   - once the red dashed frame appears, scroll that window normally;
   - click "Done" or press ⌃⌥S again. The PDF opens automatically; files go to `~/Desktop/Living Scroll PDF/` (`~/Desktop/卷轴PDF/` with the Chinese interface).
4. "Auto-scroll to bottom" additionally needs **Accessibility** permission. Before each scroll it checks that the window under the scroll point really is the target; if something covers it, auto-scroll pauses instead of scrolling the wrong window.

Currently only downward scrolling is supported (capture from the start of a conversation to its end). Requires macOS 14 or later. The interface is in English or Chinese, following your system language; switch it under Language in the menu.

## Development

```sh
swift build -c release
.build/release/LivingScrollPDF selftest   # pixel-exact self-test on a synthetic chat UI
./build-app.sh                     # package the .app (ad-hoc signed)
```

The self-test builds a frame sequence with a fixed header, an input box with a blinking caret, a moving scrollbar, a floating button and transparent corners, feeds it to the stitcher with irregular steps and scroll-backs, and compares the result against the source pixel by pixel.

In `Sources/LivingScrollPDF/`: `Stitcher.swift` is the stitching core, `CaptureSession.swift` the capture loop and control bar, `WindowPicker.swift` window picking and region selection, `Exporter.swift` PDF/PNG/record export.

## Acknowledgements

The "user scrolls manually + timed frame capture" interaction was inspired by [ScrollSnap](https://github.com/Brkgng/ScrollSnap) (MIT). The stitching algorithm, per-window capture and export are implemented independently.

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE). You may use, modify and share it for personal, research and other noncommercial purposes. **Commercial use is not permitted**, including selling this software or modified versions of it. Contact the author for a commercial license.

This is not an OSI-approved open-source license.

## Feedback and tips

Questions, ideas, or an app where the capture comes out wrong — get in touch:

- Email: [guanforlol@gmail.com](mailto:guanforlol@gmail.com)
- GitHub: [Issues](https://github.com/lululynne/living-scroll-pdf/issues)
- WeChat: scan the code on the right below to add me

Please include the app name and the kind of page, so we can reproduce the problem. The menu bar item Feedback also links straight here.

If Living Scroll PDF saved you an afternoon of stitching screenshots, scan to buy the author a milk tea, meow~

<p>
  <img src="assets/tip-wechat.jpg" width="220" alt="WeChat tip">
  &nbsp;&nbsp;
  <img src="assets/contact-wechat.jpg" width="220" alt="Add on WeChat">
</p>
