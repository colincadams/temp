# Brick Inventory

Photograph your Lego pieces, build up an inventory, and see which official sets you can build with them.

## Run it

Requires Node.js 20 or newer. There are no dependencies to install.

```sh
npm start
```

Then open <http://localhost:3000>. The first start downloads the Lego catalog (about 16 MB) from Rebrickable into `data/`.

To use your phone's camera, start it with `HOST=0.0.0.0 npm start` and open `http://<your-computer's-IP>:3000` on the phone while on the same Wi-Fi. This makes the app reachable by anything on your network, and it has no login.

| Setting | Default | Meaning |
| --- | --- | --- |
| `PORT` | `3000` | Port to listen on |
| `HOST` | `127.0.0.1` | Address to listen on |
| `DATA_DIR` | `./data` | Where the catalog and your inventory are kept |

`npm run update-data` re-downloads the catalog to pick up new sets. `npm test` runs the unit tests.

## How it works

**Scan.** Spread pieces on a plain surface and take a photo. The browser finds each separate piece (`public/segment.js`: background estimation, thresholding, connected components), and each crop is sent to the [Brickognize](https://brickognize.com) recognition service to name the part. The piece's colour is measured from the photo and matched against the colours that part is actually made in. You review every match before anything is saved.

**Inventory.** Adjust counts, add parts by name or number, add every part of a set you own by its set number, or export a CSV (`Part,Color,Quantity`, which Rebrickable can import). Every addition is listed under Recent additions and can be undone.

**What can I build?** Every set in the [Rebrickable](https://rebrickable.com/downloads/) catalog is ranked by how many of its pieces you have. Sort by most complete or by fewest missing pieces. Open a set to see exactly what is missing and export that list. Two options loosen the matching: ignore colour, and treat printed or re-moulded versions of a part as the same part.

## iPhone app (Brick Scan)

`ios/` holds a native app that replaces the photo step with a sweep: hold the phone flat over the table, move it slowly in rows, and every piece is found, measured, counted once and identified. It uses the server above for recognition, the inventory and the set matching, so the server must be running on your computer.

1. Start the server so the phone can reach it: `HOST=0.0.0.0 npm start`.
2. Open `ios/BrickScan.xcodeproj` in Xcode 16 or newer.
3. Select the BrickScan target, then under Signing & Capabilities choose your team and change the bundle identifier to something unique.
4. Plug in an iPhone running iOS 17 or newer, pick it as the run destination and press Run. The camera tracking does not work in the simulator.
5. In the app's Settings tab, enter your computer's address and port (for example `192.168.1.20:3000`) and tap Test connection.

How the sweep works (`ios/BrickScan/Sources/ScanEngine.swift`):

- ARKit tracks the phone and finds the table, so each detected piece gets a real position and a size in millimetres.
- A piece seen again at the same spot is the same piece, so overlapping passes do not double-count.
- With a trained model bundled (see `ml/README.md`), each piece is recognised on the phone from up to eight viewpoints, and the result is weighed against the piece's measured size and each shape's true dimensions. The server then only supplies names, pictures and colours.
- Without a model, each piece is sent to the server for recognition from up to two viewpoints, along with its measured length so a 1 x 2 can be told from a 1 x 4.
- White balance is locked once the table is in view so colours stay consistent across the sweep.
- Frames are skipped while the phone is tilted or moving fast, because blurred or oblique views hurt accuracy.

If Xcode will not open the project file, create a new iOS App project (SwiftUI) named BrickScan, delete its generated Swift files, drag in everything from `ios/BrickScan/Sources/`, and copy the four keys from `ios/BrickScan/Info.plist` into the target's Info tab.

## Good to know

- Pieces must not touch each other, and the background needs to be a different colour from every piece on it. White pieces on white paper will be missed.
- Recognition is a best guess. Low-confidence matches are flagged and left unticked.
- Photos of your pieces are sent to Brickognize, a free third-party service. Nothing else leaves your computer.
- Brickognize uses BrickLink part numbers. Most are the same as Rebrickable's, but a piece whose number differs is reported as "no match" and has to be added by hand.
- Minifigures and spare parts are not counted towards a set.
- Your inventory lives in `data/inventory.json`.
- When the phone app sends a correction, the crop is saved under `data/corrections/<part number>/`, the layout the training scripts read.
- The plan for what comes next is in `docs/PLAN.md`.

LEGO® is a trademark of the LEGO Group, which does not sponsor or endorse this project.
