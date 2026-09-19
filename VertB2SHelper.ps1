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
    foreach ($property in @('Image', 'Content', 'Value', 'InnerText')) {
        $propertyInfo = $Node.PSObject.Properties[$property]
        if ($null -eq $propertyInfo) { continue }
        $value = [string]$propertyInfo.Value
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
        [int]$TopOffset,
        [int]$BottomOffset,
        [string]$Order,
        [bool]$SecondaryIsGrill
    )

    if ($null -eq $Backglass) { return $null }

    $sourceWidth = $Backglass.Width
    $sourceHeight = $Backglass.Height
    $cropped = $CropGrill -and $GrillHeight -gt 0

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
        # B2SServer does not read a separate grill position from .res. The
        # grill is always immediately below the backglass. Therefore a bottom
        # offset is measured from the bottom of the grill, not the backglass.
        if ($TopOffset -gt 0) {
            $backglassY = $TopOffset
        }
        else {
            $backglassY = $MonitorHeight - $BottomOffset - $secondaryHeight - $Gap - $backglassHeight
        }
        $secondaryY = $backglassY + $backglassHeight + $Gap
    }
    else {
        $stackHeight = $backglassHeight + $Gap + $secondaryHeight
        if ($TopOffset -gt 0) {
            $stackTop = $TopOffset
        }
        else {
            $stackTop = $MonitorHeight - $BottomOffset - $stackHeight
        }

        if ($Order -eq 'Backglass Top / Secondary Bottom') {
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
    if ($secondaryX -lt 0 -or ($secondaryX + $SecondaryWidth) -gt $MonitorWidth) {
        [void]$warnings.Add('Secondary element extends outside the selected monitor horizontally.')
    }
    if ($secondaryY -lt 0 -or ($secondaryY + $secondaryHeight) -gt $MonitorHeight) {
        [void]$warnings.Add('Secondary element extends outside the selected monitor vertically.')
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
    @(
        3840
        2160
        $Layout.MonitorWidth
        $Layout.MonitorHeight
        1
        3840
        0
        0
        0
        0
        0
        0
        $Layout.BackglassX
        $Layout.BackglassY
        $Layout.BackglassWidth
        $Layout.BackglassHeight
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

$y = 10
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

$lblFile = Add-Label 'Select .directb2s File:' $y
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

$lblMon = Add-Label 'Backglass Monitor Resolution (W x H):' $y $true
$y += 25
$numMonW = [System.Windows.Forms.NumericUpDown]::new()
$numMonW.Minimum = 500; $numMonW.Maximum = 7680; $numMonW.Value = 1440
$numMonW.Location = [System.Drawing.Point]::new(10, $y); $numMonW.Size = [System.Drawing.Size]::new(100, 23)
[void]$panelControls.Controls.Add($numMonW)
$lblX = Add-Label 'x' ($y + 3)
$lblX.Location = [System.Drawing.Point]::new(118, $y + 3)
$numMonH = [System.Windows.Forms.NumericUpDown]::new()
$numMonH.Minimum = 500; $numMonH.Maximum = 7680; $numMonH.Value = 2560
$numMonH.Location = [System.Drawing.Point]::new(135, $y); $numMonH.Size = [System.Drawing.Size]::new(100, 23)
[void]$panelControls.Controls.Add($numMonH)

$y += 35
$lblGrillInfo = Add-Label 'XML Grill Height: 0 px' $y $true
$y += 22
$chkCutGrill = [System.Windows.Forms.CheckBox]::new()
$chkCutGrill.Text = 'Crop Embedded Grill from Backglass'
$chkCutGrill.Location = [System.Drawing.Point]::new(10, $y)
$chkCutGrill.AutoSize = $true
$chkCutGrill.Enabled = $false
[void]$panelControls.Controls.Add($chkCutGrill)

$y += 35
$lblType = Add-Label 'Secondary Element:' $y
$cmbType = [System.Windows.Forms.ComboBox]::new()
[void]$cmbType.Items.AddRange(@('DMD Image', 'Grill Image'))
$cmbType.SelectedIndex = 0; $cmbType.DropDownStyle = 'DropDownList'
$cmbType.Location = [System.Drawing.Point]::new(150, $y - 3); $cmbType.Size = [System.Drawing.Size]::new(200, 23)
[void]$panelControls.Controls.Add($cmbType)

$y += 30
$lblTopOffset = Add-Label 'Top Offset (px):' $y
$numTopOffset = [System.Windows.Forms.NumericUpDown]::new()
$numTopOffset.Minimum = 0; $numTopOffset.Maximum = 7680; $numTopOffset.Value = 0
$numTopOffset.Location = [System.Drawing.Point]::new(150, $y - 3); $numTopOffset.Size = [System.Drawing.Size]::new(100, 23)
[void]$panelControls.Controls.Add($numTopOffset)

$y += 30
$lblBottomOffset = Add-Label 'Bottom Offset (px):' $y
$numBottomOffset = [System.Windows.Forms.NumericUpDown]::new()
$numBottomOffset.Minimum = 0; $numBottomOffset.Maximum = 7680; $numBottomOffset.Value = 0
$numBottomOffset.Location = [System.Drawing.Point]::new(150, $y - 3); $numBottomOffset.Size = [System.Drawing.Size]::new(100, 23)
[void]$panelControls.Controls.Add($numBottomOffset)

$y += 30
$lblOrder = Add-Label 'Vertical Stacking Order:' $y
$cmbOrder = [System.Windows.Forms.ComboBox]::new()
[void]$cmbOrder.Items.AddRange(@('Backglass Top / Secondary Bottom', 'Secondary Top / Backglass Bottom'))
$cmbOrder.SelectedIndex = 0; $cmbOrder.DropDownStyle = 'DropDownList'
$cmbOrder.Location = [System.Drawing.Point]::new(150, $y - 3); $cmbOrder.Size = [System.Drawing.Size]::new(200, 23)
[void]$panelControls.Controls.Add($cmbOrder)

$y += 30
$lblDmdW = Add-Label 'Secondary Width (px):' $y
$numDmdW = [System.Windows.Forms.NumericUpDown]::new()
$numDmdW.Minimum = 100; $numDmdW.Maximum = 3840; $numDmdW.Value = 1080
$numDmdW.Location = [System.Drawing.Point]::new(150, $y - 3); $numDmdW.Size = [System.Drawing.Size]::new(100, 23)
[void]$panelControls.Controls.Add($numDmdW)

$y += 30
$lblGap = Add-Label 'Element Gap (px):' $y
$numGap = [System.Windows.Forms.NumericUpDown]::new()
$numGap.Minimum = 0; $numGap.Maximum = 500; $numGap.Value = 20
$numGap.Location = [System.Drawing.Point]::new(150, $y - 3); $numGap.Size = [System.Drawing.Size]::new(100, 23)
[void]$panelControls.Controls.Add($numGap)

$y += 40
$btnSave = [System.Windows.Forms.Button]::new()
$btnSave.Text = 'Generate .res File'
$btnSave.Font = [System.Drawing.Font]::new($btnSave.Font, [System.Drawing.FontStyle]::Bold)
$btnSave.Size = [System.Drawing.Size]::new(350, 40); $btnSave.Location = [System.Drawing.Point]::new(10, $y)
$btnSave.BackColor = [System.Drawing.Color]::LightGreen; $btnSave.Enabled = $false
[void]$panelControls.Controls.Add($btnSave)

$y += 50
$txtStatus = [System.Windows.Forms.TextBox]::new()
$txtStatus.Multiline = $true; $txtStatus.ReadOnly = $true; $txtStatus.ScrollBars = 'Vertical'
$txtStatus.Size = [System.Drawing.Size]::new(350, 200); $txtStatus.Location = [System.Drawing.Point]::new(10, $y)
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
    if ($null -eq $cmbType.SelectedItem -or $null -eq $cmbOrder.SelectedItem) { return }

    $targetType = [string]$cmbType.SelectedItem
    $secondaryIsGrill = $targetType -eq 'Grill Image'
    $activeBitmap = if ($secondaryIsGrill) { $script:State.Grill } else { $script:State.Dmd }

    try {
        $layoutParameters = @{
            MonitorWidth    = [int]$numMonW.Value
            MonitorHeight   = [int]$numMonH.Value
            Backglass       = $script:State.Backglass
            Secondary       = $activeBitmap
            GrillHeight     = $script:State.GrillHeight
            CropGrill       = $chkCutGrill.Checked
            SecondaryWidth  = [int]$numDmdW.Value
            Gap             = [int]$numGap.Value
            TopOffset       = [int]$numTopOffset.Value
            BottomOffset    = [int]$numBottomOffset.Value
            Order           = [string]$cmbOrder.SelectedItem
            SecondaryIsGrill = $secondaryIsGrill
        }
        $layout = Get-Layout @layoutParameters
    }
    catch {
        $txtStatus.Text = "Layout error:`r`n$($_.Exception.Message)"
        return
    }

    $script:State.CalculatedRes = $layout
    $warningText = if ($layout.Warnings.Count -gt 0) { "`r`nWARNINGS:`r`n - " + ($layout.Warnings -join "`r`n - ") } else { '' }
    $positionNote = if ($secondaryIsGrill) { 'Grill is fixed immediately below the backglass; bottom offset is measured from the bottom of the grill.' } else { 'DMD follows the selected stacking order.' }
    $txtStatus.Text = @"
LAYOUT SETTINGS:
Top Offset: $([int]$numTopOffset.Value) px
Bottom Offset: $([int]$numBottomOffset.Value) px
Order: $($cmbOrder.SelectedItem)
Element Gap: $([int]$numGap.Value) px
$positionNote

BACKGLASS RESULT:
Original Image: $($script:State.Backglass.Width)x$($script:State.Backglass.Height) px
Effective Source: $($layout.SourceWidth)x$($layout.SourceHeight) px
Grill Cropped: $($layout.GrillCropped)
Render Output: $($layout.BackglassWidth)x$($layout.BackglassHeight) px at ($($layout.BackglassX),$($layout.BackglassY))

$targetType RESULT:
Render Output: $($layout.SecondaryWidth)x$($layout.SecondaryHeight) px at ($($layout.SecondaryX),$($layout.SecondaryY))

Note: the exported .res format stores backglass placement only.$warningText
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
            $graphics.DrawString("No $targetType Found", [System.Drawing.SystemFonts]::DefaultFont, [System.Drawing.Brushes]::White, $drawSecondaryX + 5, $drawSecondaryY + 5)
        }
        $graphics.DrawRectangle([System.Drawing.Pens]::OrangeRed, $secondaryRect)
    }
    finally { $graphics.Dispose() }

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

        $grillHeightNode = $xml.SelectSingleNode('//*[local-name()="GrillHeight"]')
        $script:State.GrillHeight = 0
        $grillText = Get-XmlNodeValue $grillHeightNode
        if (-not [string]::IsNullOrWhiteSpace($grillText)) {
            $heightMatch = [regex]::Match($grillText, '\d+')
            if ($heightMatch.Success) { [void][int]::TryParse($heightMatch.Value, [ref]$script:State.GrillHeight) }
        }

        $txtStatus.Text = 'Loading backglass image...'; $txtStatus.Refresh(); [System.Windows.Forms.Application]::DoEvents()
        $script:State.Backglass = Convert-Base64ToBitmap (Get-Base64ImageText $xml.SelectNodes('//*[local-name()="BackglassImage"]'))
        if ($null -eq $script:State.Backglass) { throw 'Could not locate valid Base64 data in a BackglassImage node.' }

        $txtStatus.Text = 'Loading DMD image...'; $txtStatus.Refresh(); [System.Windows.Forms.Application]::DoEvents()
        $dmdNodes = $xml.SelectNodes('//*[local-name()="DMDImage"]')
        if ($null -ne $dmdNodes) { $script:State.Dmd = Convert-Base64ToBitmap (Get-Base64ImageText $dmdNodes) }

        $txtStatus.Text = 'Loading grill image...'; $txtStatus.Refresh(); [System.Windows.Forms.Application]::DoEvents()
        $grillNodes = $xml.SelectNodes('//*[local-name()="GrillImage"]')
        if ($null -ne $grillNodes) { $script:State.Grill = Convert-Base64ToBitmap (Get-Base64ImageText $grillNodes) }

        if ($script:State.GrillHeight -gt 0) {
            $lblGrillInfo.Text = "XML Grill Height: $($script:State.GrillHeight) px"
            $chkCutGrill.Enabled = $true
            $chkCutGrill.Checked = $true
        }
        else {
            $lblGrillInfo.Text = 'XML Grill Height: 0 px (None)'
            $chkCutGrill.Checked = $false
            $chkCutGrill.Enabled = $false
        }

        $btnSave.Enabled = $true
        Update-Preview
    }
    catch {
        Clear-LoadedImages
        $btnSave.Enabled = $false
        $txtStatus.Text = "Error reading .directb2s file:`r`n$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Error reading .directb2s file:`r`n$($_.Exception.Message)", 'File Load Error', 'OK', 'Error') | Out-Null
    }
}

$btnBrowse.Add_Click({
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Filter = 'DirectB2S Files (*.directb2s)|*.directb2s|All files (*.*)|*.*'
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Load-DirectB2SFile $dialog.FileName }
    }
    finally { $dialog.Dispose() }
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

$renderControls = @($numMonW, $numMonH, $numDmdW, $numTopOffset, $numBottomOffset, $numGap)
foreach ($control in $renderControls) { $control.Add_ValueChanged({ Update-Preview }) }
$cmbOrder.Add_SelectedIndexChanged({ Update-Preview })
$cmbType.Add_SelectedIndexChanged({ Update-Preview })
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
