# VertB2SHelper

VertB2SHelper is a Windows PowerShell utility that helps configure a DirectB2S `.res` layout for a vertically oriented backglass display.

Manually defining a B2S layout for a vertical backglass can be tedious. It requires calculating the backglass size and position, placing the FullDMD, choosing offsets and stacking order, and then transferring those values into a ScreenRes file. VertB2SHelper was created to speed up that process while preserving the original aspect ratios of the images, so the backglass and FullDMD are not stretched or squished.

The application loads the embedded images and layout information from a `.directb2s` file, provides an interactive preview, calculates the resulting positions and dimensions, and generates a matching `.res` file.

## Features

- Loads a `.directb2s` file and extracts its embedded backglass, FullDMD, and grill images.
- Preserves image aspect ratios when calculating output dimensions.
- Supports a vertical backglass monitor by allowing independent monitor width and height values.
- Lets you choose whether the visible secondary screen is a grill or a FullDMD.
- Supports top-offset and bottom-offset positioning.
- Supports either of these stacking orders when using a FullDMD:
  - Backglass top / FullDMD bottom
  - FullDMD top / backglass bottom
- Configures FullDMD width and the gap between stacked elements.
- Detects the grill height from the DirectB2S XML.
- Optionally crops an embedded grill from the backglass source image.
- Shows a preview of the calculated layout and warns when an element extends beyond the selected monitor.
- Generates an ASCII `.res` file beside the source `.directb2s` file.

## Requirements

- Windows
- Windows PowerShell 5.1 or later
- .NET Framework components that provide `System.Windows.Forms` and `System.Drawing`
- A DirectB2S `.directb2s` file containing a `BackglassImage` node

The script is intended for Windows PowerShell. It uses Windows Forms and is not intended to run on PowerShell versions or operating systems that do not provide those assemblies.

## Usage

1. Download or clone this repository.
2. Open Windows PowerShell.
3. Run the script:

   ```powershell
   .\VertB2SHelper.ps1
   ```

   You can also provide a DirectB2S file when starting the application:

   ```powershell
   .\VertB2SHelper.ps1 -FilePath "C:\Path\To\Table.directb2s"
   ```

4. If a file was not supplied on the command line, click **Browse...** and select the table's `.directb2s` file.
5. Set **Backglass Monitor Resolution** to the resolution of the monitor that will display the backglass.
6. Review the detected XML grill height. If appropriate, leave **Crop embedded grill from backglass** enabled.
7. Choose the **Visible Secondary Screen**:
   - **Grill**: treats the grill as part of the backglass image. No separate FullDMD position is written.
   - **FullDMD**: positions a separate FullDMD above or below the backglass.
8. Choose **Top Offset** or **Bottom Offset** and set the offset in pixels.
9. If FullDMD is selected, choose the stacking order, FullDMD width, and element gap.
10. Use the preview and status panel to verify the layout and check for warnings.
11. Click **Generate .res File**.

The generated file is written beside the source file with the same base name:

```text
C:\Tables\Example.directb2s
C:\Tables\Example.res
```

## Layout behavior

### Backglass scaling

The backglass is scaled to the configured monitor width. Its height is calculated from the effective source dimensions and the original image aspect ratio:

```text
backglass height = monitor width × source height ÷ source width
```

If grill cropping is enabled and a valid grill height is present in the XML, that height is removed from the effective source height before the result is calculated. This prevents the image from being compressed or distorted to fit an arbitrary rectangle.

### FullDMD scaling

When FullDMD is selected, its height is calculated from the configured FullDMD width and the embedded FullDMD image's original aspect ratio:

```text
FullDMD height = configured width × image height ÷ image width
```

The FullDMD is centered horizontally. Its vertical position is calculated using the selected offset mode, stacking order, and element gap.

### Grill selection

A grill embedded in `BackglassImage` does not have a separate ScreenRes position field. When **Grill** is selected, the tool keeps the grill within the backglass layout and does not write a FullDMD position. If grill cropping is enabled, the detected XML grill height is used to calculate the visible backglass source area.

## Generated `.res` file

The generated file contains the DirectB2S ScreenRes values for the calculated backglass and, when selected, FullDMD layout. The playfield values remain set to the standard values currently used by the script, while the backglass and FullDMD values are calculated from the application controls.

The output includes comments describing each section, making it easier to inspect or adjust manually if needed.

## Troubleshooting

### The application cannot load the backglass image

Make sure the selected file is a valid `.directb2s` file and contains a valid Base64-encoded `BackglassImage` node. The tool requires that image to calculate the layout.

### The grill height is shown as zero

The XML may not contain a `GrillHeight` node, or its value may not contain a positive pixel height. Grill cropping will have no effect until a valid grill height can be detected.

### A layout warning is shown

Warnings indicate that the calculated backglass or FullDMD extends beyond the configured monitor boundaries. Try adjusting the monitor resolution, offset, stacking order, FullDMD width, or element gap.

### The generated layout does not match the physical display

Verify that the configured monitor dimensions match the actual display resolution and that the generated `.res` file is being used by the correct DirectB2S table.

## License

No license has been specified for this repository yet.
