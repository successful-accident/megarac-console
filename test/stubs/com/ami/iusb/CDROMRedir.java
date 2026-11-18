// SPDX-FileCopyrightText: 2026 Jeff Morrison
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test stand-in, not AMI code: only the names and signatures the launcher, Fit
// and the media test need, so they build and run without a BMC.
package com.ami.iusb;

import java.nio.ByteBuffer;

// The CD library's native methods, which media.c implements, and the field it
// keeps its reader in.
public class CDROMRedir {
    private long nativeReaderPointer = -1;

    public CDROMRedir(boolean physical) {}

    private native void newCDROMReader(boolean physical);
    private native void deleteCDROMReader();
    private native boolean openCDROM(byte[] path);
    private native void closeCDROM();
    private native int executeCDROMSCSICmd(ByteBuffer request, ByteBuffer response);
    private native String[] listCDROMDrives();
    private native String getVersion();
}
