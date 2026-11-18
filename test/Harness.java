// SPDX-FileCopyrightText: 2026 Jeff Morrison
// SPDX-License-Identifier: GPL-3.0-or-later

import com.ami.iusb.CDROMRedir;
import java.io.*;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.file.*;
import java.security.MessageDigest;

// Drives a CD library's native methods with no viewer or BMC, from a script of
// 1024-byte records, and writes one line per record. A record starting "CTL:"
// is a control word; anything else is a SCSI request packet.
//   java Harness <library> <script> <output>
public class Harness {
    static CDROMRedir cd;

    static Object call(String name, Class<?>[] types, Object... args) throws Exception {
        Method m = CDROMRedir.class.getDeclaredMethod(name, types);
        m.setAccessible(true);
        return m.invoke(cd, args);
    }

    static String hex(byte[] b, int from, int to) {
        StringBuilder s = new StringBuilder();
        for (int i = from; i < to; i++) s.append(String.format("%02x", b[i]));
        return s.toString();
    }

    public static void main(String[] a) throws Exception {
        // The viewer class hunts for its library in places that only exist inside
        // a running viewer and complains on stdout; load the one under test here.
        PrintStream stdout = System.out;
        System.setOut(new PrintStream(new ByteArrayOutputStream()));
        cd = new CDROMRedir(false);
        System.setOut(stdout);
        System.load(a[0]);

        Class<?>[] none = {}, flag = { boolean.class }, bytes = { byte[].class }, buffers = { ByteBuffer.class, ByteBuffer.class };
        ByteBuffer req = ByteBuffer.allocateDirect(1024), resp = ByteBuffer.allocateDirect(131134);
        byte[] rec = new byte[1024], after = new byte[1024], zero = new byte[131134], out = new byte[131134];
        try (DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(a[1])));
             PrintWriter log = new PrintWriter(new BufferedWriter(new FileWriter(a[2])))) {
            for (int n = 0; ; n++) {
                try { in.readFully(rec); } catch (EOFException e) { break; }
                if (new String(rec, 0, 4, "ISO-8859-1").equals("CTL:")) {
                    String[] w = new String(rec, 4, 1020, "UTF-8").split("\0")[0].split(" ");
                    Object r = "";
                    switch (w[0]) {
                    case "NEW": call("newCDROMReader", flag, w[1].equals("physical")); break;
                    case "DELETE": call("deleteCDROMReader", none); break;
                    case "OPEN": r = call("openCDROM", bytes, (Object) w[1].getBytes("UTF-8")); break;
                    case "CLOSE": call("closeCDROM", none); break;
                    case "INFO":
                        String[] drives = (String[]) call("listCDROMDrives", none);
                        r = call("getVersion", none) + " " + (drives == null ? null : java.util.Arrays.asList(drives));
                        break;
                    case "COPY": Files.copy(Paths.get(w[1]), Paths.get(w[2]), StandardCopyOption.REPLACE_EXISTING); break;
                    case "REMOVE": Files.delete(Paths.get(w[1])); break;
                    }
                    log.println(n + " " + w[0] + " " + r);
                    continue;
                }
                req.clear(); req.put(rec); resp.clear(); resp.put(zero);
                int ret = (Integer) call("executeCDROMSCSICmd", buffers, req, resp);
                int len = Math.max(0, Math.min(ret, out.length)), head = Math.min(len, 61);
                resp.rewind(); resp.get(out, 0, len);
                req.rewind(); req.get(after);
                MessageDigest sha = MessageDigest.getInstance("SHA-1");
                sha.update(out, head, len - head);
                log.println(n + " ret=" + ret + " " + hex(out, 0, head) + " data=" + hex(sha.digest(), 0, 20)
                    + (java.util.Arrays.equals(rec, after) ? "" : " REQUEST-MODIFIED"));
            }
        }
    }
}
