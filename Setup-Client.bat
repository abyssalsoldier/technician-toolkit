@echo off
title Toolkit Client Setup
:: Opens the Client Setup wizard (tools\ClientSetup). No administrator rights needed.
:: Windows PowerShell 5.1 in STA mode is always available and required for the WPF window.
:: PSModulePath is cleared so a PowerShell 7 parent session cannot leak its module paths into 5.1.
set PSModulePath=
start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tools\ClientSetup\Start-ClientSetup.ps1"
