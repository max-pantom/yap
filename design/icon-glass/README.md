# Liquid Glass app icon

Layers for Apple's Icon Composer, from the Paper designs (`paper/`):

| File | Use |
|---|---|
| `mark-black.svg` | The mark layer (1024 canvas, mark at 62.5%, clipped to the ball) |
| `mark-white.svg` | Same mark in white, if you prefer a separate dark-mode layer |
| `icon-light.png`, `icon-dark.png`, `icon-yellow.png` | Static renders of the three Paper designs (light is the current app icon) |

## Make the .icon (about 2 minutes)

1. Open **Icon Composer** (comes with Xcode 26).
2. Drag `mark-black.svg` onto the canvas.
3. Select the canvas background. Fill **Default** `#EDEDED`, **Dark** `#000000`.
   (Or yellow `#FFFF00` for Default if you want the bold version.)
4. Select the mark layer. Turn on **Liquid Glass**. In the **Dark** appearance, set its fill to white.
5. Check the Default, Dark, Clear and Tinted previews.
6. Save as `AppIcon.icon` into `Resources/` of this repo.

Then `./build.sh --install` compiles it automatically when Xcode 26 is installed.
