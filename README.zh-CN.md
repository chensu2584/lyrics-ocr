# lyrics-ocr

[English](README.md)

在 Mac 上把压制在歌词视频里的双语字幕认出来，再把时间轴换算到你自己的那份音源上。

提取硬字幕的工具不少，这个工具多做了后半步：视频里的字幕时间会被换算到另一份本地录音上。那份录音可以是另一个母带，片头长短不同，或者整体快一点、慢一点，每句译文都能挂到你那份音源对应的歌词行上。识别完还有一套核对流程：日文和参考歌词逐行比对，已知的形近误读会附上放大截图标出来，人工改字记在改字表里，重跑之后可以再次应用。

![合成样本的一帧：上面一行中文，下面是它的日文训读](docs/sample-frame.jpg)

```
$ ./lyrics-ocr extract demo/sample.mp4 --template demo/template.json \
    --audio demo/other-master.wav --lrc demo/reading.lrc --out demo/out
音频对齐：偏移 -4.9604 秒，比例 0.9920311，9 个匹配点，最大偏差 0.003 秒

$ cat demo/out/audio.lrc
[00:01.27]春眠不觉晓 / 春眠暁を覚えず
[00:05.24]处处闻啼鸟 / 処処に啼鳥を聞く
…
```

所有处理都在本机完成：视频用 AVFoundation 解码，文字用 Vision 识别，音频用 Accelerate 比对。不依赖任何第三方库。

## 环境与范围

- Apple Silicon Mac，macOS 14 或更新。
- Swift 6：Xcode 16 或更新，或者只装对应版本的 Command Line Tools（`xcode-select --install`）。

不支持 Windows、Linux 和 Intel Mac，不提取软字幕轨（那种用解封装工具更合适），也不做语音识别。工具只读画面里画出来的字。

实际用过的是简体中文、繁体中文和日文。Vision 支持的其他语言应该也能提取，但没有测过。假名检查和简繁检查只对日文、中文字幕框运行。

## 安装

```sh
git clone https://github.com/chensu2584/lyrics-ocr.git
cd lyrics-ocr
./lyrics-ocr --help
```

`lyrics-ocr` 脚本第一次运行时会编译 release 版本，源码改动后会重新编译。也可以自己运行 `swift build -c release`，然后直接用 `.build/release/lyrics-ocr`。

## 五分钟跑通

工具可以自己生成样本，试用时不需要任何有版权的素材：

```sh
./lyrics-ocr sample demo
```

会生成以下文件：

- `sample.mp4`：40 秒的视频，内容是两首唐诗的原文，每句下面配传统的日文训读（書き下し），片头有一行出处。唐诗属于公有领域，训读是约定俗成的读法，不是谁的译文。配乐是程序合成的。
- `other-master.wav`：同一段配乐，剪掉前 5 秒，并加快 0.8%，相当于“你自己的那份音源”。
- `template.json`：两行字幕在画面里的位置。
- `reading.lrc`：按 `other-master.wav` 打好时间的日文歌词，相当于你手头已有的歌词。
- `truth.json`：标准文本和时间，用来量准确率。

然后提取字幕，并换算到另一份音源上：

```sh
./lyrics-ocr extract demo/sample.mp4 --template demo/template.json \
  --audio demo/other-master.wav --lrc demo/reading.lrc --out demo/out
```

在这个样本上，八句全部逐字认对，自动对齐找到的剪切和变速误差在几毫秒以内。`demo/out/translation.json` 按 `reading.lrc` 的行号给出每行的中文。片头那行出处会单独存进 `video.json` 的 `credits`，不混进歌词。

## 用在自己的视频上

### 1. 框选字幕区域

```sh
./lyrics-ocr select video.mp4 --at 00:01:12.500 --template my-layout.json \
  --region zh=zh-Hans --region ja=ja-JP
```

选一个两行字幕都完整显示的时间点。弹出窗口后依次拖框，再点“保存模板”。框的位置按画面宽高的比例保存，所以同一种版式的视频可以共用一个模板。也可以只设一个框（`--region zh=zh-Hant`）。想先看几帧，可以用 `./lyrics-ocr preview video.mp4 --at 72.5 --out frame.png`。

[`examples/templates/`](examples/templates) 里有几种常见版式的模板。

每个框还可以设置以下字段：

- `brightTextThreshold`：用于暗底白字。亮像素没有变化的帧直接沿用上一帧的结果，空白帧跳过。不设时，每个取样帧都会识别。
- `ocrBrightnessThreshold`：交给 Vision 的增强图单独用一个阈值。调低可以保住细笔画。
- `ignorePrefixes`：以这些前缀开头的行（比如 `"翻译："`）记进 `credits`，不当作歌词。

### 2. 提取

```sh
./lyrics-ocr extract video.mp4 --template my-layout.json --out out \
  [--audio song.flac] [--lrc song.lrc] [--reference song.lrc] [--review-images]
```

默认每秒取 4 帧。可以先用 `--start 20 --end 40` 试一小段，换行快的视频调高 `--fps`。不给 `--audio` 时，只输出视频时间轴上的结果。

| 文件 | 内容 |
|---|---|
| `lyrics.txt` | 双语纯文本，每组上下两行 |
| `video.srt`、`video-<id>.srt` | 视频时间轴上的字幕，合并版和分框版 |
| `audio.lrc`、`audio.srt`、`audio-<id>.lrc` | 同样的内容，换到你那份音源的时间轴（需要 `--audio`） |
| `translation.json` | 按你的 LRC 行号（从 0 起）排列的译文（需要 `--lrc`） |
| `video.json` | 各框的结构化字幕，以及 `credits` |
| `alignment.json` | 音频匹配点和时间映射 |
| `review.json`、`review/` | 待核对的行、原因和 2 倍放大截图 |

### 3. 换一份音源对齐

自动对齐能处理转码、片头片尾长短不同和轻微变速。已有提取结果时，不必重新识别：

```sh
./lyrics-ocr align video.mp4 other.flac --cues out/video.json --out out-other [--lrc other.lrc]
```

自动匹配没把握时（比如中间有剪辑，或者是另一场演出），可以手动指定对应关系：

- `--anchor 42=37`：视频第 42 秒对应音源第 37 秒。一个锚点整体平移，多个锚点在相邻锚点之间插值。
- `--segment 5:80=0:75 --segment 86:182=75:171`：只映射列出的片段，比如音源删掉了视频里的 6 秒。片段以外的字幕不写入结果。

### 4. 核对

`extract` 结束时会自动检查一遍。想换参数重新检查：

```sh
./lyrics-ocr check out --reference song.lrc [--zh Hans|Hant] [--video video.mp4]
```

`review.json` 会列出以下几类：

- 与参考歌词不同的日文行，并标出多出和缺少的字。字幕把两三行歌词并成一句，或把一行拆开，都算对上。
- 没有跟在い段假名后面的小写ゃゅょ（常见于把よ认成ょ）。
- 简体译文里混进的繁体字，或者繁体里混进的简体字，附转换建议。
- 已知的形近误读，比如 千燥 → 干燥、叙しい → 寂しい。这张表来自对真实字幕的人工核对。用 `--misreads 文件.json`（格式为 `{"zh": {...}, "ja": {...}}`）可以换掉内置的表。
- 帧数太少、置信度低，或者原图和放大图读法不一致的行。

和参考歌词不同不一定是错，字幕可能用了别的写法（あなた／貴方）。改之前请先对照画面确认。

### 5. 应用改字

改字请写进改字表，不要直接改输出文件，这样重跑之后还能再用：

```json
{"fixes": [
  {"cue": 5, "lang": "zh", "from": "千燥", "to": "干燥"}
]}
```

`cue` 是 `video.json` 里 `combined` 列表的序号，图片则用 `pair`，都从 0 开始。每条改字都会先确认 `from` 确实存在，找不到就报错，过期的改字表不会悄悄改错行。

```sh
./lyrics-ocr fix out/video.json --fixes fixes.json --out out-fixed
```

`extract`、`align` 和 `image` 也接受 `--fixes`。一整张专辑可以共用一份改字表，每条带上曲号 `no`，用的时候加 `--track 3` 选曲。

## 图片版歌词

有些译文是以图片发布的：白底，原文、罗马音、译文逐行排列，译文用较浅的颜色或彩色。

```sh
./lyrics-ocr image 01.jpg 02.jpg --out out --zh zh-Hant --source-url 'https://example.com/post'
```

图片按给出的顺序读。工具根据每行笔画最深处的颜色深浅来分类，蓝灰、暖灰、青绿的译文都能和黑色原文分开。输出 `image.json`、`lyrics.txt` 和 `review.json`，原图会复制到 `image-sources/`，并记下来源网址。

## 使用须知

这些视频和图片里的译文属于写下它们的人。工具在设计上照顾这一点：

- 署名会保留下来，不会被丢掉。命中 `ignorePrefixes` 的行连同出现时间一起写进 `video.json` 的 `credits`；图片版会记录每张图的来源网址。
- 无论把译文用在哪里，都请带上译者的名字。
- 提取结果供自己听歌、学习使用。转载到任何地方之前，请先征得译者同意。

## 开发

```sh
swift build
scripts/test.sh
```

`scripts/test.sh` 会运行 `swift test`；只装了 Command Line Tools 时，它会补上 Swift Testing 需要的框架路径。端到端测试会生成样本、用 Vision 识别，并检查文字、时间和对齐结果；设置 `LYRICS_OCR_SKIP_E2E=1` 可以跳过。GitHub 托管的 Mac 是虚拟机，视频编码和 Vision 在上面不可靠，所以 CI 以单元测试为准，端到端测试单独跑一个仅供参考的任务。界面语言跟随系统（中文或英文），用 `LYRICS_OCR_LANG=en` 或 `zh` 可以指定。

这是个人工具，分享出来供参考。欢迎提 issue 和 PR，但不保证及时回复。

## 许可证

MIT，见 [LICENSE](LICENSE)。
