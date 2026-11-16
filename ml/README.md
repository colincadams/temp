# Part recognition model

Trains the on-device model that recognises a Lego part's shape from a camera crop. Training images are rendered from the LDraw 3D parts library, so no hand-labelled photos are needed to start.

## Steps

Use Python 3.13 (the `bpy` Blender module is built for specific Python versions). Run from the repository root after the server has downloaded the catalog into `data/`.

```sh
pip install -r ml/requirements.txt

# 1. Get the 3D parts library (about 150 MB) and the part category list.
curl -LO https://library.ldraw.org/library/updates/complete.zip && unzip -q complete.zip -d ml/
curl -L -o data/part_categories.csv.gz https://cdn.rebrickable.com/media/downloads/part_categories.csv.gz

# 2. Choose the shapes to learn, most used first.
python ml/build_manifest.py --ldraw ml/ldraw --max-classes 1000

# 3. Render training images (about 0.1 s each on an M4 Pro). Safe to interrupt and restart.
python ml/render.py --ldraw ml/ldraw --per-class 300

# 4. Train, then check against real photos arranged as ml/real/<part number>/*.jpg.
python ml/train.py            # add --resume to continue an interrupted run
python ml/evaluate.py --checkpoint ml/runs/v1/best.pt --photos ml/real

# 5. Convert for the iPhone app.
python ml/export.py --checkpoint ml/runs/v1/best.pt
```

## Piece detector

A second model finds each piece in the camera frame, including pieces that touch. Without it the app falls back to a colour threshold that merges touching pieces.

```sh
python ml/render_scenes.py --ldraw ml/ldraw --scenes 3000    # whole tables with a per-piece outline map; resumable
python ml/train_detector.py                                  # reports pieces found and false detections on held-out tables
python ml/export_detector.py --checkpoint ml/runs/detector/best.pt
```

The network predicts, for each pixel, whether it belongs to a piece, how near it is to a piece's centre, and the offset to that centre. Two touching pieces share an edge but not a centre, so grouping pixels by the centre they point at separates them. The scenes deliberately include pieces pushed flush together in the same colour, the hardest case.

## Replay a sweep

Scores the app's scan pipeline (find pieces in each frame, place them on the table, follow them across frames, count each once) on a rendered sweep, with no phone. The tool runs the same BrickCore code the app runs, with the app's frame gating (phone facing down, not moving too fast, one frame every 0.2 s).

```sh
# 1. Render a phone's pass over one table. --ids adds a piece-number map per frame (a quick second pass).
python3 ml/render_sweep.py --ldraw ml/ldraw --out ml/sweeps/001 --seed 1 --ids \
    --table-width 300 --table-depth 220 --image-width 640 --image-height 480 --samples 8

# 2. Optional: the trained detector's output for every frame, or ideal output made from the piece maps.
python3 ml/sweep_maps.py ml/sweeps/001 --checkpoint ml/runs/detector/best.pt
python3 ml/sweep_maps.py ml/sweeps/001 --ideal

# 3. Replay and score.
cd ios/BrickCore
swift run -c release brick-replay ../../ml/sweeps/001 --detector colour   # the colour threshold (no model)
swift run -c release brick-replay ../../ml/sweeps/001 --detector truth    # perfect detection: shows tracking errors alone
swift run -c release brick-replay ../../ml/sweeps/001 --detector maps     # the detector network, via NNNN.maps
```

The report says how many pieces were on the table, how many the camera showed whole in at least 3 processed frames (the ones the scan could fairly be expected to find), and of those how many were found, missed, or merged into a neighbour; and of the pieces counted, how many were a piece counted twice, two or more pieces taken as one, or nothing at all. It also gives the error of the measured length against the piece's true footprint, the position error, and how far the measured colour is from the catalog colour. `--list` prints every piece; the full report is saved as `replay-<detector>.json` in the sweep folder. `--match frame` matches each frame's detections to known pieces all at once instead of one at a time as the app does now.

### Techniques measured before they go into the app

Three techniques from continuous-scanning apps live in BrickCore, tested, but are not yet wired into `ScanEngine` (each source file starts with the calls it should make). The replay switches them on one by one; the report says what each did, and the file name of the JSON report gains a suffix per option.

```sh
swift run -c release brick-replay <sweep> --detector truth --match frame --sharpness on       # gate | views | on
swift run -c release brick-replay <sweep> --detector truth --match frame --negative-evidence  # add --phantoms 10 to inject phantoms
swift run -c release brick-replay <sweep> --detector truth --match frame --consolidate
```

`--match frame` is how the app matches detections now. The numbers below are from sweeps rendered as in step 1 (640 x 480, 300 x 220 mm tables, seeds 1-5).

**Sharpness (`Sharpness.swift`).** A frame's score is a Laplacian variance of its luminance, taken along x, y and both diagonals and keeping the smallest (a smear along x leaves edges along x sharp, so the plain Laplacian cannot fall below about half), on 2 x 2-averaged pixels so single-pixel noise does not count, at every 8th pixel: 0.2-0.3 ms a frame. A frame is skipped when its score is under 0.35 of the median of the last 15 frames. A piece's region score (the same measure over its box, divided by the box's contrast so pale and dark pieces compare) scales its view quality when it is under half the typical region score, so the thumbnail and the crops sent for recognition come from sharp views (about 8 microseconds a piece).

To test it, `render_sweep.py --motion-blur SECONDS --blur-share 0.3` gives 30% of the frames a long exposure: each is smeared along the camera's motion during that time. This is an approximation applied to the rendered frames, not Blender's motion blur (the sweep's camera jitters its tilt independently per frame, which Blender would turn into a large rotational smear): for a camera sliding over a flat table the picture moves as a whole, so the smear is a box blur of length focal x speed x exposure / height along the motion (pieces stand a few centimetres at most, so parallax changes that by under 10%). sweep.json records each frame's smear as `blurPx`, the piece maps stay sharp, and the replay reports how many processed frames were blurred and how many counted pieces got their best view from one.

What the score keeps of a frame, blurring every frame of a sweep by a given smear (seed 4): 2 working pixels 0.34-0.61, 3-5 pixels 0.12-0.44 (typically 0.18), 6-10 pixels about 0.06, 14-19 pixels 0.02. Sharp frames vary only down to about 0.65 of the median as the view moves over fuller or emptier ground. So 0.35 rejects smears of about 3 pixels or more (1.8 mm on the table at 32 cm, a tenth of a 1 x 2 plate's length) and no sharp frame: 0 of the 110 frames of five unblurred sweeps were rejected. When every frame is blurred the median follows them and nothing is rejected, so a dim room slows nothing down.

Seed 5 (303 pieces), rendered with `--motion-blur 0.0333 --blur-share 0.3` (7 of 22 frames smeared 7-9 px) and again without:

| | frames used | truth: found / twice | truth: best view blurred | colour: found | colour: long side measured/true | colour: short side error | colour: position error |
| --- | --- | --- | --- | --- | --- | --- | --- |
| no blur | 22 | 301 / 3 | - | 59 | 1.06 | 4.7 mm | 2.8 mm |
| blur, sharpness off | 22 | 301 / 3 | 125 of 304 | 77 | 1.04 | 4.5 mm | 3.3 mm |
| blur, `--sharpness gate` | 15 | 300 / 2 | 0 | 46 | 0.99 | 1.7 mm | 1.8 mm |
| blur, `--sharpness views` | 22 | 301 / 3 | 1 | 77 | 1.04 | 4.5 mm | 3.3 mm |

The gate rejected exactly the 7 blurred frames, here and on four more blurred copies of sweeps 2 and 4 (7-10 px and 14-19 px). With perfect detection nothing is lost (one piece drops out of the fair set for being seen whole in only 2 frames). The colour threshold, unexpectedly, finds more pieces with the blurred frames than without (77 against 59; not investigated, perhaps because blur evens out stud texture), so for it the gate trades count for measurement. The trained detector was not run on blurred frames. The region factor alone moves nearly every best view off the blurred frames: on the four blurred copies, 135, 13, 135 and 13 best views from blurred frames became 0, 0, 1 and 0.

**Negative evidence (`Visibility.swift`).** Each processed frame, a tracked piece whose spot lies well inside the view (inside the coverage map's 5%-inset footprint by half its length plus 5 mm) gets a hit if a detection matched it and a miss if none did. The evidence is a log-odds sum: a hit multiplies the odds "real : phantom" by (1 - m) / p and a miss by m / (1 - p), where m is the detector's miss rate for a piece in plain view and p the chance a phantom turns up again at the same spot (0.2). A piece is doubtful, and left out of the count and the review until seen again, once the odds are 1 : 16 against it; the evidence is capped so a piece seen 50 times is still flagged after 7 misses in a row, and a doubtful one comes back after 2 sightings (at m = 0.2). m must match the detector: the replay measures it (`realPieceMissRate`, `viewMissRate`): under 0.3% for the truth and ideal-maps detectors, 59-76% of pieces in view for the colour threshold, so the replay uses 0.2 for those and 0.6 for colour (`--miss-rate`).

`--phantoms 10` injects 10 phantom blobs at random free spots, each reported in the 3 processed frames that first show its spot well and never again (fewer fit on a crowded table). Over sweeps 1-4, 27 phantoms were placed:

| detector | phantoms counted, without | with negative evidence | real pieces lost |
| --- | --- | --- | --- |
| truth | 27 | 3 | 0 |
| maps (ideal) | 27 | 3 | 0 |
| colour, m = 0.6 | 27 | 23 | 0 |
| colour, m = 0.2 | 27 | 3 | 16 (and 8 second tracks of a piece rightly dropped) |

The 3 survivors lay near the table's far edge (125-130 mm from its middle), which only the last row's views show, too few times after their hits. Without phantoms nothing was set aside with whole-frame matching; with one-at-a-time matching it removed the 1 and 2 pieces counted twice on sweep 4 (truth and maps), whose old tracks stop being matched.

**Consolidation (`Consolidation.swift`).** When the user taps Review, pairs of tracks are merged when they were never detected in the same frame (a hard rule), lie within one piece length (at least 15 mm), have the same colour (RGB within 60, or the same hue at up to twice the brightness: one face lit, one in shade) and the same size (within 1.6 times). The app logs which tracks each processed frame matched (`ObservationLog`) to know this.

| sweeps 1-4, truth / maps | counted twice before | after | merges | wrong merges |
| --- | --- | --- | --- | --- |
| whole-frame matching | 2 / 2 | 1 / 1 | 1 / 1 | 0 |
| one-at-a-time matching | 4 / 5 | 2 / 4 | 2 / 1 | 0 |

The colour threshold's doubles were not merged (0 merges, 0 wrong). The merged double is an upright 48 mm bar measured from its lit and its shaded side; every remaining double was, in some frame, matched by a neighbour's detection while its twin was detected, so the rule cannot touch it: that is a tracking fault to fix in the tracker.

Each frame is stored for the tool as raw pixels at the detector's working size (`NNNN.rgba`, every `step`-th pixel as the app downsamples, `step` = width / 640), next to `NNNN.ids` (piece numbers, 16-bit) and `NNNN.maps` (detector output, 4 float32 planes of 320 x 240). For a sweep rendered before these existed, run `python3 ml/sweep_frames.py <sweep folder>`; true sizes then come from `--manifest ml/manifest.json`.

## Design

- **Shape classes.** Printed and re-moulded versions of a part are one class, since they are the same shape. 1,000 classes cover about 93% of all pieces in sets since 1990; 3,000 cover about 96%.
- **Rendering.** Each part is dropped in a physically plausible resting pose, in colours it is really made in, with random table, lighting, camera angle and neighbouring pieces.
- **Model.** A pretrained image backbone fine-tuned to produce an embedding, compared against one prototype per shape with a margin loss that separates look-alikes. `--backbone` takes any `timm` model name.
- **Scale is not in the image.** A crop of a 1 x 2 plate and a 1 x 4 plate can look alike once resized. The app measures each piece in millimetres and `classes.json` carries every shape's true dimensions, so the two are combined on the phone.
- **Colour is not learned.** It is measured from the pixels, so training deliberately varies lighting and tint.

## Status

- **Recognition model:** a pilot has been run on an M4 Pro: 100 shapes, 150 images each, 8 epochs. Rendering took 25 minutes, training 28 minutes, and the model reached 84% top-1 and 97.5% top-5 on held-out rendered images (still improving when it stopped, and before the size check the app adds). It exported and compiled into the app. No full-size model has been trained yet.
- **Piece detector:** trained on an M4 Pro on 2,000 rendered tables averaging 225 pieces (50 minutes to render, 35 to train). On held-out rendered tables it finds 99.1% of pieces standing apart and 94.7% of pieces touching a neighbour, and 6% of its detections are not real pieces. It is exported and compiled into the app.
- Accuracy on real photos is unmeasured for both.
