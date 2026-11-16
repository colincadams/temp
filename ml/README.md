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

**Tall pieces and LiDAR depth.** A tall piece's outline takes in its side and top, so the spot where its middle projects onto the table slides as the camera moves, and its outline looks longer than the piece is. The tracker allows for this (`HeightGeometry`, `PieceTracker`): the middle of the outline sits about half-way up the piece, so a detection seen from camera `C` at height `H` lands at `p = B + e (p - C) / H`, with `B` the table point under the piece and `e` half its height. With depth, `e` comes from the piece's height measured in the LiDAR depth map (median of high-confidence depth pixels under the middle of the outline, then the median over its frames; `DepthHeight`). Without depth, `e` and `B` are fitted by least squares from the piece's views once there are three that differ enough. Heights under 6 mm count as flat. The piece is placed at `B`, new detections are matched after the same correction, and its size is measured at the height of its top, from the half of its views taken most nearly from straight above (which show least of its side).

```sh
# Render with the depth an iPhone Pro's ARKit would give (implies --ids); --tall lays out many tall pieces,
# some stood on end and some stacked.
python3 ml/render_sweep.py --ldraw ml/ldraw --out ml/sweeps/001 --seed 1 --depth \
    --table-width 300 --table-depth 220 --image-width 640 --image-height 480 --samples 8
swift run -c release brick-replay ../../ml/sweeps/001 --detector truth --depth on    # a phone with LiDAR
swift run -c release brick-replay ../../ml/sweeps/001 --detector truth --depth off   # a phone without (default)
```

The report then also breaks the results down by the pieces' true height (under 6, 6-10, 10-20 and 20+ mm): found, counted twice, merged, measured over true length, and the height the tracker estimated against the true one. The depth maps are `NNNN.depth` (256 x 192 float32 metres along the viewing axis, rows top to bottom, the picture's field of view, as ARKit's `sceneDepth`) and `NNNN.conf` (one ARConfidenceLevel byte per pixel). They are made from Blender's exact depth with a LiDAR-like noise model (`phone_depth` in `render_sweep.py`): box-averaged to 256 x 192, so edges mix piece and table; noise of 1 cm standard deviation at 30 cm growing with the square of the distance, part independent per pixel and part smooth over a few pixels; confidence medium or low at depth steps; dark pieces noisier and partly medium confidence; transparent pieces partly seen through and low confidence; and a few outliers, some of them still marked high confidence.

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
