# CC0 photographic test sources

These four photographs are part of the encode corpus (see `PROGRESS.MD`, the
`src/testing/encode_corpus.zig` test, and the `zig build encode-report` tool).
They supply clean photographic source pixels for the lossless size measurement
and for the VP8 lossy encoder's PSNR work (`PLAN.MD` step 8).

All four are released under the **Creative Commons CC0 1.0 Universal Public
Domain Dedication**, confirmed on each Wikimedia Commons file page and via the
MediaWiki `extmetadata` API (`License: cc0`). CC0 places the work in the public
domain, so the files are safe to redistribute in this repository.

## Processing

Each original was downscaled to a 512 px longest side and re-encoded with
`cwebp -lossless -metadata none` (libwebp 1.5.0). The committed `.webp` therefore
stores the exact pixels this library's decoder reproduces — no metadata, no
alpha. The committed file is the artifact; regeneration is not required.

## Sources

| Committed file | Content | Source dimensions | Author | Commons file page |
|---|---|---|---|---|
| `photo_portrait.webp` | B&W portrait, single face | 1499×2246 | Hunter S. Thompson | [File:Hunter_S._Thompson_(self-portrait_photograph_-_Hell's_Angels_author_photo).jpg](https://commons.wikimedia.org/wiki/File:Hunter_S._Thompson_(self-portrait_photograph_-_Hell's_Angels_author_photo).jpg) |
| `photo_foliage.webp` | Yellow flower macro | 6000×4000 | Rodion Kutsaev | [File:Yellow_flower_in_macro_(Unsplash).jpg](https://commons.wikimedia.org/wiki/File:Yellow_flower_in_macro_(Unsplash).jpg) |
| `photo_signage.webp` | Neon restaurant sign (text/edges) | 7360×4912 | Julian Lupyan | [File:Maximilien_Restaurant_Sign_in_Pike_Place_Market,_Seattle,_Washington,_2025.jpg](https://commons.wikimedia.org/wiki/File:Maximilien_Restaurant_Sign_in_Pike_Place_Market,_Seattle,_Washington,_2025.jpg) |
| `photo_sky.webp` | Orange/blue sunset, gradients | 2560×1920 | Sugar Bee | [File:Orange_and_blue_sunset_(Unsplash).jpg](https://commons.wikimedia.org/wiki/File:Orange_and_blue_sunset_(Unsplash).jpg) |

Direct media URLs fetched from `upload.wikimedia.org`:

- portrait — `https://upload.wikimedia.org/wikipedia/commons/7/71/Hunter_S._Thompson_%28self-portrait_photograph_-_Hell%27s_Angels_author_photo%29.jpg`
- foliage — `https://upload.wikimedia.org/wikipedia/commons/b/bc/Yellow_flower_in_macro_%28Unsplash%29.jpg`
- signage — `https://upload.wikimedia.org/wikipedia/commons/3/35/Maximilien_Restaurant_Sign_in_Pike_Place_Market%2C_Seattle%2C_Washington%2C_2025.jpg`
- sky — `https://upload.wikimedia.org/wikipedia/commons/2/2e/Orange_and_blue_sunset_%28Unsplash%29.jpg`

## Notes

- The foliage and sunset images originate from Unsplash uploads made before
  June 2017, when Unsplash dedicated content under genuine CC0; their Commons
  file pages carry explicit CC0 tags rather than the later Unsplash License.
- Content was chosen for codec diversity: a face, organic high-detail texture,
  high-frequency text/signage, and a smooth tonal gradient.
