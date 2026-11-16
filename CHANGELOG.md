# Changelog

## 0.1.0

First public release.

- `extract`: read bilingual subtitles burnt into a video with Vision, with smoothing across frames, credit lines kept apart in `credits`, and a review report with enlarged screenshots.
- `align`: map subtitle timing onto another recording automatically (offset and slight speed change), or by `--anchor` / `--segment`; `--lrc` attaches each translation to its lyric line.
- `image`: read lyric images with original, romaji and colored translation lines.
- `check`: compare Japanese with reference lyrics; flag invalid small kana, mixed Simplified / Traditional characters and known misreadings.
- `fix`: apply a fixes file that checks every replacement against the text it expects.
- `select` / `preview`: draw subtitle regions on a frame and save them as a template.
- `sample`: generate a copyright-free demo video and a trimmed, sped-up copy of its audio.
- Messages in Chinese or English, following the system language.
