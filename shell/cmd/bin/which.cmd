@echo off
rem which - where.exe by its System32 path, so no where.* in the current
rem directory runs in its place.
"%SystemRoot%\System32\where.exe" %*
