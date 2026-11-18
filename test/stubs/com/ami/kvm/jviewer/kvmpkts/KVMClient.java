// SPDX-FileCopyrightText: 2026 Jeff Morrison
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test stand-in, not AMI code: only the names and signatures the launcher, Fit
// and the media test need, so they build and run without a BMC.
package com.ami.kvm.jviewer.kvmpkts;

public class KVMClient {
    public boolean isM_redirection() { return false; }
    public void sendFullScreenRequest() {}
}
