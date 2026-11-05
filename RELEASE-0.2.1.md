# 卷轴PDF 0.2.1

手动滚动照样免费，不加水印，打赏入口也还在。自动滚到底这一版仍然关着。

## 这次修了什么

- **提示条不再乱闪。** 以前好几条提示抢着写，同一刻能跳出「停一下」「往上滚」「已到底」。现在只有一个地方写提示：正常滚动时就一行，告诉你已经收了几张、拼了多长。
- **不再说「到了」骗你。** 断开之后，只有画面真的对上了才会告诉你「接上了」。滚轮估算的距离只拿来给个大概方向；拿不准方向时它不指路，只提示你慢慢上下滚。
- **滚轮距离按真实像素算。** 普通滚轮鼠标的距离以前会被估大好几倍，现在读的是系统给的真实像素位移。
- **证明不了的地方不硬接。** 两段内容长得几乎一样、又证明不了真的重叠时，不再把它们接上。这时点完成，文件名会带上「未完成」，同名 JSON 里会写清楚缺口在哪；图中间不会补上任何编造的像素。
- 导出文件里记录的版本号读的是 app 自己的版本。

## 已知限制

- 甩得太快、或者两段内容看起来一模一样时，它不会替你认定已经拼完整，需要你滚回断开的地方，等它提示「接上了」。
- 以前导出的文件不会被改动。

需要 macOS 14 或更高版本。安装包已经通过 Apple 公证。

---

# Living Scroll PDF 0.2.1

Manual scrolling stays free, with no watermark and the same tip entry. Auto-scroll stays off in this build.

## Fixes

- **The status bar no longer flickers.** It now has a single writer. While you scroll normally it shows one line: how many frames it has and how long the image is.
- **No more false "arrived".** After a break, only real pixels can say "joined". The wheel estimate gives a rough direction at most. When the direction is uncertain, it just asks you to scroll slowly up and down.
- **Wheel distance uses real pixels.** Ordinary wheel mice used to be overestimated several times over. It now reads the system's real pixel delta.
- **No unproved joins.** If two stretches look nearly the same and the overlap cannot be proved, they are not joined. Finishing then marks the file name as unfinished, and the JSON beside it records where the gap is. No pixels are invented.
- The version recorded in exports comes from the app bundle.

## Limits

- After a very fast flick, or on two stretches that look identical, it will not certify the capture as complete. Scroll back to the break until it says "joined".
- Earlier exports are left unchanged.

Requires macOS 14 or later. Notarized by Apple.
