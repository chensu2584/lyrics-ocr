# lyrics-ocr

[中文说明](README.zh-CN.md)

Read the bilingual subtitles burnt into a lyric video on your Mac, then move their timing onto your own copy of the song.

Plenty of tools pull hard-coded subtitles out of a video. This one also does the second half: the video's subtitle times are mapped onto a separate local recording (a different master, with a different intro length, or running slightly faster or slower). Every translated line then lands on the right lyric line of your audio. It also helps you proofread the result: the Japanese is compared with reference lyrics, known look-alike misreadings are flagged with enlarged screenshots, and your corrections are kept in a fixes file that can be reapplied.

![A frame of the synthetic sample: a Chinese line above its Japanese reading](docs/sample-frame.jpg)

```
$ ./lyrics-ocr extract demo/sample.mp4 --template demo/template.json \
    --audio demo/other-master.wav --lrc demo/reading.lrc --out demo/out
Audio alignment: offset -4.9604 s, scale 0.9920311, 9 matches, max error 0.003 s

$ cat demo/out/audio.lrc
[00:01.27]春眠不觉晓 / 春眠暁を覚えず
[00:05.24]处处闻啼鸟 / 処処に啼鳥を聞く
…
```

Everything runs on your machine: AVFoundation decodes the video, Vision reads the text, and Accelerate matches the audio. There are no third-party dependencies.

## Requirements and scope

- An Apple Silicon Mac with macOS 14 or later.
- Swift 6: Xcode 16 or later, or the matching Command Line Tools (`xcode-select --install`).

Not supported: Windows, Linux and Intel Macs, soft subtitle tracks (use a demuxer for those), and speech recognition. The tool only reads text that is drawn into the picture.

It has been used on Simplified Chinese, Traditional Chinese and Japanese. Other languages that Vision supports should work for extraction, but they are untested. The kana and Chinese-script checks only run on Japanese and Chinese regions.

## Install

```sh
git clone https://github.com/chensu2584/lyrics-ocr.git
cd lyrics-ocr
./lyrics-ocr --help
```

The `lyrics-ocr` script builds a release binary on first use, and again whenever the sources change. You can also run `swift build -c release` and use `.build/release/lyrics-ocr` directly.

## Five-minute walkthrough

The tool can generate its own sample, so you don't need any copyrighted material to try it:

```sh
./lyrics-ocr sample demo
```

This writes:

- `sample.mp4`: a 40-second video with two Tang poems in their original Chinese, each line shown above its traditional Japanese kundoku reading (書き下し), and a credit line at the start. The poems are in the public domain. Kundoku is a conventional reading, not anyone's translation. The soundtrack is synthesized.
- `other-master.wav`: the same soundtrack with the first 5 seconds cut, played 0.8% faster. It stands in for "your own copy of the song".
- `template.json`: where the two subtitle lines sit in the frame.
- `reading.lrc`: the Japanese lines timed to `other-master.wav`, like lyrics you might already have.
- `truth.json`: the exact text and timing, for measuring accuracy.

Then extract the subtitles and map them onto the other recording:

```sh
./lyrics-ocr extract demo/sample.mp4 --template demo/template.json \
  --audio demo/other-master.wav --lrc demo/reading.lrc --out demo/out
```

On the sample, all eight lines come back character for character. The automatic alignment finds the 5-second cut and the speed change within a few milliseconds. `demo/out/translation.json` maps each line of `reading.lrc` to its Chinese line. The credit line ends up in `credits` in `video.json`, apart from the lyrics.

## Your own video

### 1. Mark the subtitle regions

```sh
./lyrics-ocr select video.mp4 --at 00:01:12.500 --template my-layout.json \
  --region zh=zh-Hans --region ja=ja-JP
```

Choose a moment when both lines are fully visible. A window opens; drag a box around each line in turn and click Save. Boxes are stored as fractions of the frame, so one template fits every video with the same layout. A single region also works (`--region zh=zh-Hant`). To look at frames first, run `./lyrics-ocr preview video.mp4 --at 72.5 --out frame.png`.

[`examples/templates/`](examples/templates) has templates for a few common layouts.

Optional fields in each region:

- `brightTextThreshold`: for light text on a dark background. Frames whose bright-pixel mask hasn't changed are reused instead of read again, and empty frames are skipped. If you leave it out, every sampled frame is read.
- `ocrBrightnessThreshold`: a separate threshold for the cleaned-up image passed to Vision. Lower it to keep thin strokes.
- `ignorePrefixes`: lines that start with one of these (for example `"翻译："`, "translation:") are stored in `credits` rather than treated as lyrics.

### 2. Extract

```sh
./lyrics-ocr extract video.mp4 --template my-layout.json --out out \
  [--audio song.flac] [--lrc song.lrc] [--reference song.lrc] [--review-images]
```

By default the tool samples 4 frames per second. Try a short span first with `--start 20 --end 40`, and raise `--fps` for fast line changes. If you leave out `--audio`, you only get the video-timed results.

| File | Contents |
|---|---|
| `lyrics.txt` | Plain bilingual text, one block per line pair |
| `video.srt`, `video-<id>.srt` | Subtitles on the video's timeline, combined and per region |
| `audio.lrc`, `audio.srt`, `audio-<id>.lrc` | The same, on your recording's timeline (with `--audio`) |
| `translation.json` | Translation per line of your LRC file, keyed by line number from 0 (with `--lrc`) |
| `video.json` | Structured cues per region, plus `credits` |
| `alignment.json` | Audio matching points and the time mapping |
| `review.json`, `review/` | Lines to check, with reasons and 2× screenshots |

### 3. Align with another recording

Automatic alignment handles transcodes, different intro and outro lengths, and slight speed differences. You can align an extraction again later without running OCR:

```sh
./lyrics-ocr align video.mp4 other.flac --cues out/video.json --out out-other [--lrc other.lrc]
```

When the automatic match isn't confident (an edit in the middle, a live version), say which points correspond:

- `--anchor 42=37`: second 42 of the video is second 37 of the audio. One anchor shifts everything; several anchors interpolate between them.
- `--segment 5:80=0:75 --segment 86:182=75:171`: map only these spans, for example when the recording drops six seconds of the video. Cues outside the spans are left out.

### 4. Proofread

`extract` checks its own output. To check again with different options:

```sh
./lyrics-ocr check out --reference song.lrc [--zh Hans|Hant] [--video video.mp4]
```

The report in `review.json` lists:

- Japanese lines that differ from the reference lyrics, with the extra and missing characters. Subtitles that merge two or three lyric lines, or split one, still count as matching.
- Small ゃ/ゅ/ょ that don't follow an i-row kana (a frequent misreading of よ).
- Traditional characters in Simplified text, or the reverse, with a suggested conversion.
- Known look-alike misreadings, such as 千燥 → 干燥 and 叙しい → 寂しい. These come from proofreading real subtitles by hand. Use `--misreads file.json` (`{"zh": {...}, "ja": {...}}`) to replace the built-in table.
- Lines read from too few frames, with low confidence, or read differently from the enlarged image.

A difference from the reference is not always an error: subtitles can use other spellings (あなた / 貴方). Check against the frame before changing anything.

### 5. Apply corrections

Keep your corrections in a fixes file rather than editing outputs by hand. That way they can be reapplied after a re-run:

```json
{"fixes": [
  {"cue": 5, "lang": "zh", "from": "千燥", "to": "干燥"}
]}
```

`cue` is the index in `video.json`'s `combined` list. For images, use `pair` instead. Both count from 0. Each fix checks that `from` is really there and stops with an error if it isn't, so a stale fixes file can't silently change the wrong line.

```sh
./lyrics-ocr fix out/video.json --fixes fixes.json --out out-fixed
```

`extract`, `align` and `image` also accept `--fixes`. A single fixes file can cover a whole album if each entry carries a track number `no`; pick the track with `--track 3`.

## Lyric images

Some translations are published as images: a white background with original / romaji / translation lines in turn, the translation in a lighter or colored ink.

```sh
./lyrics-ocr image 01.jpg 02.jpg --out out --zh zh-Hant --source-url 'https://example.com/post'
```

Images are read in the order given. Rows are classified by how dark the core of their strokes is, so blue-grey, warm-grey or teal translations are all told apart from black originals. The tool writes `image.json`, `lyrics.txt` and `review.json`, copies the originals to `image-sources/`, and records where they came from.

## Using what you extract

The translations in these videos and images belong to the people who wrote them. The tool takes that seriously:

- Credit lines are kept, not thrown away. Lines matched by `ignorePrefixes` go into `credits` in `video.json`, with the time they appeared. Image sources are recorded with their URLs.
- Keep the translator's name with the text wherever you use it.
- Extract for your own listening and study. Before you repost a translation anywhere, ask the translator.

## Development

```sh
swift build
scripts/test.sh
```

`scripts/test.sh` runs `swift test`, adding the framework paths that Swift Testing needs when only the Command Line Tools are installed. The end-to-end test renders the sample, reads it with Vision and checks the text, timing and alignment; set `LYRICS_OCR_SKIP_E2E=1` to skip it. GitHub's hosted Macs are virtual machines where video encoding and Vision are unreliable, so CI gates on the unit tests and runs the end-to-end test as an informational job. Messages follow the system language (Chinese or English); set `LYRICS_OCR_LANG=en` or `zh` to choose.

This is a personal tool, shared in case it is useful. Issues and pull requests are welcome, but responses aren't guaranteed.

## License

MIT. See [LICENSE](LICENSE).
