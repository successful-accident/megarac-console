@echo off
rem SPDX-FileCopyrightText: 2026 Jeff Morrison
rem SPDX-License-Identifier: GPL-3.0-or-later
rem
rem The megarac-console command on Windows: the launcher on the Java 8 installed
rem with it. megarac-console.iss puts it on PATH.
"%~dp0..\jdk\bin\java.exe" -cp "%~dp0..\classes" MegaracConsole %*
