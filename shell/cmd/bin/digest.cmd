@echo off
rem digest — unified hash function
rem Usage: digest {md5|sha256|sha512} <file>

if "%~1"=="" goto :usage
if "%~2"=="" goto :usage

set "_algo="
if /i "%~1"=="md5"    set "_algo=MD5"
if /i "%~1"=="sha256" set "_algo=SHA256"
if /i "%~1"=="sha512" set "_algo=SHA512"
if not defined _algo goto :usage

if not exist "%~2" (
    echo digest: '%~2' is not a file >&2
    exit /b 1
)

certutil -hashfile "%~2" %_algo% | findstr /v "hash CertUtil"
set "_algo="
exit /b

:usage
echo usage: digest {md5^|sha256^|sha512} ^<file^> >&2
exit /b 1
