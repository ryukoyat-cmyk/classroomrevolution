Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies "System.Windows.Forms", "System.Drawing" -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class LayeredWindow
{
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_LAYERED = 0x00080000;
    private const byte AC_SRC_OVER = 0;
    private const byte AC_SRC_ALPHA = 1;
    private const int ULW_ALPHA = 2;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x; public int y; public POINT(int x, int y) { this.x = x; this.y = y; } }

    [StructLayout(LayoutKind.Sequential)]
    public struct SIZE { public int cx; public int cy; public SIZE(int cx, int cy) { this.cx = cx; this.cy = cy; } }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

    [DllImport("user32.dll", SetLastError = true)] private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError = true)] private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern bool DeleteObject(IntPtr hObject);

    public static void Enable(IntPtr handle)
    {
        int style = GetWindowLong(handle, GWL_EXSTYLE);
        SetWindowLong(handle, GWL_EXSTYLE, style | WS_EX_LAYERED);
    }

    public static void SetBitmap(Form form, Bitmap bitmap)
    {
        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memDc = CreateCompatibleDC(screenDc);
        IntPtr hBitmap = bitmap.GetHbitmap(Color.FromArgb(0));
        IntPtr oldBitmap = SelectObject(memDc, hBitmap);

        try
        {
            POINT top = new POINT(form.Left, form.Top);
            SIZE size = new SIZE(bitmap.Width, bitmap.Height);
            POINT source = new POINT(0, 0);
            BLENDFUNCTION blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = AC_SRC_ALPHA };

            if (!UpdateLayeredWindow(form.Handle, screenDc, ref top, ref size, memDc, ref source, 0, ref blend, ULW_ALPHA))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            SelectObject(memDc, oldBitmap);
            DeleteObject(hBitmap);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }
}
"@

$ErrorActionPreference = "Stop"

$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$defaultImagePath = Join-Path $appRoot "assets\pet.png"
$configDir = Join-Path $appRoot "config"
$settingsPath = Join-Path $configDir "settings.json"
$customImagePath = Join-Path $configDir "custom-pet.png"

if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
}

function Get-DefaultSettings {
    [pscustomobject]@{
        ImagePath = $defaultImagePath
        X = $null
        Y = $null
        Width = 160
    }
}

function Read-Settings {
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        return Get-DefaultSettings
    }

    try {
        $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
        if (-not $settings.ImagePath -or -not (Test-Path -LiteralPath $settings.ImagePath)) {
            $settings.ImagePath = $defaultImagePath
        }
        if (-not $settings.Width -or $settings.Width -lt 64) {
            $settings.Width = 160
        }
        return $settings
    }
    catch {
        return Get-DefaultSettings
    }
}

function Save-Settings {
    param(
        [string]$ImagePath,
        [int]$X,
        [int]$Y,
        [int]$Width
    )

    [pscustomobject]@{
        ImagePath = $ImagePath
        X = $X
        Y = $Y
        Width = $Width
    } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}

function Load-BitmapUnlocked {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $stream = New-Object System.IO.MemoryStream(,$bytes)
    try {
        $image = [System.Drawing.Image]::FromStream($stream)
        try {
            return New-Object System.Drawing.Bitmap($image)
        }
        finally {
            $image.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function New-UiText {
    param([int[]]$CodePoints)

    -join ($CodePoints | ForEach-Object { [string][char]$_ })
}

function Resize-PetWindow {
    param(
        [System.Windows.Forms.Form]$Form,
        [System.Drawing.Image]$Image,
        [int]$TargetWidth
    )

    $safeWidth = [Math]::Max(64, [Math]::Min(360, $TargetWidth))
    $ratio = $Image.Height / [double]$Image.Width
    $height = [Math]::Max(64, [int][Math]::Round($safeWidth * $ratio))
    $Form.ClientSize = New-Object System.Drawing.Size($safeWidth, $height)
}

function New-DisplayBitmap {
    param(
        [System.Drawing.Image]$Image,
        [int]$Width,
        [int]$Height
    )

    $bitmap = New-Object System.Drawing.Bitmap $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($Image, 0, 0, $Width, $Height)
    }
    finally {
        $graphics.Dispose()
    }

    return $bitmap
}

function Update-PetBitmap {
    if ($script:displayBitmap) {
        $script:displayBitmap.Dispose()
    }

    $script:displayBitmap = New-DisplayBitmap -Image $script:currentBitmap -Width $form.Width -Height $form.Height
    [LayeredWindow]::SetBitmap($form, $script:displayBitmap)
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$settings = Read-Settings
$currentImagePath = $settings.ImagePath
$currentBitmap = Load-BitmapUnlocked $currentImagePath
$displayBitmap = $null

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.Padding = New-Object System.Windows.Forms.Padding(0)
$form.Cursor = [System.Windows.Forms.Cursors]::SizeAll

Resize-PetWindow -Form $form -Image $currentBitmap -TargetWidth ([int]$settings.Width)

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($null -ne $settings.X -and $null -ne $settings.Y) {
    $form.Location = New-Object System.Drawing.Point([int]$settings.X, [int]$settings.Y)
}
else {
    $x = $screen.Right - $form.Width - 80
    $y = $screen.Bottom - $form.Height - 80
    $form.Location = New-Object System.Drawing.Point($x, $y)
}

$dragging = $false
$dragStart = New-Object System.Drawing.Point(0, 0)

$form.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragging = $true
        $script:dragStart = $_.Location
    }
})

$form.Add_MouseMove({
    if ($script:dragging) {
        $newX = $form.Left + $_.X - $script:dragStart.X
        $newY = $form.Top + $_.Y - $script:dragStart.Y
        $form.Location = New-Object System.Drawing.Point($newX, $newY)
        Update-PetBitmap
    }
})

$form.Add_MouseUp({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragging = $false
        Save-Settings -ImagePath $script:currentImagePath -X $form.Left -Y $form.Top -Width $form.Width
    }
})

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$changeImageItem = $menu.Items.Add((New-UiText @(0xC774,0xBBF8,0xC9C0,0x20,0xBCC0,0xACBD,0x2E,0x2E,0x2E)))
$resetImageItem = $menu.Items.Add((New-UiText @(0xAE30,0xBCF8,0x20,0xCE90,0xB9AD,0xD130,0xB85C,0x20,0xB418,0xB3CC,0xB9AC,0xAE30)))
$menu.Items.Add("-") | Out-Null
$exitItem = $menu.Items.Add((New-UiText @(0xC885,0xB8CC)))
$form.ContextMenuStrip = $menu

$changeImageItem.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = New-UiText @(0xCE90,0xB9AD,0xD130,0x20,0xC774,0xBBF8,0xC9C0,0x20,0xC120,0xD0DD)
    $dialog.Filter = (New-UiText @(0xC774,0xBBF8,0xC9C0,0x20,0xD30C,0xC77C)) + "|*.png;*.jpg;*.jpeg;*.bmp;*.gif|" + (New-UiText @(0xBAA8,0xB4E0,0x20,0xD30C,0xC77C)) + "|*.*"
    $dialog.Multiselect = $false

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $selectedBitmap = Load-BitmapUnlocked $dialog.FileName
            $selectedBitmap.Save($customImagePath, [System.Drawing.Imaging.ImageFormat]::Png)
            $selectedBitmap.Dispose()

            $newBitmap = Load-BitmapUnlocked $customImagePath
            $oldBitmap = $script:currentBitmap
            $script:currentBitmap = $newBitmap
            if ($oldBitmap) { $oldBitmap.Dispose() }

            $script:currentImagePath = $customImagePath
            Resize-PetWindow -Form $form -Image $newBitmap -TargetWidth 160
            Update-PetBitmap
            Save-Settings -ImagePath $script:currentImagePath -X $form.Left -Y $form.Top -Width $form.Width
            $form.TopMost = $true
        }
        catch {
            $message = (New-UiText @(0xC774,0xBBF8,0xC9C0,0xB97C,0x20,0xBD88,0xB7EC,0xC624,0xC9C0,0x20,0xBABB,0xD588,0xC2B5,0xB2C8,0xB2E4,0x2E)) + "`n$($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($message, "Desktop Pet", "OK", "Warning") | Out-Null
        }
    }
})

$resetImageItem.Add_Click({
    try {
        $newBitmap = Load-BitmapUnlocked $defaultImagePath
        $oldBitmap = $script:currentBitmap
        $script:currentBitmap = $newBitmap
        if ($oldBitmap) { $oldBitmap.Dispose() }

        $script:currentImagePath = $defaultImagePath
        Resize-PetWindow -Form $form -Image $newBitmap -TargetWidth 160
        Update-PetBitmap
        Save-Settings -ImagePath $script:currentImagePath -X $form.Left -Y $form.Top -Width $form.Width
        $form.TopMost = $true
    }
    catch {
        $message = (New-UiText @(0xAE30,0xBCF8,0x20,0xCE90,0xB9AD,0xD130,0xB97C,0x20,0xBD88,0xB7EC,0xC624,0xC9C0,0x20,0xBABB,0xD588,0xC2B5,0xB2C8,0xB2E4,0x2E)) + "`n$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($message, "Desktop Pet", "OK", "Warning") | Out-Null
    }
})

$exitItem.Add_Click({
    Save-Settings -ImagePath $script:currentImagePath -X $form.Left -Y $form.Top -Width $form.Width
    $form.Close()
})

$keepOnTopTimer = New-Object System.Windows.Forms.Timer
$keepOnTopTimer.Interval = 1000
$keepOnTopTimer.Add_Tick({
    if (-not $form.TopMost) {
        $form.TopMost = $true
    }
    Update-PetBitmap
})
$keepOnTopTimer.Start()

$form.Add_FormClosing({
    Save-Settings -ImagePath $script:currentImagePath -X $form.Left -Y $form.Top -Width $form.Width
    $keepOnTopTimer.Stop()
    if ($script:displayBitmap) {
        $script:displayBitmap.Dispose()
    }
    if ($script:currentBitmap) {
        $script:currentBitmap.Dispose()
    }
})

$null = $form.Handle
[LayeredWindow]::Enable($form.Handle)
Update-PetBitmap
[System.Windows.Forms.Application]::Run($form)
