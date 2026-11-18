// SPDX-FileCopyrightText: 2026 Jeff Morrison
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test stand-in, not AMI code: only the names and signatures the launcher, Fit
// and the media test need, so they build and run without a BMC.
package com.ami.kvm.jviewer;

import java.io.PrintWriter;
import java.lang.management.ManagementFactory;

// The viewer's main class. Writes its arguments to $STUB_ARGS_FILE, loads the
// three media libraries the real viewer loads (unless $STUB_NO_LIBS is set),
// then waits $STUB_SLEEP seconds and exits with $STUB_EXIT.
public class JViewer {
    public static void main(String[] args) throws Exception {
        System.out.println("PID:" + ManagementFactory.getRuntimeMXBean().getName().split("@")[0]);
        try (PrintWriter w = new PrintWriter(System.getenv("STUB_ARGS_FILE"), "UTF-8")) {
            for (String a : args) w.println(a);
        }
        if (System.getenv("STUB_NO_LIBS") == null)
            for (String lib : new String[] { "javacdromwrapper", "javafloppywrapper", "javaharddiskwrapper" }) {
                System.loadLibrary(lib);
                System.out.println("LOADED:" + lib);
            }
        String sleep = System.getenv("STUB_SLEEP"), exit = System.getenv("STUB_EXIT");
        if (sleep != null) Thread.sleep(Long.parseLong(sleep) * 1000);
        System.exit(exit == null ? 0 : Integer.parseInt(exit));
    }
}
