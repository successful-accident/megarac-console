// SPDX-FileCopyrightText: 2026 Jeff Morrison
// SPDX-License-Identifier: GPL-3.0-or-later

import com.ami.iusb.IUSBRedirSession;
import com.ami.kvm.jviewer.JViewer;
import com.ami.kvm.jviewer.gui.JVMenu;
import com.ami.kvm.jviewer.gui.JViewerApp;
import com.ami.kvm.jviewer.gui.JViewerView;
import com.ami.kvm.jviewer.kvmpkts.KVMClient;
import java.awt.Component;
import java.awt.Frame;
import java.awt.Insets;
import java.awt.KeyboardFocusManager;
import java.awt.Toolkit;
import java.awt.event.KeyEvent;
import java.awt.image.BufferedImage;
import java.util.prefs.Preferences;
import javax.swing.JScrollPane;
import javax.swing.Timer;

// Starts JViewer, then fixes four things it gets wrong, the first three by
// checking every 250 ms:
// - It opens at its own default size. Reopen at the size the window had last.
// - It only zooms in fixed steps. Keep its zoom factor (JVMenu.m_scale, which
//   drives painting, layout and mouse mapping) matched to the window, so the
//   host screen always fills it.
// - After Pause then Resume the BMC sends only the parts of the screen that
//   change, onto a blank picture. Ask for the whole screen when video resumes.
// - Caps Lock took two presses on macOS. There, Java reports it as a press when
//   it turns on and a release when it turns off, so the server got half a
//   keystroke each time. Send a whole keystroke, and only when the server's
//   Caps Lock differs from the Mac's. macOS only.
// The viewer's own LED sync is switched off everywhere but Windows: it works by
// pressing keys on this computer, from an LED reading that media.c, which stands
// in for the vendor's library there, cannot supply.
public class Fit {
    static final String OS = System.getProperty("os.name");
    static final boolean MAC = OS.startsWith("Mac"), WIN = OS.startsWith("Windows");
    static final Preferences prefs = Preferences.userRoot().node("megarac-console");
    static final long start = System.currentTimeMillis();
    static boolean wasRunning;
    static Boolean lastCaps;
    // BMC_ISO=/path/to.iso mounts that image as the virtual CD once video is
    // up, the same call the Media dialog makes, and logs for a minute how much
    // the server has read from it. Closing the console unmounts it.
    static String iso = System.getenv("BMC_ISO");

    public static void main(String[] args) throws Exception {
        new Timer(250, e -> tick()).start();
        if (MAC) KeyboardFocusManager.getCurrentKeyboardFocusManager().addKeyEventDispatcher(Fit::capsLock);
        JViewer.main(args);
    }

    static boolean capsLock(KeyEvent e) {
        if (e.getKeyCode() != KeyEvent.VK_CAPS_LOCK || System.currentTimeMillis() - start < 3000) return false;
        JViewerApp app = JViewerApp.getInstance();
        Component view = app.getRCView();
        if (e.getComponent() != view) return false;
        boolean mac = Toolkit.getDefaultToolkit().getLockingKeyState(KeyEvent.VK_CAPS_LOCK);
        boolean server = (app.getLed_status() & JViewerApp.CAPSLOCK) != 0;
        // lastCaps: act once per change, however many events the Mac sends for it.
        if ((lastCaps == null || lastCaps != mac) && mac != server) {
            KeyboardFocusManager keys = KeyboardFocusManager.getCurrentKeyboardFocusManager();
            for (int id : new int[] { KeyEvent.KEY_PRESSED, KeyEvent.KEY_RELEASED })
                keys.redispatchEvent(view, new KeyEvent(view, id, e.getWhen(), 0, KeyEvent.VK_CAPS_LOCK, KeyEvent.CHAR_UNDEFINED,
                    KeyEvent.KEY_LOCATION_STANDARD)); // the viewer drops keys with no location
        }
        lastCaps = mac;
        return true;
    }

    static void mount(JViewerApp app, String path) {
        try {
            if (app.getM_IUSBSession() == null) app.create_IUSBSession();
            IUSBRedirSession media = app.getM_IUSBSession();
            boolean ok = media.StartISORedir(app.getSessionToken(), app.getCDPort(), 0, app.isM_bVMUseSSL(), path);
            System.out.println("BMC_ISO: mount of " + path + (ok ? " started" : " FAILED"));
            for (int i = 0; ok && i < 12; i++) {
                Thread.sleep(5000);
                System.out.println("BMC_ISO: status " + media.getCDROMRedirStatus(0) + ", host has read " + media.getCDROMReadBytes(0) + " KB");
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    static void tick() {
        try {
            Frame window = null;
            for (Frame f : Frame.getFrames()) if (f.isVisible()) window = f;
            if (window == null) return;
            int w = prefs.getInt("width", 0), h = prefs.getInt("height", 0);

            // First 3 s: the viewer is still starting and sizing its window, and
            // its singleton is not safe to touch. Only hold the saved size.
            if (System.currentTimeMillis() - start < 3000) {
                if (w > 0 && (window.getWidth() != w || window.getHeight() != h)) window.setSize(w, h);
                return;
            }

            JViewerApp app = JViewerApp.getInstance();
            if (!WIN) JViewerView.m_keyled_flag = true; // the viewer's LED sync off; see the top

            KVMClient client = app.getKVMClient();
            boolean running = client.isM_redirection();
            if (running && !wasRunning) {
                // One tick later, so the resume command reaches the BMC first.
                Timer once = new Timer(250, e -> client.sendFullScreenRequest());
                once.setRepeats(false);
                once.start();
            }
            wasRunning = running;
            if (running && iso != null) {
                String path = iso;
                iso = null;
                new Thread(() -> mount(app, path)).start();
            }

            if (app.isFullScreenMode()) return;
            if (window.getWidth() != w || window.getHeight() != h) {
                prefs.putInt("width", window.getWidth());
                prefs.putInt("height", window.getHeight());
            }

            JScrollPane pane = app.getMainWindow().getM_viewSP();
            BufferedImage host = app.getPrepare_buf().getM_image();
            pane.setHorizontalScrollBarPolicy(JScrollPane.HORIZONTAL_SCROLLBAR_NEVER);
            pane.setVerticalScrollBarPolicy(JScrollPane.VERTICAL_SCROLLBAR_NEVER);
            Insets in = pane.getInsets();
            double pw = pane.getWidth() - in.left - in.right;
            double ph = pane.getHeight() - in.top - in.bottom;
            double scale = Math.min(pw / host.getWidth(), ph / host.getHeight());
            if (scale <= 0 || Math.abs(scale - JVMenu.m_scale) < 0.002) return;
            JVMenu.m_scale = scale;
            app.getRCView().revalidate();
            app.getRCView().repaint();
        } catch (RuntimeException e) {
            // Viewer not up yet, or no video frame to measure.
        }
    }
}
