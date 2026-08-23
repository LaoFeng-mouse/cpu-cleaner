# Swag Cat Icon and Shortcut Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the low-resolution shortcut icon with an original `鼠鼠的幻想` derivative based on the project's established vertically symmetrical cat-face meme language, and apply it consistently to the desktop shortcut, WPF window, taskbar and GUI launch entry.

**Architecture:** Generate one original square master with the same warm-cream background used by the GUI, review it visually, then derive a multi-frame ICO deterministically. A repository-owned PowerShell installer creates the shortcut with fixed target, arguments, working directory, description and icon; the GUI loads the same ICO after XAML creation.

**Tech Stack:** OpenAI image generation, PNG, Python Pillow or ImageMagick for ICO packaging, Windows PowerShell COM shortcut API, WPF BitmapFrame, Pester/GUI tests.

---

## File map

- Create `assets/shushu-cleaner-master.png`: approved original source art.
- Replace `assets/shushu.ico`: multi-frame Windows icon.
- Create `Install-DesktopShortcut.ps1`: idempotent shortcut installer.
- Modify `gui-cleaner.ps1`: set WPF/taskbar icon from repository asset.
- Modify `src/Gui/MainWindow.xaml`: unified title `鼠鼠 Cleaner`.
- Create `tests/Pester/Shortcut.Tests.ps1`: shortcut and icon contract.
- Modify `tests/Gui.Tests.ps1`: WPF icon and title checks.
- Modify `README.md`: shortcut install instructions and preview.

### Task 1: Generate and approve the original master asset

**Files:**
- Create: `assets/shushu-cleaner-master.png`

- [ ] **Step 1: Generate the visual using the approved prompt**

Use the image-generation skill with this prompt:

```text
Create an original square app icon derived from the project's established `鼠鼠的幻想` visual language, not a literal mouse and not a copy of any single meme photo. Use a beige-gray tabby cat in an extreme close-up, with its face deliberately mirrored along the vertical center, huge dark eyes, a centered pink nose, rounded cheeks, and the blank daydream expression used by the four-stage GUI. Keep a subtle low-resolution meme texture but make the silhouette clean enough for a Windows icon. Use a clean warm-cream background matching the GUI. Add a small mint-green cleaning broom at the lower-right, occupying no more than 20 percent of the canvas and not covering the eyes, nose, or mouth. No text, logos, weapons, game branding, or watermark. Keep both ears and the chin visible with safe padding.
```

- [ ] **Step 2: Inspect the generated master visually**

Reject it if the face is not symmetric, the broom covers facial features, the background contains a checkerboard pattern, or the small-size silhouette is unclear. Present the actual image to the user before deriving the ICO.

- [ ] **Step 3: Save only the approved image and commit**

```powershell
git add assets/shushu-cleaner-master.png
git commit -m "art: add original mouse-cat cleaner icon master"
```

### Task 2: Package a real multi-size ICO with tests

**Files:**
- Modify: `assets/shushu.ico`
- Create: `tests/Pester/Shortcut.Tests.ps1`

- [ ] **Step 1: Write a failing ICO contract test**

Parse the ICO directory header as binary and assert exact embedded dimensions `16,20,24,32,40,48,64,128,256`, at least one 256×256 PNG-compressed entry, file length greater than 10 KiB, and an RGB/RGBA square source PNG at least 1024 pixels wide.

- [ ] **Step 2: Run RED test**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\Pester\Shortcut.Tests.ps1' -EnableExit"
```

Expected: FAIL because the old ICO is only 32×32 and 766 bytes.

- [ ] **Step 3: Derive the ICO deterministically**

Use Pillow with the approved PNG and save all required sizes:

```python
from PIL import Image
source = Image.open('assets/shushu-cleaner-master.png').convert('RGBA')
source.save('assets/shushu.ico', format='ICO', sizes=[(16,16),(20,20),(24,24),(32,32),(40,40),(48,48),(64,64),(128,128),(256,256)])
```

- [ ] **Step 4: Run GREEN contract test and visually inspect 16/32/256 renders**

- [ ] **Step 5: Commit**

```powershell
git add assets/shushu.ico tests/Pester/Shortcut.Tests.ps1
git commit -m "feat: package multi-size mouse-cat Windows icon"
```

### Task 3: Add an idempotent desktop shortcut installer

**Files:**
- Create: `Install-DesktopShortcut.ps1`
- Modify: `tests/Pester/Shortcut.Tests.ps1`

- [ ] **Step 1: Write failing installer-source and integration tests**

Assert the installer creates `鼠鼠 Cleaner.lnk`, targets Windows PowerShell, passes `-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File <repo>\gui-cleaner.ps1`, sets the repository working directory, uses `assets\shushu.ico,0`, and description `安全识别并清理 OEM 后台组件`. Run against a temporary Desktop override exposed only as an installer parameter.

- [ ] **Step 2: Run RED tests**

Expected: FAIL because the installer does not exist.

- [ ] **Step 3: Implement the installer**

```powershell
param([string]$DesktopPath = [Environment]::GetFolderPath('Desktop'))
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$shortcutPath = Join-Path $DesktopPath '鼠鼠 Cleaner.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = (Get-Command powershell.exe).Source
$shortcut.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $root 'gui-cleaner.ps1') + '"'
$shortcut.WorkingDirectory = $root
$shortcut.IconLocation = (Join-Path $root 'assets\shushu.ico') + ',0'
$shortcut.Description = '安全识别并清理 OEM 后台组件'
$shortcut.Save()
```

Validate root files before overwriting an existing shortcut and fail without mutation when the GUI/icon is missing.

- [ ] **Step 4: Run GREEN tests and commit**

```powershell
git add Install-DesktopShortcut.ps1 tests/Pester/Shortcut.Tests.ps1
git commit -m "feat: install branded mouse cleaner shortcut"
```

### Task 4: Apply icon to WPF window and taskbar

**Files:**
- Modify: `tests/Gui.Tests.ps1`
- Modify: `gui-cleaner.ps1`
- Modify: `src/Gui/MainWindow.xaml`

- [ ] **Step 1: Write failing GUI icon tests**

Assert the loaded window title is exactly `鼠鼠 Cleaner`, `$window.Icon` is non-null, and its decoder exposes icon frames. Add a fail-closed test where a missing icon does not prevent the GUI from opening but records a diagnostic warning.

- [ ] **Step 2: Run RED GUI tests**

Expected: FAIL because no window icon is loaded.

- [ ] **Step 3: Load the icon after XAML creation**

Use a read-only file stream and `BitmapFrame.Create`, set `$window.Icon`, then dispose the stream after the frame is cached. Keep application startup working if icon loading fails and surface the error only in diagnostics.

- [ ] **Step 4: Run GREEN GUI tests and commit**

```powershell
git add gui-cleaner.ps1 src/Gui/MainWindow.xaml tests/Gui.Tests.ps1
git commit -m "feat: apply mouse-cat icon to cleaner window"
```

### Task 5: Install and visually verify the real desktop shortcut

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run full shortcut and GUI tests**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path '.\tests\Pester\Shortcut.Tests.ps1' -EnableExit"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\run-gui-tests.ps1
```

Expected: all pass.

- [ ] **Step 2: Install the actual desktop shortcut**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-DesktopShortcut.ps1
```

- [ ] **Step 3: Inspect COM properties and launch once**

Read back target, arguments, working directory, icon and description. Launch the shortcut, verify there is no persistent console window, verify WPF title/icon, then close without starting a cleanup.

- [ ] **Step 4: Capture desktop visual acceptance**

Check small, medium and high-DPI icon views. If Windows icon cache still shows the old icon, rename/recreate the shortcut and refresh Explorer without deleting unrelated icon-cache or desktop data.

- [ ] **Step 5: Update README and commit**

```powershell
git add README.md
git commit -m "docs: explain branded desktop shortcut install"
```

- [ ] **Step 6: Run final static and worktree checks**

```powershell
git diff --check
git status --short --branch
```

Expected: clean tracked worktree; temporary visual-companion files remain untracked and must not be committed.
