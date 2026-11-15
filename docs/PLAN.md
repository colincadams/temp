# Plan: from working pipeline to a usable app

Status when this was written: every stage exists and compiles (detect, measure, recognise, fuse views, match to sets), the piece detector is trained, and the recognition model is a 100-shape pilot. Nothing has run on a phone or seen a real photo.

Work is split into what can be done and verified without a phone (Parts A and B, now) and what needs real photos (Part C, later).

## Architecture: phone for perception, server for knowledge

The phone does what has to happen at camera speed: detect pieces, measure them, recognise their shape, fuse views. The server holds everything that changes or is shared: the catalog, set matching, the inventory, corrections, and second opinions on hard pieces.

Why not put everything on the phone:
- **One implementation.** Set matching and the catalog logic exist once, already tested. A Swift copy would have to be kept identical forever.
- **Always current.** New sets appear weekly; the server refreshes its catalog and every user has them at once.
- **Better accuracy over time.** The server can collect corrections for retraining, run a larger model or an outside service on pieces the phone is unsure about, and deliver new phone models.
- **Room to grow.** Inventory shared across devices, and later things like parts prices, need a server anyway.

What this costs: the app needs a connection to finish a scan and to show builds, and a public release needs the server hosted somewhere with user accounts. Until then it runs on a computer on the same Wi-Fi, as now.

## Part A: a solid phone-plus-server base

| Step | What | How it is verified without a phone |
| --- | --- | --- |
| A1 | **Server: scans as batches.** Every addition to the inventory is a batch with a time and a source, listed and undoable. | Server tests |
| A2 | **Server: corrections.** When a user fixes a match, the crop and the right answer are saved in the layout `ml/evaluate.py` and training already read. | Server tests |
| A3 | **Server: richer builds.** Sort by fewest missing pieces, filter by year, export a set's missing parts. | Server tests |
| A4 | **Second opinion.** Pieces the phone model is unsure about, or that look like none of its shapes, are sent to the server's recognition service; the better answer wins. Common pieces stay on the phone; rare ones get the wider coverage. | Replay harness (A6) |
| A5 | **Core logic as a Swift package** (`ios/BrickCore`): everything that is not camera or screen, including `PieceDetector`, the detector's pixel grouping, view fusion and the size check. | `swift test` on the Mac |
| A6 | **Replay harness**: the scan pipeline takes frames and camera poses from an interface, not directly from ARKit. A command-line tool feeds it a rendered sweep (the scene renderer knows every piece and the camera) and reports end-to-end accuracy. | This is itself the verification tool: detection, recognition, de-duplication and counting, measured on synthetic sweeps on the Mac |
| A7 | **Scanning without a connection.** The phone keeps names and colours for the shapes its model knows, so a scan can be completed and reviewed offline and sent when the server is reachable. | Unit tests |
| A8 | **No setup.** The app finds a server on the local network by itself; later, a hosted address is built in. | Xcode build |

Needed before a public release, not now: hosting, user accounts and sign-in, a real database in place of the JSON file, scheduled catalog refresh.

## Part B: make it easy to use

| Step | What |
| --- | --- |
| B1 | **Guided scanning.** A small map of the table showing where the camera has been and where pieces were found, so gaps are obvious. Haptic tick for each new piece. A "looks complete" prompt when a pass over covered ground finds nothing new. |
| B2 | **Review by exception.** Confident pieces are accepted automatically and summarised. Only uncertain ones are shown, grouped by look-alike, each with its crop beside catalog pictures of the top three candidates. One tap to choose, one to mark "not a Lego piece". |
| B3 | **Scans that add up.** Each scan is a batch added to one inventory. Batches are listed with date and piece count and can be undone. Warning when a new scan looks like a repeat of the last one. |
| B4 | **What can I build.** Filters for theme, size and year; sort by fewest missing pieces; favourites. Set page shows what is missing with pictures, links to instructions, and exports the missing list as CSV. (A BrickLink wanted list needs BrickLink's own part and colour numbers, which the catalog download does not include.) |
| B5 | **First run and empty states.** Three-screen introduction to laying out pieces and sweeping. Clear messages when the camera is denied, the table is not found, or lighting is too dim. |
| B6 | **Accessibility.** Dynamic Type, VoiceOver labels, colour names always shown beside swatches. |

Verification without a phone: every screen gets SwiftUI previews with sample data, and the Mac session can build and screenshot them in the simulator once its CoreSimulator is updated. The camera screen cannot run in the simulator; its logic is covered by the replay harness (A6).

Order: A1-A3 (server), A5, A6, A4, then B2 and B3, B4, B1, A7, A8, B5, B6.

## Part C: accuracy, once real photos exist

### C0. Before any photos
Train the full recognition model (1,000 shapes, about 15 hours on the M4 Pro). Can run at any time; it does not need a phone.

### C1. What to capture
A set you own is ideal: its exact contents are in the catalog, so no hand labelling is needed to score counts.

- Add a **record mode** to the app that saves the sweep's frames and camera poses, so each capture can be replayed through new models forever.
- Capture the same set under a small grid of conditions: two lightings (daylight, indoor lamp), two tables (light, dark), two layouts (spread out, crowded). Eight sweeps is enough to start.
- Corrections made on the review screen are saved with their crops; these become per-piece labels.

### C2. What to measure
| Stage | Measure | Source of truth |
| --- | --- | --- |
| Detection | Pieces counted vs pieces in the set; merged, split and phantom pieces | Set contents |
| Shape | Correct shape first, and within the top three | Review corrections |
| Colour | Correct colour, given the right shape | Set contents |
| End to end | Share of the set's part-and-colour lots with the right count; is the set reported buildable | Set contents |

Proposed first targets, to be revised after the first numbers: count within 3%, shape top-three 95%, lots correct 90%.

### C3. Find the weakest stage first
- Counts wrong, shapes fine: detector. Look at whether pieces are missed (white on light table, transparent), merged (flush same-colour) or split.
- Truth is in the top three but not first: ranking. Tune view fusion and the size check.
- Truth is not in the top five: the model has not learned that shape from renders, or the shape is outside the 1,000.
- Shape right, colour wrong: lighting and colour matching.

### C4. Fixes, cheapest first
1. **Thresholds and weights** (minutes): detector cut-offs, how strongly size counts, views per piece. Replay the recorded sweeps to choose them.
2. **Make renders match reality** (hours): adjust lighting, blur, sensor noise, table textures, and stud logos to resemble the failing photos, then re-render and retrain.
3. **Fine-tune on real crops** (a day): a few hundred corrected crops mixed into the rendered data usually closes most of the gap between rendered and real images.
4. **Detector on real frames** (a day): have the current detector label recorded frames, fix its mistakes by hand on a few dozen, and fine-tune.
5. **Look-alike pairs**: for the specific pairs that stay confused, add targeted renders, or have the app ask the user to flip the piece when the underside decides it.
6. **More coverage**: more shapes, a larger backbone, or the outside recognition service for rare parts.

### C5. Colour
Measure the table's own colour during the sweep to correct for the light, and train a small colour classifier on real crops once there are enough.

### C6. Keep improving
Corrections feed the dataset, retraining is scripted, and new models are delivered without an app update.

## Not in this plan
Performance on older phones, App Store submission, licences and trademark checks, minifigures and printed parts. These follow once accuracy is known.
