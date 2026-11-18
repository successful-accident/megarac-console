// SPDX-FileCopyrightText: 2026 Jeff Morrison
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test stand-in, not AMI code: only the names and signatures the launcher, Fit
// and the media test need, so they build and run without a BMC.
package com.ami.iusb;

public class IUSBRedirSession {
    public boolean StartISORedir(String token, int port, int index, boolean ssl, String path) { return false; }
    public int getCDROMRedirStatus(int index) { return 0; }
    public long getCDROMReadBytes(int index) { return 0; }
}
