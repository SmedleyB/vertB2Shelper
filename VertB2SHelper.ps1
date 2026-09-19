[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$FilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:State = [ordered]@{
    XmlPath       = ''
    Backglass     = $null
    Dmd           = $null
    Grill         = $null
    GrillHeight   = 0
    CalculatedRes = $null
}

function Dispose-Image {
    param([System.Drawing.Image]$Image)
    if ($null -ne $Image) { $Image.Dispose() }
}

function Clear-LoadedImages {
    Dispose-Image $script:State.Backglass
    Dispose-Image $script:State.Dmd
    Dispose-Image $script:State.Grill
    $script:State.Backglass = $null
    $script:State.Dmd = $null
    $script:State.Grill = $null
}

function Get-NodeText {
    param([System.Xml.XmlNode]$Node)
    if ($null -eq $Node) { return $null }

    foreach ($propertyName in @('Image', 'Content', 'Value', 'InnerText')) {
        $property = $Node.PSObject.Properties[$propertyName]
        if ($null -eq $property) { continue }
        $value = [string]$property.Value
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return $null
}

function Get-Base64ImageText {
    param([System.Xml.XmlNodeList]$Nodes)
    if ($null -eq $Nodes) { return $null }

    foreach ($node in $Nodes) {
        $candidate = Get-NodeText $node
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            [Convert]::FromBase64String(($candidate -replace '\s+', '')) | Out-Null
            return $candidate
        }
        catch [FormatException] { }
    }
    return $null
}

function Convert-Base64ToBitmap {
    param([string]$Base64Text)
    if ([string]::IsNullOrWhiteSpace($Base64Text)) { return $null }

    $bytes = [Convert]::FromBase64String(($Base64Text -replace '\s+', ''))
    $stream = [System.IO.MemoryStream]::new($bytes)
    $image = $null
    try {
        $image = [System.Drawing.Image]::FromStream($stream)
        return [System.Drawing.Bitmap]::new($image)
    }
    finally {
        if ($null -ne $image) { $image.Dispose() }
        $stream.Dispose()
    }
}

function Get-XmlNodeValue {
    param([System.Xml.XmlNode]$Node)
    if ($null -eq $Node) { return $null }

    foreach ($attributeName in @('Value', 'Height', 'Pixels', 'Size')) {
        $attribute = $Node.Attributes[$attributeName]
        if ($null -ne $attribute -and -not [string]::IsNullOrWhiteSpace($attribute.Value)) {
            return $attribute.Value.Trim()
        }
    }

    foreach ($propertyName in @('Value', 'InnerText', 'Image', 'Content')) {
        $property = $Node.PSObject.Properties[$propertyName]
        if ($null -eq $property) { continue }
        $value = [string]$property.Value
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    return $null
}

function Get-GrillHeight {
    param([System.Xml.XmlDocument]$Xml)

    foreach ($node in $Xml.SelectNodes('//*[local-name()="GrillHeight"]')) {
        $text = Get-XmlNodeValue $node
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $match = [regex]::Match($text, '\d+')
        if ($match.Success) {
            $height = 0
            if ([int]::TryParse($match.Value, [ref]$height) -and $height -gt 0) {
                return $height
            }
        }
    }
    return 0
}

function Get-Layout {
    param(
        [int]$MonitorWidth,
        [int]$MonitorHeight,
        [System.Drawing.Image]$Backglass,
        [System.Drawing.Image]$Secondary,
        [int]$GrillHeight,
        [bool]$CropGrill,
        [int]$SecondaryWidth,
        [int]$Gap,
        [int]$Offset,
        [string]$OffsetMode,
        [string]$Order,
        [bool]$SecondaryIsGrill
    )

    if ($null -eq $Backglass) { return $null }

    $sourceWidth = $Backglass.Width
    $sourceHeight = $Backglass.Height
    $cropped = $CropGrill -and -not $SecondaryIsGrill -and $GrillHeight -gt 0

    if ($cropped) {
        if ($GrillHeight -ge $sourceHeight) {
            throw "The XML grill height ($GrillHeight px) is not smaller than the backglass height ($sourceHeight px)."
        }
        $sourceHeight -= $GrillHeight
    }

    $backglassWidth = $MonitorWidth
    $backglassHeight = [math]::Max(1, [int][math]::Round($backglassWidth * $sourceHeight / $sourceWidth))

    if ($null -ne $Secondary) {
        $secondaryHeight = [math]::Max(1, [int][math]::Round($SecondaryWidth * $Secondary.Height / $Secondary.Width))
    }
    else {
        $secondaryHeight = 360
    }

    $backglassX = 0
    $secondaryX = [int][math]::Round(($MonitorWidth - $SecondaryWidth) / 2)

    if ($SecondaryIsGrill) {
        if ($OffsetMode -eq 'Top Offset') {
            $backglassY = $Offset
        }
        else {
            $backglassY = $MonitorHeight - $Offset - $backglassHeight
        }
        $secondaryY = $backglassY + $backglassHeight
    }
    else {
        $stackHeight = $backglassHeight + $Gap + $secondaryHeight
        if ($OffsetMode -eq 'Top Offset') {
            $stackTop = $Offset
        }
        else {
            $stackTop = $MonitorHeight - $Offset - $stackHeight
        }

        if ($Order -eq 'Backglass Top / FullDMD Bottom') {
            $backglassY = $stackTop
            $secondaryY = $backglassY + $backglassHeight + $Gap
        }
        else {
            $secondaryY = $stackTop
            $backglassY = $secondaryY + $secondaryHeight + $Gap
        }
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($backglassY -lt 0 -or ($backglassY + $backglassHeight) -gt $MonitorHeight) {
        [void]$warnings.Add('Backglass extends outside the selected monitor.')
    }
    if (-not $SecondaryIsGrill -and ($secondaryX -lt 0 -or ($secondaryX + $SecondaryWidth) -gt $MonitorWidth)) {
        [void]$warnings.Add('FullDMD extends outside the selected monitor horizontally.')
    }
    if (-not $SecondaryIsGrill -and ($secondaryY -lt 0 -or ($secondaryY + $secondaryHeight) -gt $MonitorHeight)) {
        [void]$warnings.Add('FullDMD extends outside the selected monitor vertically.')
    }

    return [pscustomobject]@{
        MonitorWidth       = $MonitorWidth
        MonitorHeight      = $MonitorHeight
        SourceWidth        = $sourceWidth
        SourceHeight       = $sourceHeight
        GrillCropped       = $cropped
        SecondaryIsGrill   = $SecondaryIsGrill
        BackglassX         = $backglassX
        BackglassY         = $backglassY
        BackglassWidth     = $backglassWidth
        BackglassHeight    = $backglassHeight
        SecondaryX         = $secondaryX
        SecondaryY         = $secondaryY
        SecondaryWidth     = $SecondaryWidth
        SecondaryHeight    = $secondaryHeight
        Warnings           = @($warnings)
    }
}

function Get-ResContent {
    param([pscustomobject]$Layout)

    $dmdWidth = 0
    $dmdHeight = 0
    $dmdX = 0
    $dmdY = 0

    if (-not $Layout.SecondaryIsGrill) {
        $dmdWidth = $Layout.SecondaryWidth
        $dmdHeight = $Layout.SecondaryHeight
        $dmdX = $Layout.SecondaryX
        $dmdY = $Layout.SecondaryY - $Layout.BackglassY
    }

    @(
        '# DirectB2S ScreenRes (.res) generated by VertB2SHelper'
        '#'
        '# Playfield: width, height'
        '2560'
        '1440'
        '# Backglass: width, height'
        $Layout.BackglassWidth
        $Layout.BackglassHeight
        '# Define Backglass screen using Display Devicename screen number (\\.\DISPLAY)x or screen coordinates (@x) or screen index (=x)'
        '2'
        '# Backglass x/y position relative to the upper left corner of the screen selected'
        $Layout.BackglassX
        $Layout.BackglassY
        '# FullDMD: width, height'
        $dmdWidth
        $dmdHeight
        '# FullDMD position: X, Y (relative to the upper left corner of the backglass window)'
        $dmdX
        $dmdY
        '# Y-flip, flips the LED display upside down'
        '0'
        '# Background x/y position - relative to the backglass screen - has to be activated in the settings'
        '0'
        '0'
        '# Background image size: width, height'
        '0'
        '0'
        '# path to the background image (C:\path\Frame) or black if none selected'
        '#D:\images\image.jpg'
	'# This line would turn off B2SWindowPunch if activated'
	'#B2SWindowPunch=off'
    ) -join [Environment]::NewLine
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'DirectB2S .res Layout Generator & Preview'
$form.ClientSize = [System.Drawing.Size]::new(920, 820)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

$panelControls = [System.Windows.Forms.Panel]::new()
$panelControls.Size = [System.Drawing.Size]::new(380, 780)
$panelControls.Location = [System.Drawing.Point]::new(10, 10)
[void]$form.Controls.Add($panelControls)

function Add-Label {
    param([string]$Text, [int]$Top, [bool]$Bold = $false)
    $label = [System.Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Location = [System.Drawing.Point]::new(10, $Top)
    $label.AutoSize = $true
    if ($Bold) { $label.Font = [System.Drawing.Font]::new($label.Font, [System.Drawing.FontStyle]::Bold) }
    [void]$panelControls.Controls.Add($label)
    return $label
}

function Add-NumberControl {
    param(
        [int]$Top,
        [int]$Minimum = 0,
        [int]$Maximum = 7680,
        [int]$Value = 0,
        [int]$Left = 150
    )

    $number = [System.Windows.Forms.NumericUpDown]::new()
    $number.Minimum = $Minimum
    $number.Maximum = $Maximum
    $number.Value = $Value
    $number.Location = [System.Drawing.Point]::new($Left, $Top - 3)
    $number.Size = [System.Drawing.Size]::new(100, 23)
    [void]$panelControls.Controls.Add($number)
    return $number
}

function Add-ComboControl {
    param(
        [object[]]$Items,
        [int]$Top,
        [int]$Left = 150
    )

    $combo = [System.Windows.Forms.ComboBox]::new()
    [void]$combo.Items.AddRange($Items)
    $combo.SelectedIndex = 0
    $combo.DropDownStyle = 'DropDownList'
    $combo.Location = [System.Drawing.Point]::new($Left, $Top - 3)
    $combo.Size = [System.Drawing.Size]::new(200, 23)
    [void]$panelControls.Controls.Add($combo)
    return $combo
}

$y = 10
[void](Add-Label 'Select .directb2s File:' $y)
$y += 22
$txtFile = [System.Windows.Forms.TextBox]::new()
$txtFile.Location = [System.Drawing.Point]::new(10, $y)
$txtFile.Size = [System.Drawing.Size]::new(270, 23)
$txtFile.ReadOnly = $true
[void]$panelControls.Controls.Add($txtFile)
$btnBrowse = [System.Windows.Forms.Button]::new()
$btnBrowse.Text = 'Browse...'
$btnBrowse.Location = [System.Drawing.Point]::new(285, $y - 1)
$btnBrowse.Size = [System.Drawing.Size]::new(75, 25)
[void]$panelControls.Controls.Add($btnBrowse)
$y += 35

$separator = [System.Windows.Forms.Label]::new()
$separator.BorderStyle = 'Fixed3D'
$separator.Size = [System.Drawing.Size]::new(350, 2)
$separator.Location = [System.Drawing.Point]::new(10, $y)
[void]$panelControls.Controls.Add($separator)
$y += 15

[void](Add-Label 'Backglass Monitor Resolution (W x H):' $y $true)
$y += 25
$numMonW = Add-NumberControl -Top $y -Minimum 500 -Maximum 7680 -Value 1440 -Left 10
$lblX = Add-Label 'x' ($y + 3)
$lblX.Location = [System.Drawing.Point]::new(118, $y + 3)
$numMonH = Add-NumberControl -Top $y -Minimum 500 -Maximum 7680 -Value 2560 -Left 135

$y += 35
$lblGrillInfo = Add-Label 'XML Grill Height: 0 px' $y $true
$y += 22
$chkCutGrill = [System.Windows.Forms.CheckBox]::new()
$chkCutGrill.Text = 'Crop embedded grill from backglass'
$chkCutGrill.Location = [System.Drawing.Point]::new(10, $y)
$chkCutGrill.AutoSize = $true
$chkCutGrill.Enabled = $false
[void]$panelControls.Controls.Add($chkCutGrill)

$y += 35
[void](Add-Label 'Visible Secondary Screen:' $y $true)
$cmbType = Add-ComboControl -Items @('Grill', 'FullDMD') -Top $y
$y += 30
[void](Add-Label 'Offset Mode:' $y)
$cmbOffsetMode = Add-ComboControl -Items @('Top Offset', 'Bottom Offset') -Top $y
$y += 30
[void](Add-Label 'Offset (px):' $y)
$numOffset = Add-NumberControl -Top $y -Minimum 0 -Maximum 7680 -Value 25 -Left 150
$y += 30
[void](Add-Label 'Vertical Stacking Order:' $y)
$cmbOrder = Add-ComboControl -Items @('Backglass Top / FullDMD Bottom', 'FullDMD Top / Backglass Bottom') -Top $y
$y += 30
[void](Add-Label 'FullDMD Width (px):' $y)
$numDmdW = Add-NumberControl -Top $y -Minimum 100 -Maximum 3840 -Value 1280 -Left 150
$y += 30
[void](Add-Label 'Element Gap (px):' $y)
$numGap = Add-NumberControl -Top $y -Minimum 0 -Maximum 500 -Value 25 -Left 150

$y += 40
$btnSave = [System.Windows.Forms.Button]::new()
$btnSave.Text = 'Generate .res File'
$btnSave.Font = [System.Drawing.Font]::new($btnSave.Font, [System.Drawing.FontStyle]::Bold)
$btnSave.Size = [System.Drawing.Size]::new(350, 40)
$btnSave.Location = [System.Drawing.Point]::new(10, $y)
$btnSave.BackColor = [System.Drawing.Color]::LightGreen
$btnSave.Enabled = $false
[void]$panelControls.Controls.Add($btnSave)

$y += 50
$txtStatus = [System.Windows.Forms.TextBox]::new()
$txtStatus.Multiline = $true
$txtStatus.ReadOnly = $true
$txtStatus.ScrollBars = 'Vertical'
$txtStatus.Size = [System.Drawing.Size]::new(350, 200)
$txtStatus.Location = [System.Drawing.Point]::new(10, $y)
[void]$panelControls.Controls.Add($txtStatus)

$picPreview = [System.Windows.Forms.PictureBox]::new()
$picPreview.Size = [System.Drawing.Size]::new(480, 780)
$picPreview.Location = [System.Drawing.Point]::new(400, 10)
$picPreview.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$picPreview.BorderStyle = 'FixedSingle'
$picPreview.SizeMode = 'Normal'
[void]$form.Controls.Add($picPreview)

function Update-Preview {
    if ($null -eq $script:State.Backglass) { return }
    if ($null -eq $cmbType.SelectedItem -or $null -eq $cmbOffsetMode.SelectedItem -or $null -eq $cmbOrder.SelectedItem) { return }

    $secondaryIsGrill = ([string]$cmbType.SelectedItem -eq 'Grill')
    $activeBitmap = if ($secondaryIsGrill) { $null } else { $script:State.Dmd }

    try {
        $layout = Get-Layout -MonitorWidth ([int]$numMonW.Value) -MonitorHeight ([int]$numMonH.Value) `
            -Backglass $script:State.Backglass -Secondary $activeBitmap `
            -GrillHeight $script:State.GrillHeight -CropGrill $chkCutGrill.Checked `
            -SecondaryWidth ([int]$numDmdW.Value) -Gap ([int]$numGap.Value) `
            -Offset ([int]$numOffset.Value) -OffsetMode ([string]$cmbOffsetMode.SelectedItem) `
            -Order ([string]$cmbOrder.SelectedItem) -SecondaryIsGrill $secondaryIsGrill
    }
    catch {
        $txtStatus.Text = "Layout error:`r`n$($_.Exception.Message)"
        return
    }

    $script:State.CalculatedRes = $layout

    $warningText = if ($layout.Warnings.Count -gt 0) { "`r`nWARNINGS:`r`n - " + ($layout.Warnings -join "`r`n - ") } else { '' }
    $cropNote = if ($script:State.GrillHeight -gt 0) {
        "Crop checkbox is available; XML grill height is $($script:State.GrillHeight) px."
    }
    else {
        'No XML grill height was found; cropping has no effect for this file.'
    }

    $txtStatus.Text = @"
LAYOUT SETTINGS:
Offset Mode: $($cmbOffsetMode.SelectedItem)
Offset: $([int]$numOffset.Value) px
Order: $($cmbOrder.SelectedItem)
Element Gap: $([int]$numGap.Value) px
Visible Secondary Screen: $($cmbType.SelectedItem)
$cropNote

BACKGLASS RESULT:
Original Image: $($script:State.Backglass.Width)x$($script:State.Backglass.Height) px
Effective Source: $($layout.SourceWidth)x$($layout.SourceHeight) px
Grill Cropped: $($layout.GrillCropped)
Render Output: $($layout.BackglassWidth)x$($layout.BackglassHeight) px at ($($layout.BackglassX),$($layout.BackglassY))

$($cmbType.SelectedItem) PREVIEW:
Render Output: $($layout.SecondaryWidth)x$($layout.SecondaryHeight) px at ($($layout.SecondaryX),$($layout.SecondaryY))

Grill is embedded in the backglass image and does not have a separate ScreenRes position field.$warningText
"@

    $canvasWidth = $picPreview.ClientSize.Width
    $canvasHeight = $picPreview.ClientSize.Height
    $bitmap = [System.Drawing.Bitmap]::new($canvasWidth, $canvasHeight)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(30, 30, 30))
        $scale = [math]::Min(($canvasWidth - 40) / $layout.MonitorWidth, ($canvasHeight - 40) / $layout.MonitorHeight)
        $drawMonitorWidth = [int][math]::Round($layout.MonitorWidth * $scale)
        $drawMonitorHeight = [int][math]::Round($layout.MonitorHeight * $scale)
        $originX = [int][math]::Round(($canvasWidth - $drawMonitorWidth) / 2)
        $originY = [int][math]::Round(($canvasHeight - $drawMonitorHeight) / 2)
        $monitorRect = [System.Drawing.Rectangle]::new($originX, $originY, $drawMonitorWidth, $drawMonitorHeight)
        $graphics.FillRectangle([System.Drawing.Brushes]::Black, $monitorRect)
        $graphics.DrawRectangle([System.Drawing.Pens]::Cyan, $monitorRect)

        $drawBgX = $originX + [int][math]::Round($layout.BackglassX * $scale)
        $drawBgY = $originY + [int][math]::Round($layout.BackglassY * $scale)
        $drawBgW = [int][math]::Round($layout.BackglassWidth * $scale)
        $drawBgH = [int][math]::Round($layout.BackglassHeight * $scale)
        $sourceRect = [System.Drawing.Rectangle]::new(0, 0, $layout.SourceWidth, $layout.SourceHeight)
        $destinationRect = [System.Drawing.Rectangle]::new($drawBgX, $drawBgY, $drawBgW, $drawBgH)
        $graphics.DrawImage($script:State.Backglass, $destinationRect, $sourceRect, [System.Drawing.GraphicsUnit]::Pixel)
        $graphics.DrawRectangle([System.Drawing.Pens]::Yellow, $destinationRect)

        if (-not $secondaryIsGrill) {
            $drawSecondaryX = $originX + [int][math]::Round($layout.SecondaryX * $scale)
            $drawSecondaryY = $originY + [int][math]::Round($layout.SecondaryY * $scale)
            $drawSecondaryW = [int][math]::Round($layout.SecondaryWidth * $scale)
            $drawSecondaryH = [int][math]::Round($layout.SecondaryHeight * $scale)
            $secondaryRect = [System.Drawing.Rectangle]::new($drawSecondaryX, $drawSecondaryY, $drawSecondaryW, $drawSecondaryH)
            if ($null -ne $activeBitmap) {
                $graphics.DrawImage($activeBitmap, $secondaryRect)
            }
            else {
                $graphics.FillRectangle([System.Drawing.Brushes]::DarkGray, $secondaryRect)
                $graphics.DrawString('No FullDMD Found', [System.Drawing.SystemFonts]::DefaultFont, [System.Drawing.Brushes]::White, $drawSecondaryX + 5, $drawSecondaryY + 5)
            }
            $graphics.DrawRectangle([System.Drawing.Pens]::OrangeRed, $secondaryRect)
        }
        else {
            $grillLabel = 'Grill is embedded in BackglassImage and has no separate ScreenRes position.'
            $graphics.DrawString($grillLabel, [System.Drawing.SystemFonts]::DefaultFont, [System.Drawing.Brushes]::White, $originX + 12, $originY + 12)
        }
    }
    finally {
        $graphics.Dispose()
    }

    $oldImage = $picPreview.Image
    $picPreview.Image = $bitmap
    Dispose-Image $oldImage
}

function Load-DirectB2SFile {
    param([string]$TargetPath)
    if ([string]::IsNullOrWhiteSpace($TargetPath) -or -not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { return }

    try {
        $xml = [xml](Get-Content -LiteralPath $TargetPath -Raw -ErrorAction Stop)
        Clear-LoadedImages
        $script:State.XmlPath = $TargetPath
        $txtFile.Text = [System.IO.Path]::GetFileName($TargetPath)
        $script:State.GrillHeight = Get-GrillHeight $xml

        $txtStatus.Text = 'Loading backglass image...'; $txtStatus.Refresh(); [System.Windows.Forms.Application]::DoEvents()
        $script:State.Backglass = Convert-Base64ToBitmap (Get-Base64ImageText $xml.SelectNodes('//*[local-name()="BackglassImage"]'))
        if ($null -eq $script:State.Backglass) { throw 'Could not locate valid Base64 data in a BackglassImage node.' }

        $txtStatus.Text = 'Loading DMD image...'; $txtStatus.Refresh(); [System.Windows.Forms.Application]::DoEvents()
        $script:State.Dmd = Convert-Base64ToBitmap (Get-Base64ImageText $xml.SelectNodes('//*[local-name()="DMDImage"]'))

        $txtStatus.Text = 'Loading grill image...'; $txtStatus.Refresh(); [System.Windows.Forms.Application]::DoEvents()
        $script:State.Grill = Convert-Base64ToBitmap (Get-Base64ImageText $xml.SelectNodes('//*[local-name()="GrillImage"]'))

        if ($script:State.GrillHeight -gt 0) {
            $lblGrillInfo.Text = "XML Grill Height: $($script:State.GrillHeight) px"
            $chkCutGrill.Checked = $true
        }
        else {
            $lblGrillInfo.Text = 'XML Grill Height: 0 px (not specified)'
            $chkCutGrill.Checked = $false
        }

        $chkCutGrill.Enabled = $true
        $btnSave.Enabled = $true
        Update-Preview
    }
    catch {
        Clear-LoadedImages
        $btnSave.Enabled = $false
        $chkCutGrill.Enabled = $false
        $txtStatus.Text = "Error reading .directb2s file:`r`n$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Error reading .directb2s file:`r`n$($_.Exception.Message)", 'File Load Error', 'OK', 'Error') | Out-Null
    }
}

$btnBrowse.Add_Click({
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Filter = 'DirectB2S Files (*.directb2s)|*.directb2s|All files (*.*)|*.*'
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Load-DirectB2SFile $dialog.FileName
        }
    }
    finally {
        $dialog.Dispose()
    }
})

$btnSave.Add_Click({
    if ($null -eq $script:State.CalculatedRes -or [string]::IsNullOrWhiteSpace($script:State.XmlPath)) { return }
    try {
        $resPath = [System.IO.Path]::ChangeExtension($script:State.XmlPath, '.res')
        Set-Content -LiteralPath $resPath -Value (Get-ResContent $script:State.CalculatedRes) -Encoding ASCII
        [System.Windows.Forms.MessageBox]::Show(".res file generated successfully at:`r`n$resPath", 'Success', 'OK', 'Information') | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Could not write the .res file:`r`n$($_.Exception.Message)", 'Save Error', 'OK', 'Error') | Out-Null
    }
})

$renderControls = @($numMonW, $numMonH, $numDmdW, $numOffset, $numGap)
foreach ($control in $renderControls) { $control.Add_ValueChanged({ Update-Preview }) }
$cmbOrder.Add_SelectedIndexChanged({ Update-Preview })
$cmbType.Add_SelectedIndexChanged({ Update-Preview })
$cmbOffsetMode.Add_SelectedIndexChanged({ Update-Preview })
$chkCutGrill.Add_CheckedChanged({ Update-Preview })

$form.Add_FormClosed({
    Clear-LoadedImages
    Dispose-Image $picPreview.Image
    $picPreview.Image = $null
})

if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
    $form.Add_Shown({ Load-DirectB2SFile $FilePath })
}

[void]$form.ShowDialog()
