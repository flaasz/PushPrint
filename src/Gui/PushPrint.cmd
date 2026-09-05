@echo off
rem Launches the PushPrint GUI without leaving a console window around.
rem Requires Windows PowerShell 5.1 (built in) - no install, no admin rights on this machine.
start "" /min powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PushPrint.ps1" %*
