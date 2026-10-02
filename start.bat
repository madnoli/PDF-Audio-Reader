@echo off
rem Starts a local web server and opens the reader in Microsoft Edge
rem (Edge includes the natural Indian voices Neerja and Prabhat).
cd /d "%~dp0"
start "" msedge http://localhost:8000
python -m http.server 8000
