// Generates sized WebP variants of the local token/stock icons so a 16–48px slot does not
// download the 128px PNG. Re-run after adding an icon:  node scripts/generate-icon-variants.mjs
// Output: public/<dir>/w<size>/<name>.webp for each size in ICON_VARIANT_WIDTHS.
import fs from "node:fs"
import path from "node:path"
import sharp from "sharp"

export const ICON_VARIANT_DIRS = ["public/asset-icons", "public/stock-Icons"]
export const ICON_VARIANT_WIDTHS = [64, 96, 128]

for (const dir of ICON_VARIANT_DIRS) {
  const sources = fs.readdirSync(dir).filter((file) => file.endsWith(".png"))
  for (const width of ICON_VARIANT_WIDTHS) {
    const outDir = path.join(dir, `w${width}`)
    fs.mkdirSync(outDir, { recursive: true })
    for (const file of sources) {
      await sharp(path.join(dir, file))
        .resize(width, width, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
        .webp({ quality: 90 })
        .toFile(path.join(outDir, file.replace(/\.png$/, ".webp")))
    }
  }
  console.log(`${dir}: ${sources.length} icons × ${ICON_VARIANT_WIDTHS.length} sizes`)
}
