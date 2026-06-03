@echo off
powershell -NoProfile -Command "($env:PATH -split ';') -ne '' | ForEach-Object { $_ }"
