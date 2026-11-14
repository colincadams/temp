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

**Inventory.** Adjust counts, add parts by name or number, add every part of a set you own by its set number, or export a CSV (`Part,Color,Quantity`, which Rebrickable can import).

**What can I build?** Every set in the [Rebrickable](https://rebrickable.com/downloads/) catalog is ranked by how many of its pieces you have. Open a set to see exactly what is missing. Two options loosen the matching: ignore colour, and treat printed or re-moulded versions of a part as the same part.

## Good to know

- Pieces must not touch each other, and the background needs to be a different colour from every piece on it. White pieces on white paper will be missed.
- Recognition is a best guess. Low-confidence matches are flagged and left unticked.
- Photos of your pieces are sent to Brickognize, a free third-party service. Nothing else leaves your computer.
- Brickognize uses BrickLink part numbers. Most are the same as Rebrickable's, but a piece whose number differs is reported as "no match" and has to be added by hand.
- Minifigures and spare parts are not counted towards a set.
- Your inventory lives in `data/inventory.json`.

LEGO® is a trademark of the LEGO Group, which does not sponsor or endorse this project.
