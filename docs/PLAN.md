# Plan: from working pipeline to a usable app

Status when this was written: every stage exists and compiles (detect, measure, recognise, fuse views, match to sets), the piece detector is trained, and the recognition model is a 100-shape pilot. Nothing has run on a phone or seen a real photo. The phone app needs the Node server on the same Wi-Fi.

Work is split into what can be done and verified without a phone (Parts A and B, now) and what needs real photos (Part C, later).

## Part A: make the phone self-sufficient

Goal: install the app, scan, see what you can build. No server, no Wi-Fi, no settings.

| Step | What | How it is verified without a phone |
| --- | --- | --- |
| A1 | **Core logic as a Swift package** (`ios/BrickCore`): everything that is not camera or screen. Moves `PieceDetector`, the detector's pixel grouping, view fusion and the size check out of the app target. | `swift test` on the Mac |
| A2 | **Catalog file.** A Node script (reusing `lib/catalog.js`) writes one SQLite file: parts, colours, which colours each part comes in (with how common and a picture), sets, set contents, and the print/mould variant groups. Expected size 15-25 MB. Bundled in the app. | Row counts and spot checks against the server |
| A3 | **Catalog reader in Swift**, using the SQLite that ships with iOS (no dependency): part lookup, search, colour ranking for a measured colour. | Same fixtures as the JS tests; results must match the server's |
| A4 | **Set matching in Swift**: port of `ownedCounts`, `builds`, `buildDetail`. Set contents are held in memory as flat arrays (about 12 MB) so ranking all sets stays under a tenth of a second. | Golden files: the server computes builds for sample inventories on the real catalog, the Swift port must produce identical output |
| A5 | **Inventory on the phone**, in its own SQLite file: lots, scan batches, timestamps. CSV export and import in the format Rebrickable accepts. | Unit tests |
| A6 | **Switch the app over**: screens talk to the local services, the Settings server field and the server recognition path are removed. The web app and server stay in the repository as a separate, desktop way to use the same catalog. | Xcode build on the Mac |
| A7 | **Replay harness**: the scan pipeline takes frames and camera poses from an interface, not directly from ARKit. A command-line tool feeds it a rendered sweep (the scene renderer already knows every piece and the camera) and reports end-to-end accuracy. | This is itself the verification tool: detection, recognition, de-duplication and counting, measured on synthetic sweeps on the Mac |

Later, not now: catalog updates downloaded in the app (needs somewhere to host the file), iCloud sync.

## Part B: make it easy to use

| Step | What |
| --- | --- |
| B1 | **Guided scanning.** A small map of the table showing where the camera has been and where pieces were found, so gaps are obvious. Haptic tick for each new piece. A "looks complete" prompt when a pass over covered ground finds nothing new. |
| B2 | **Review by exception.** Confident pieces are accepted automatically and summarised. Only uncertain ones are shown, grouped by look-alike, each with its crop beside catalog pictures of the top three candidates. One tap to choose, one to mark "not a Lego piece". |
| B3 | **Scans that add up.** Each scan is a batch added to one inventory. Batches are listed with date and piece count and can be undone. Warning when a new scan looks like a repeat of the last one. |
| B4 | **What can I build.** Filters for theme, size and year; sort by fewest missing pieces; favourites. Set page shows what is missing with pictures, links to instructions, and exports the missing list (CSV, and BrickLink wanted-list XML). |
| B5 | **First run and empty states.** Three-screen introduction to laying out pieces and sweeping. Clear messages when the camera is denied, the table is not found, or lighting is too dim. |
| B6 | **Accessibility.** Dynamic Type, VoiceOver labels, colour names always shown beside swatches. |

Verification without a phone: every screen gets SwiftUI previews with sample data, and the Mac session can build and screenshot them in the simulator once its CoreSimulator is updated. The camera screen cannot run in the simulator; its logic is covered by the replay harness (A7).

Order: A1, A2-A5 (independent of each other), A6, A7, then B2 and B3 (they shape the data model), B4, B1, B5, B6.

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
