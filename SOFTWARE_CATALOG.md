# Software Manager — Package Catalog

Packages available in the toolkit's Software Manager section, installed via `winget` (plus any local `.exe`/`.msi` files dropped into `CustomInstallers/`).

## Browsers
- Google Chrome (`Google.Chrome`)
- Mozilla Firefox (`Mozilla.Firefox`)

## Productivity
- Adobe Acrobat Reader (`Adobe.Acrobat.Reader.64-bit`)
- Adobe Acrobat Reader 32-bit (`Adobe.Acrobat.Reader.32-bit`)
- Adobe Acrobat Pro (`Adobe.Acrobat.Pro`)
- Microsoft Office (`Microsoft.Office`)
- Bluebeam Revu (`Bluebeam.Revu.21`)
- Egnyte Desktop App (`Egnyte.EgnyteDesktopApp`)
- 7-Zip (`7zip.7zip`)
- Notepad++ (`Notepad++.Notepad++`)
- VLC Media Player (`VideoLAN.VLC`)

## Communication
- Microsoft Teams (`Microsoft.Teams`)
- Zoom (`Zoom.Zoom`)
- Slack (`SlackTechnologies.Slack`)
- RingCentral (`RingCentral.RingCentral`)
- Dialpad (`Dialpad.Dialpad`)

## Runtimes
- .NET Desktop Runtime 8 (`Microsoft.DotNet.DesktopRuntime.8`)
- VC++ Redistributable 2015+ (`Microsoft.VCRedist.2015+.x64`)

## Utilities
- PowerShell 7 (`Microsoft.PowerShell`)
- TreeSize Free (`JAMSoftware.TreeSize.Free`)
- WinSCP (`WinSCP.WinSCP`)
- PuTTY (`PuTTY.PuTTY`)
- FileZilla (`TimKosse.FileZilla.Client`)

## Drivers
- Dell Command Update (`Dell.CommandUpdate`)
- Lenovo System Update (`Lenovo.SystemUpdate`)

## Custom Installers
Any `.exe`/`.msi` files found in `CustomInstallers/` (excluding the `ODT` subfolder, which Debloat uses) are auto-discovered and added to this list at runtime — not statically defined in the catalog.

---
*Source: [dependencies/Modules/Install-Software.ps1](dependencies/Modules/Install-Software.ps1) — `Get-WingetPackageCatalog`*
