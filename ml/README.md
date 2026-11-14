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
python ml/train.py
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

## Design

- **Shape classes.** Printed and re-moulded versions of a part are one class, since they are the same shape. 1,000 classes cover about 93% of all pieces in sets since 1990; 3,000 cover about 96%.
- **Rendering.** Each part is dropped in a physically plausible resting pose, in colours it is really made in, with random table, lighting, camera angle and neighbouring pieces.
- **Model.** A pretrained image backbone fine-tuned to produce an embedding, compared against one prototype per shape with a margin loss that separates look-alikes. `--backbone` takes any `timm` model name.
- **Scale is not in the image.** A crop of a 1 x 2 plate and a 1 x 4 plate can look alike once resized. The app measures each piece in millimetres and `classes.json` carries every shape's true dimensions, so the two are combined on the phone.
- **Colour is not learned.** It is measured from the pixels, so training deliberately varies lighting and tint.

## Status

- **Recognition model:** a pilot has been run on an M4 Pro: 100 shapes, 150 images each, 8 epochs. Rendering took 25 minutes, training 28 minutes, and the model reached 84% top-1 and 97.5% top-5 on held-out rendered images (still improving when it stopped, and before the size check the app adds). It exported and compiled into the app. No full-size model has been trained yet.
- **Piece detector:** run end to end at toy scale only (57 small scenes, a network trained from scratch on a CPU), enough to show it learns and exports. No usable detector has been trained yet.
- Accuracy on real photos is unmeasured for both.
