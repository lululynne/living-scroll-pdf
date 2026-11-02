# 0.2.1

手动滚动仍免费，没有水印，打赏入口不变。自动滚动这一版关着。

## 修复

近重复的行（正文按固定行高重复，只有一列窄标记不同）在证明不了两帧真的重叠时，不再接上一个较小的位移。对不上就停在最后一次能证明连续的画面。

这时点完成，文件名带「未完成」。同名 JSON 写 `isPartial`、`partialReason` 和 `gaps`。`gaps.afterRow` 是当前图像高度，缺的是结尾之后还没接上的部分，不会在图中间补像素。

导出版本读包里的 `CFBundleShortVersionString`。命令行构建没有 app 包，记为 `dev`，不再写成 `0.1.0`。打包脚本里的版本是 `0.2.1`，build `3`。

往回滚、停下、速度不匀都可以，只要新的一帧还能和上一帧对上真实重叠。滚过了重叠范围，就得滚回到还重叠的位置才会再接上。

## 已知限制

丢帧次数不是滚动速度的测量，也不能单独说明图中间为什么有洞。没有原始帧，就不能把某一次导出里的内洞逐帧归因到这次误匹配。

快滚，或两段看起来几乎一样的内容，不会被自动证明为完整。

这一版说明对应的源码没有在这次核对里打包、公证，也没有启动图形界面。已经导出的旧文件不会被改写。

# 0.2.1

Manual scrolling stays free, with no watermark and the same tip entry. Auto-scroll stays off in this build.

## Fixes

Near-duplicate lines (a repeating body plus one narrow unique column) are no longer joined at a small shift when the overlap cannot be proved. The image stays at the last join that was proved.

Finishing then writes the unfinished mark on the file name. The JSON records `isPartial`, `partialReason` and `gaps`. `gaps.afterRow` is the current image height: the gap is after the end, and no pixels are invented in the middle.

The export version is `CFBundleShortVersionString`. A command-line build has no app bundle and is recorded as `dev`, not `0.1.0`. The pack script stamps `0.2.1`, build `3`.

Scrolling back, pausing and uneven speed are fine when the new frame still overlaps the previous one. Past that overlap, it joins again only after you scroll back to a real overlap.

## Limits

A dropped-frame count is not a measurement of scroll speed, and it does not by itself explain an interior hole. Without the original frames, an interior hole in an existing export cannot be attributed frame by frame to this mismatch.

Fast scrolling, or two stretches that only look the same, is not automatically certified complete.

This note was not followed by packaging, notarization or a GUI launch. Older exports are left as they are.
