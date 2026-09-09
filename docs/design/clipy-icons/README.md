# Clipy icon design master

Generated with the built-in `image_gen` tool on 2026-09-09. The selected
`clipy-blue-white-master.png` is the 1254 × 1254 opaque design master.
The user explicitly authorized ImageMagick for final transparent-edge cleanup
and AppIcon preparation after generated alpha had artifacts.

`clipy-appicon.png` is the finished 1024 × 1024 RGBA asset. The source's blue
perimeter supplies its mask: blue-minus-red > 0.04, a two-pixel close, exterior
flood fill, one-pixel erosion and 0.65-pixel edge antialiasing. This removes
only the surrounding gray canvas and preserves the generated artwork.
Lanczos reductions populate all ten macOS AppIcon slots (seven unique raster
sizes, 16 through 1024 px) in the app's asset catalog.

`size-review.png` displays 16, 32, 64, 128 and 256 px at actual pixel size on
light and dark backgrounds. Visual inspection found clean boundaries. The
1024 px alpha has one connected opaque silhouette, transparent corners, and
no detached components at its 50% contour. Asset dimensions match every slot.
This is a static macOS AppIcon, not an Icon Composer multilayer file. Actual
Dock/Finder rendering still requires macOS verification.

The direction follows the user's request for a cohesive contemporary Apple
appearance: simplified blue/pearl clipboard, shallow layers and restrained
highlights. Earlier heavy-metal and inflated-glass variants were discarded.

## Generation prompt

Use case: logo-brand. Generate one original, expertly designed macOS clipboard utility app icon for Clipy, visually harmonious with Apple's current Liquid Glass design language. Single finished icon only, square 1024x1024 canvas. Dramatically simplify the previous heavy literal metal clipboard concept: two crisp overlapping rounded rectangular sheets, the front sheet luminous pearl white, the back sheet saturated but restrained Apple-like azure blue, and a small simple rounded translucent blue clip centered on top. Straight-on orthographic view. Three clear large shapes, broad flat surfaces, extremely shallow layered depth, precise soft edge highlights, restrained soft refraction at edges only. Front sheet has absolutely no text, lines or symbols. Elegant slightly translucent frosted rounded-square base, neutral cool white with subtle clean light gradient. Visually lightweight like a contemporary first-party Mac utility; not a photograph, not a toy, no brushed metal, no paper texture, no cartoon. A compact distinct silhouette that reads well at 16 pixels. Generous optical breathing room: rounded-square tile occupies centered 82 percent of the canvas, clean truly transparent outside the tile. Absolutely pristine antialiased boundary with no stray white specks, no wispy alpha artifacts, no outside shadow. No text, letters, watermark, decorative sparkles, extra objects or multiple icon variants. High contrast between clipboard silhouette and base without loud colors or rainbow effects.

## Selected refinement prompt

Edit the most recent blue and pearl Clipy icon into a cleaner, more coherent contemporary Apple macOS utility icon. Keep the same single clipboard motif, the blue rear sheet, pearl front sheet, and compact blue clip. Preserve overall geometry. Reduce the puffy inflation and shiny lens effects by about 70 percent: nearly flat broad surfaces, very thin translucent layered edges, subtle soft light, restrained cool-blue palette. Crucially remove the frothy irregular outer edges and all stray specks. For this design master, use a perfectly opaque solid very light neutral gray full-square background, NOT transparency. The rounded-square icon base and its clean smooth boundary sit centered in this gray canvas with about 10 percent margin; no external drop shadow. The gray background must be perfectly uniform and artifact-free. Sharpen the three large foreground shapes for excellent small-size legibility. No textures, no metal, no paper fibers, no internal writing or marks, no letters or text, no watermarks, no multi-icon sheet. One finished square icon, precise, harmonious, quiet, high-end.

Final artwork processing uses the selected master above, not the rejected
generated alpha variants. The blue-perimeter mask and resolution conversion
were performed locally with ImageMagick after explicit user approval.
