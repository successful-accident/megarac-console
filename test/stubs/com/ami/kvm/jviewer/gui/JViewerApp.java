// SPDX-FileCopyrightText: 2026 Jeff Morrison
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test stand-in, not AMI code: only the names and signatures the launcher, Fit
// and the media test need, so they build and run without a BMC.
package com.ami.kvm.jviewer.gui;

import com.ami.iusb.IUSBRedirSession;
import com.ami.kvm.jviewer.kvmpkts.KVMClient;
import java.awt.image.BufferedImage;
import javax.swing.JComponent;
import javax.swing.JScrollPane;

public class JViewerApp {
    public static final int CAPSLOCK = 2;
    public static JViewerApp getInstance() { return null; }
    public JComponent getRCView() { return null; }
    public int getLed_status() { return 0; }
    public IUSBRedirSession getM_IUSBSession() { return null; }
    public void create_IUSBSession() {}
    public String getSessionToken() { return null; }
    public int getCDPort() { return 0; }
    public boolean isM_bVMUseSSL() { return false; }
    public KVMClient getKVMClient() { return null; }
    public boolean isFullScreenMode() { return false; }
    public Window getMainWindow() { return null; }
    public Buffer getPrepare_buf() { return null; }

    public static class Window {
        public JScrollPane getM_viewSP() { return null; }
    }

    public static class Buffer {
        public BufferedImage getM_image() { return null; }
    }
}
