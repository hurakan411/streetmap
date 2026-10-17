# Reference paper edge material

Generated with the built-in image_gen tool from the user-selected warm-gray torn-paper reference. Source: `exec-f799deeb-48ba-46c8-8396-abc5c919791f.png`. App asset: `Michi/Resources/Assets.xcassets/TornPaperEdge.imageset/torn-edge-v1.png`.

Prompt brief: photoreal warm-gray (#CDC9C2) paper occupying the upper half of a landscape RGBA texture, a nearly horizontal irregular tear through the middle, fine exposed white fibres, five or six selective tapered folded-back tabs, narrow dark occlusion beneath the raised lips, and soft semitransparent cast shadows fading into the transparent lower half. Diffuse upper-left light, subtle short surface fibres, no map, phone, UI, backdrop, text, plaster, thick cardboard, uniform bevel, or giant paper rolls.

The app samples this material around a route-derived contour. It is not a fixed hole or a generated map. Normal-dependent blending changes the ribbon direction and shadow strength; the upper paper surface is sampled from the same asset and tint-matched to the template. The whole source remains in the asset catalog with its original alpha.

## Exact generation prompt

Use case: product-mockup. Produce a production-ready RGBA TEXTURE ASSET of a real torn paper edge for a map app. The input image is a MATERIAL STYLE REFERENCE ONLY: match the warm gray tactile thin paper, subtle short fibers, white exposed paper core, selectively curled flaps, and shadows of the reference. DO NOT include any phone, map, text, symbols, UI or scene.

Composition: a wide landscape flat-lay image, ideally 2048 by 1024. A single continuous warm gray sheet fills the entire upper half and runs all the way off the top, left and right image boundaries. Its torn bottom edge travels horizontally across the exact vertical middle of the image, varying gently up/down no more than 35 pixels. Below the torn edge the canvas is truly TRANSPARENT. The lower 35% must be completely transparent. No white or gray backdrop, no checkerboard printed into the image.

Paper top: soft warm gray #CDC9C2, very fine quiet natural short fibers, matte uncoated paper. No dramatic uneven lighting over the sheet.

Edge design: very realistic irregular hand-torn edge, narrow whitish delaminated fibers at the break, several small pointed paper tabs folded BACK UP onto the sheet, and occasional tiny outward lifted lip. At 5 or 6 non-repeating positions across the width, a flap lifts and reveals the pale paper back. The folds have asymmetric triangular or tapered shapes, with an actual visible overlap, dark narrow occlusion UNDER the lip, a lit pale curled face, and a soft cast shadow onto the transparent region below the paper or onto the sheet under a folded tab. Most of the edge remains thin and only gently raised. Layered fibers, ragged small notches, but NO chunky stone, plaster, cardboard, foam, big accordion rolls, scalloped ribbon, or uniform white beveled outline.

Lighting: diffuse daylight from upper-left; underside just below raised lips is dark, cast shadow softens and fades into transparent alpha below; top faces remain light. Include physically plausible SEMI-TRANSPARENT shadow pixels along the torn edge, not an opaque gray background. Keep the vertical footprint of curls and shadows compact, within approximately 100 pixels of the central boundary. The edge is almost straight overall so this can be used as a ribbon texture. Photoreal macro material, no watermarks.
