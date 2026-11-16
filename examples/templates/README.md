# Example templates

Region boxes are fractions of the frame (`x`, `y` from the top-left corner; `width`, `height`), so a template fits any video with the same layout, whatever its resolution. Use one as a starting point, and check it with `lyrics-ocr preview` before a full run. Better still, draw your own with `lyrics-ocr select`.

| File | Layout |
|---|---|
| `two-lines-bottom-left.json` | Chinese above Japanese, lower left. Lines starting with `翻译：` go to `credits`. |
| `two-lines-lower-right.json` | Chinese above Japanese, a wide band in the lower right. |
| `ja-over-zh-lower-right.json` | Japanese above Chinese, a wide band in the lower right. |
| `two-lines-bottom-edge.json` | Chinese above Japanese, a thin strip along the bottom left edge. Lyricist, composer and translator credits (`作词：`, `作曲：`, `翻译：` …) go to `credits`. |

The template for the synthetic sample is written by `lyrics-ocr sample`.

示例模板：框的位置按画面宽高的比例保存（`x`、`y` 从左上角算起），同一版式的视频不论分辨率都能共用。可以拿来当起点，正式跑之前先用 `lyrics-ocr preview` 看一眼；更好的做法是用 `lyrics-ocr select` 自己框。
