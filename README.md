# gaea-plugin-ace-step

ACE Studio and StepFun's **ACE-Step 1.5** (MIT) as a [Gaea](https://github.com/xocialize-code/gaea) plugin: songs from a
caption and lyrics, on MES Audio 0.1's `audio.compose`. It is built on
[GaeaPluginKit](https://github.com/xocialize-code/gaea-plugin-kit) over
[mlx-ace-step-swift](https://github.com/xocialize/mlx-ace-step-swift), runs in its own process, and speaks the Gaea Plugin
Protocol v1. Add it to Gaea by its repo URL:

```bash
gaea plugins add https://github.com/xocialize-code/gaea-plugin-ace-step
```

## What it offers

One model, `ace-step-1.5`, on `audio.compose`: a 48 kHz stereo song of 10 to 600 s. A 5 Hz planner writes the song's plan,
then a turbo DiT renders it in eight steps and a VAE decodes it.

- **Caption and lyrics.** The caption is the style: genre, mood, instruments, era and the voice.
  - **Sections:** lyrics use MES's tags (`[intro]`, `[verse]`, `[pre-chorus]`, `[chorus]`, `[bridge]`, `[solo]`,
    `[instrumental]`, `[outro]`), with an optional direction (`[chorus - anthemic, full band]`). The plugin writes them
    as ACE-Step does.
  - **Untagged lyrics** are one verse.
  - **Other bracketed lines** are dropped, with `section_unsupported`.
  - **No lyrics** make an instrumental.
- **`language`:** one of the planner's 50 (`en`, `zh`, `ja`, `ko`, `es`, `fr`, `de`, …). Set it: without one, the planner
  picks.
- **`duration_s`:** 10 to 600 s, exact to the frame.
- **`anchors`:** `bpm`, `key` (`"F# minor"`) and `time_signature` (`"3/4"`) are pinned. The plan's values come back as
  `effective.anchors`, pinned or chosen.
- **`timestamps: true`** returns the `timestamps` output, `{lines: [{text, start_s, end_s}]}`.
- **`reference`:** a recording whose timbre the vocals take.
- **`edit` reworks a `source`:**
  - **`cover`:** a new performance in the caption's style. `strength` 0 to 1 says how far it may go (0.5 by default).
  - **`repaint`:** `start_s` to `end_s` is made again, and the rest is kept. The span must lie inside the source.
  - **`extend`:** `before_s` and `after_s` of music around the source.
  - **Length:** an edit's song is the source's length, plus the extension, to the frame. The package decodes whole latent
    windows (an extend of 1 + 2 + 1.5 s comes back 5.12 s), and the worker cuts it to the MES length.
- **Seeds:** the planner samples with the job's seed, so the same request gives the same WAV.
- **No score** (`supports.score` is absent): the planner plans bpm, key and the codes, not an ABC score. `planning` and a
  `score` input are refused.
- **One quality tier.** The DiT is distilled to eight steps.
- **Output:** a 48 kHz stereo 16-bit WAV, peak-normalized to −1 dBFS, converted by Gaea to the request's `output`.

On an M5 Max at int8, warm, a 10 s or 30 s song takes about 5.7 s. An edit of a 2 s source takes 0.4 s.

## Lanes and memory

Three lanes, the planner's quant: `int8` (the default, 10.0 GB resident), `bf16` (11.0 GB) and `int4` (9.2 GB), each up to
8 GB more while decoding, by the package's measurements. Through the plugin check, int8 measured 11.5 GB after a 10 s song
and peaked at 13.2 GB.

## Weights

Gaea sends its models root in `configure` (MLXEngine's store by default). Every lane reads four mlx-community bundles there:
- `ACE-Step-1.5-turbo-bf16` (4.5 GB);
- the planner: `ACE-Step-1.5-planner-1.7B-8bit` (2.3 GB), `-bf16` (3.5 GB) or `-4bit` (1.6 GB);
- `ACE-Step-1.5-text-encoder-bf16` (1.1 GB);
- `ACE-Step-1.5-vae-fp32` (0.6 GB).

It downloads them on `prepare` or `materialize` when they're missing.

## Build and check locally

```bash
scripts/build-plugin.sh
```

```bash
scripts/check-plugin.sh
```

`check-plugin.sh` composes one 10 s song over GPP on the signed bundle, with every `.build` folder hidden. It then shows
that the bare worker, outside the bundle, finds no metallib.

`scripts/release.sh` builds, checks, notarizes with the fleet's `mlx-notary` profile, and publishes the GitHub release.
The release workflow does the same in CI when a `v<version>` tag is pushed.

`ace-step-inproc` (its header lists the options) is not part of the plugin. It runs the same lanes in-process through
MLXServeEngine, with the worker's requests and cut: the reference Gaea's runs are compared against.

```bash
scripts/golden.sh <out-dir>
```

`golden.sh` composes seeded songs over GPP on the signed bundle and through `ace-step-inproc`. It needs each pair to be
the same WAV byte for byte, and of the MES length. The cases:
- a 10 s song;
- a 30 s song with its anchors pinned;
- a 15 s instrumental, and a Chinese song;
- a song with a reference;
- `Tests/Fixtures/source.wav` (2 s of a song this model made) covered, repainted and extended.

## CI secrets

The release workflow signs with Developer ID and notarizes. It reads four organization secrets on xocialize-code:
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID` and `NOTARY_APP_PASSWORD` (Gaea's
`Docs/Signing secrets.md`).

## Licence

The plugin is Apache-2.0 (Gaea G-21). ACE-Step 1.5's weights are MIT (ACE Studio and StepFun, per the GitHub LICENSE).
Its Qwen3 bases, the planner's base and the Qwen3-Embedding text encoder, are Apache-2.0. The port, mlx-ace-step-swift, is
MIT. Covers and supplied lyrics may need the original song's rights; this model's licence doesn't grant them.
