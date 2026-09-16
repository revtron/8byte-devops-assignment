@echo off
rem Runs the PowerShell version from cmd.exe (typing the .ps1 in cmd only opens it in an editor).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-admin-cidr.ps1" %*
