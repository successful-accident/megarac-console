// SPDX-FileCopyrightText: 2026 Jeff Morrison
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MegaRAC Console opens the Java remote console (AMI's JViewer) of an older AMI
// MegaRAC SP BMC without a browser or Java Web Start. It logs in through the
// BMC's web API, fetches the console's launch file (JNLP) and the viewer jars it
// names, then runs the viewer in a second Java 8 process, wrapped by Fit
// (Fit.java). The login is kept in the operating system's credential store.
//
//   megarac-console              open the console
//   megarac-console forget       delete the saved login and host
//   megarac-console --diagnose   check TLS, the login and the launch file, print a
//                                report with every secret removed, then log out
//
// BMC_HOST overrides the saved host. BMC_ISO=<image.iso> mounts that image as the
// server's virtual CD once video starts.
import java.awt.GraphicsEnvironment;
import java.awt.GridLayout;
import java.io.*;
import java.net.*;
import java.nio.file.*;
import java.security.cert.X509Certificate;
import java.security.interfaces.RSAPublicKey;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.prefs.Preferences;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import javax.net.ssl.*;
import javax.swing.*;
import javax.tools.JavaCompiler;
import javax.tools.ToolProvider;

import static java.nio.charset.StandardCharsets.UTF_8;

public class MegaracConsole {
    static final String NAME = "MegaRAC Console", ID = "megarac-console";
    static final String OS = System.getProperty("os.name");
    static final boolean MAC = OS.startsWith("Mac"), WIN = OS.startsWith("Windows");
    static final boolean HEADLESS = GraphicsEnvironment.isHeadless();
    // Set when this process was started again with the legacy TLS settings.
    static final boolean LEGACY = System.getProperty("megarac.legacy") != null;
    static final boolean STDIN_LOGIN = System.getProperty("megarac.login-on-stdin") != null;
    // megarac.prefs: the test suites use their own node, never this one.
    static final Preferences prefs = Preferences.userRoot().node(System.getProperty("megarac.prefs", ID));
    static final Pattern ARGUMENT = Pattern.compile("<argument>(.*?)</argument>", Pattern.DOTALL);
    static final String[] KNOWN_JARS = { "/Java/release/JViewer.jar", "/Java/release/JViewer-SOC.jar" };

    static Path classes, app; // where this class lives, and the install directory above it
    static String host = "", dir;
    static boolean fromEnv; // BMC_HOST chose the host: never saved over the remembered one
    static Path cache;
    static PrintStream log;
    static String cookie = "", csrf = "";
    static final List<String> secrets = new ArrayList<>(); // never written anywhere
    static Process child;
    static boolean loggedOut;
    static SSLSocketFactory tls;

    public static void main(String[] a) {
        try {
            launch(a);
        } catch (Exception e) {
            die(e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    static void launch(String[] a) throws Exception {
        String cmd = a.length > 0 ? a[0] : "";
        if (!Arrays.asList("", "forget", "--diagnose").contains(cmd) || a.length > 1) {
            System.err.println("usage: " + ID + " [forget | --diagnose]");
            System.exit(2);
        }
        classes = Paths.get(MegaracConsole.class.getProtectionDomain().getCodeSource().getLocation().toURI());
        app = classes.getParent();
        String env = System.getenv("BMC_HOST");
        fromEnv = env != null && !clean(env).isEmpty();
        host = fromEnv ? clean(env) : clean(prefs.get("host", ""));
        dir = safe(host);
        if (cmd.equals("forget")) {
            forget();
            return;
        }
        boolean diagnose = cmd.equals("--diagnose");
        if (!System.getProperty("java.version").startsWith("1.8."))
            die(NAME + " needs Java 8, because the BMC's viewer predates Java 9. This is Java "
                + System.getProperty("java.version") + ".");
        tls = trustAll();

        // The first run, or a relaunch that carries what was typed: ask before anything else.
        String[] typed = null;
        if (host.isEmpty() || STDIN_LOGIN) {
            typed = ask(host);
            host = typed[0];
            dir = safe(host);
        }
        cache = cacheRoot().resolve(dir);
        Files.createDirectories(cache);
        openLog();
        if (typed != null) secrets.add(typed[2]);

        // Older BMCs only speak TLS 1.0 or 1.1 with old keys, which Java 8 now refuses.
        // Those settings have to be in place when the JVM starts, so start again.
        if (!LEGACY && prefs.getBoolean("legacy-tls:" + dir, false)) relaunch(a, typed);
        String probe;
        try {
            probe = tlsProbe();
        } catch (SSLException e) {
            if (LEGACY) die("TLS to " + host + " failed even with the legacy settings: " + e.getMessage());
            say("tls: " + e.getMessage() + "; trying again with the legacy TLS settings for older BMCs");
            prefs.putBoolean("legacy-tls:" + dir, true);
            relaunch(a, typed);
            return;
        } catch (IOException e) {
            die("Cannot reach https://" + host + ": " + e.getMessage());
            return;
        }
        if (diagnose) {
            out("host: " + host);
            out("java: " + System.getProperty("java.version") + " (" + System.getProperty("java.vendor") + "), "
                + OS + " " + System.getProperty("os.arch"));
            out("tls: " + probe + (LEGACY ? ", with the legacy settings" : ""));
        }

        // Log in: a saved login, else ask. A saved login the BMC refuses is asked for again, once.
        String[] login = typed != null ? new String[] { typed[1], typed[2] } : savedLogin();
        boolean fromStore = typed == null && login != null;
        if (login == null) login = Arrays.copyOfRange(ask(host), 1, 3);
        secrets.add(login[1]);
        if (!createSession(login) && fromStore) {
            say("the BMC refused the saved login for " + login[0] + "@" + host + "; asking again");
            deleteLogin();
            fromStore = false;
            login = Arrays.copyOfRange(ask(host), 1, 3);
            secrets.add(login[1]);
            createSession(login);
        }
        if (cookie.isEmpty()) die("The BMC refused the login for " + login[0] + "@" + host + ".");
        // The BMC allows only four or five web sessions, so always give this one back.
        Runtime.getRuntime().addShutdownHook(new Thread(MegaracConsole::logout));
        secrets.add(cookie);
        secrets.add(csrf);
        if (!fromStore) saveLogin(login);
        if (!fromEnv) prefs.put("host", host);
        say("login: " + login[0] + "@" + host + ", CSRF token " + (csrf.isEmpty() ? "absent" : "present"));

        // The launch file carries the viewer's command line, including a one-time console token.
        String jnlp = text(open("/Java/jviewer.jnlp?EXTRNIP=" + URLEncoder.encode(address(), "UTF-8")
            + "&JNLPSTR=JViewer", 30));
        List<String> args = new ArrayList<>();
        for (Matcher m = ARGUMENT.matcher(jnlp); m.find(); ) args.add(xml(m.group(1)));
        for (int i = 0; i < args.size(); i++)
            if (secretLike(args.get(i)) || i > 0 && args.get(i - 1).toLowerCase(Locale.ROOT).matches("-.*(token|cookie|session).*"))
                secrets.add(args.get(i));
        if (diagnose) {
            report(jnlp, args);
            logout();
            System.exit(0);
        }
        if (args.isEmpty())
            die("The BMC did not return a console launch file. Does " + login[0] + " have administrator rights?");

        List<Path> jars = new ArrayList<>();
        for (Map.Entry<String, Boolean> j : jarPaths(jnlp).entrySet()) {
            Path jar = download(j.getKey(), cache.resolve(fileName(j.getKey())), j.getValue());
            if (jar != null) jars.add(jar);
        }
        Path lib = WIN ? windowsLibraries(jnlp) : app.resolve("lib");
        if (!Files.isDirectory(lib)) die("The media library is missing from " + lib + ". Run the installer again.");
        Path fit = cache.resolve("classes");
        String main = compileFit(jars, fit) ? "Fit" : mainClass(jnlp);
        runViewer(main, args, fit, jars, lib);
    }

    // ---- HTTPS to the BMC. Its certificate is self-signed, so nothing about it is checked,
    // for these connections only.

    static SSLSocketFactory trustAll() throws Exception {
        // X509ExtendedTrustManager, not X509TrustManager: Java wraps the latter and still
        // rejects certificates that use old algorithms.
        TrustManager all = new X509ExtendedTrustManager() {
            public void checkClientTrusted(X509Certificate[] c, String t) {}
            public void checkServerTrusted(X509Certificate[] c, String t) {}
            public void checkClientTrusted(X509Certificate[] c, String t, Socket s) {}
            public void checkServerTrusted(X509Certificate[] c, String t, Socket s) {}
            public void checkClientTrusted(X509Certificate[] c, String t, SSLEngine e) {}
            public void checkServerTrusted(X509Certificate[] c, String t, SSLEngine e) {}
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        };
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(null, new TrustManager[] { all }, null);
        return context.getSocketFactory();
    }

    // Connects once to report what TLS the BMC speaks, and to find out early if it needs
    // the legacy settings.
    static String tlsProbe() throws IOException {
        URI u = URI.create("https://" + host + "/");
        try (SSLSocket s = (SSLSocket) tls.createSocket()) {
            s.connect(new InetSocketAddress(address(), u.getPort() < 0 ? 443 : u.getPort()), 20000);
            s.setSoTimeout(20000);
            s.startHandshake();
            SSLSession session = s.getSession();
            X509Certificate cert = (X509Certificate) session.getPeerCertificates()[0];
            String key = cert.getPublicKey().getAlgorithm();
            if (cert.getPublicKey() instanceof RSAPublicKey)
                key += " " + ((RSAPublicKey) cert.getPublicKey()).getModulus().bitLength() + "-bit";
            return session.getProtocol() + ", " + session.getCipherSuite() + ", certificate " + key + " signed "
                + cert.getSigAlgName();
        }
    }

    // A pasted web address works too: https://bmc/ is the host bmc.
    static String clean(String h) {
        return h.trim().replaceFirst("(?i)^https?://", "").replaceFirst("/.*$", "");
    }

    // The host, made safe for file names.
    static String safe(String h) {
        return h.replaceAll("[^A-Za-z0-9.-]", "_");
    }

    // The host name or address alone: no port, no brackets.
    static String address() {
        String h = URI.create("https://" + host + "/").getHost();
        return h != null && h.startsWith("[") ? h.substring(1, h.length() - 1) : String.valueOf(h);
    }

    static HttpsURLConnection open(String path, int seconds) throws IOException {
        HttpsURLConnection c = (HttpsURLConnection) new URL("https://" + host + path).openConnection(Proxy.NO_PROXY);
        c.setSSLSocketFactory(tls);
        c.setHostnameVerifier((h, s) -> true);
        c.setConnectTimeout(seconds * 1000);
        c.setReadTimeout(seconds * 1000);
        c.setInstanceFollowRedirects(false);
        if (!cookie.isEmpty()) c.setRequestProperty("Cookie", "SessionCookie=" + cookie);
        if (!csrf.isEmpty()) c.setRequestProperty("CSRFTOKEN", csrf);
        return c;
    }

    static String text(HttpsURLConnection c) throws IOException {
        InputStream in = c.getResponseCode() < 400 ? c.getInputStream() : c.getErrorStream();
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        if (in != null) try (InputStream i = in) { copy(i, b); }
        return new String(b.toByteArray(), UTF_8);
    }

    // The reply is JavaScript, not JSON, with the fields as 'NAME' : 'value'. Older
    // firmware sends no CSRF token. A refused login has a cookie starting "Failure".
    static boolean createSession(String[] login) throws IOException {
        HttpsURLConnection c = open("/rpc/WEBSES/create.asp", 20);
        c.setDoOutput(true);
        c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
        try (OutputStream o = c.getOutputStream()) {
            o.write(("WEBVAR_USERNAME=" + form(login[0]) + "&WEBVAR_PASSWORD=" + form(login[1])).getBytes(UTF_8));
        }
        String reply = text(c);
        cookie = field(reply, "SESSION_COOKIE");
        csrf = field(reply, "CSRFTOKEN");
        if (cookie.isEmpty() || cookie.startsWith("Failure")) cookie = csrf = "";
        return !cookie.isEmpty();
    }

    // Encoded byte for byte as curl --data-urlencode does it, which is what the BMC has seen:
    // a space as +, * as %2A, ~ as itself. test-launcher.sh compares the two.
    static String form(String s) throws UnsupportedEncodingException {
        return URLEncoder.encode(s, "UTF-8").replace("*", "%2A").replace("%7E", "~");
    }

    static String field(String reply, String name) {
        Matcher m = Pattern.compile("'" + name + "' *: *'([^']*)'").matcher(reply);
        return m.find() ? m.group(1) : "";
    }

    static synchronized void logout() {
        if (cookie.isEmpty() || loggedOut) return;
        loggedOut = true;
        if (child != null && child.isAlive()) child.destroy();
        try {
            HttpsURLConnection c = open("/rpc/WEBSES/logout.asp", 10);
            say("logout: HTTP " + c.getResponseCode());
            c.disconnect();
        } catch (IOException e) {
            say("logout failed: " + e.getMessage());
        }
    }

    // ---- The launch file, the jars and the native libraries.

    static String xml(String s) {
        return s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'")
            .replace("&amp;", "&");
    }

    // Values that may be tokens: long, no spaces, not an option name, not the host.
    static boolean secretLike(String s) {
        return !s.startsWith("-") && s.length() >= 12 && !s.matches(".*\\s.*") && !s.equalsIgnoreCase(address());
    }

    static String first(String regex, String text, String otherwise) {
        Matcher m = Pattern.compile(regex, Pattern.DOTALL).matcher(text);
        return m.find() ? m.group(1) : otherwise;
    }

    static String mainClass(String jnlp) {
        return first("<application-desc\\b[^>]*\\bmain-class=\"([^\"]+)\"", jnlp, "com.ami.kvm.jviewer.JViewer");
    }

    // A jar's path on the BMC, from its href and the launch file's codebase.
    static String resolve(String jnlp, String href) {
        String base = URI.create(first("<jnlp\\b[^>]*\\bcodebase=\"([^\"]+)\"", jnlp, "https://x/Java")).getRawPath();
        URI dirUri = URI.create("https://x" + (base == null || base.isEmpty() ? "/" : base.endsWith("/") ? base : base + "/"));
        return (href.matches("(?i)https?://.*") ? URI.create(href) : dirUri.resolve(href)).getRawPath();
    }

    // Path -> whether the launch file lists it. The two jars every known firmware serves are
    // fetched too; one the launch file doesn't list may be missing.
    static Map<String, Boolean> jarPaths(String jnlp) {
        Map<String, Boolean> paths = new LinkedHashMap<>();
        for (Matcher m = Pattern.compile("<jar\\b[^>]*\\bhref=\"([^\"]+)\"").matcher(jnlp); m.find(); )
            paths.put(resolve(jnlp, m.group(1)), true);
        for (String known : KNOWN_JARS) if (!paths.containsKey(known)) paths.put(known, false);
        return paths;
    }

    static String fileName(String path) {
        return path.substring(path.lastIndexOf('/') + 1);
    }

    // Downloads beside the old copy, then replaces it: a viewer that is already running keeps
    // the jar it opened.
    static Path download(String path, Path to, boolean required) throws IOException {
        HttpsURLConnection c = open(path, 30);
        if (c.getResponseCode() != 200) {
            if (required) die("Cannot download " + path + " from the BMC (HTTP " + c.getResponseCode() + ").");
            say("download " + path + ": HTTP " + c.getResponseCode() + ", not needed");
            return null;
        }
        Path part = to.resolveSibling(to.getFileName() + ".part");
        try (InputStream in = c.getInputStream()) {
            Files.copy(in, part, StandardCopyOption.REPLACE_EXISTING);
        }
        try {
            Files.move(part, to, StandardCopyOption.REPLACE_EXISTING);
        } catch (FileSystemException e) {
            die(NAME + " is already open for " + host + ".");
        }
        say("download " + path + ": " + Files.size(to) + " bytes");
        return to;
    }

    // On Windows the viewer uses the BMC's own media libraries, from the launch file's
    // Windows x64 resources.
    static Path windowsLibraries(String jnlp) throws IOException {
        String href = "release/Win64.jar";
        for (Matcher m = Pattern.compile("<resources\\b([^>]*)>(.*?)</resources>", Pattern.DOTALL).matcher(jnlp); m.find(); )
            if (m.group(1).contains("os=\"Windows\"") && m.group(1).matches("(?s).*arch=\"(amd64|x86_64)\".*"))
                href = first("<nativelib\\b[^>]*\\bhref=\"([^\"]+)\"", m.group(2), href);
        String path = resolve(jnlp, href);
        Path jar = download(path, cache.resolve(fileName(path)), true);
        Path lib = cache.resolve("lib");
        try {
            deleteTree(lib);
        } catch (IOException e) {
            die(NAME + " is already open for " + host + ".");
        }
        Files.createDirectories(lib);
        try (ZipInputStream z = new ZipInputStream(Files.newInputStream(jar))) {
            for (ZipEntry e; (e = z.getNextEntry()) != null; )
                if (e.getName().toLowerCase(Locale.ROOT).endsWith(".dll"))
                    Files.copy(z, lib.resolve(fileName(e.getName())), StandardCopyOption.REPLACE_EXISTING);
        }
        return lib;
    }

    // Fit is compiled against the jars this BMC serves. If its API differs from the one Fit
    // was written for, the viewer runs without Fit's fixes.
    static boolean compileFit(List<Path> jars, Path out) throws IOException {
        JavaCompiler javac = ToolProvider.getSystemJavaCompiler();
        if (javac == null) die(NAME + " needs a Java 8 JDK; this Java is only a runtime (JRE).");
        deleteTree(out);
        Files.createDirectories(out);
        StringWriter errors = new StringWriter();
        boolean ok = javac.getTask(errors, null, null,
            Arrays.asList("-nowarn", "-encoding", "UTF-8", "-cp", join(jars), "-d", out.toString()), null,
            javac.getStandardFileManager(null, null, UTF_8).getJavaFileObjects(app.resolve("Fit.java").toFile()))
            .call();
        say(ok ? "fit: compiled" : "fit: does not compile against this viewer, so it runs without Fit:\n" + errors);
        return ok;
    }

    static String join(List<Path> paths) {
        StringBuilder s = new StringBuilder();
        for (Path p : paths) s.append(s.length() > 0 ? File.pathSeparator : "").append(p);
        return s.toString();
    }

    static String java(String name) {
        return Paths.get(System.getProperty("java.home"), "bin", WIN ? name + ".exe" : name).toString();
    }

    static void runViewer(String main, List<String> args, Path fit, List<Path> jars, Path lib) throws Exception {
        List<Path> cp = new ArrayList<>(jars);
        cp.add(0, fit);
        List<String> cmd = new ArrayList<>(Collections.singletonList(java(WIN ? "javaw" : "java")));
        if (MAC) cmd.addAll(Arrays.asList("-Xdock:name=" + NAME, "-Xdock:icon=" + app.resolve("AppIcon.icns")));
        if (LEGACY) cmd.add("-Djava.security.properties=" + app.resolve("legacy-tls.security"));
        // Extra options for the viewer's Java, such as -Dsun.java2d.uiScale=2 or -Dos.name=Linux.
        String opts = System.getenv("MEGARAC_JAVA_OPTS");
        if (opts != null && !opts.trim().isEmpty()) cmd.addAll(Arrays.asList(opts.trim().split("\\s+")));
        cmd.addAll(Arrays.asList("-Djava.library.path=" + lib, "-cp", join(cp), main));
        // Fit reads the viewer's arguments from stdin, so the session cookie and console token
        // never appear in a process listing. The viewer alone can only take them as arguments.
        boolean viaStdin = main.equals("Fit");
        if (!viaStdin) cmd.addAll(args);
        ProcessBuilder pb = new ProcessBuilder(cmd).redirectErrorStream(true);
        if (WIN) pb.directory(cache.toFile()); // the viewer's fallback looks in <cwd>\lib
        say("viewer: " + main + (LEGACY ? ", legacy TLS" : ""));
        child = pb.start();
        try (OutputStream o = child.getOutputStream()) {
            if (viaStdin) for (String s : args) o.write((s + "\0").getBytes(UTF_8));
        }
        try (BufferedReader r = new BufferedReader(new InputStreamReader(child.getInputStream(), UTF_8))) {
            for (String line; (line = r.readLine()) != null; ) {
                String s = scrub(line);
                System.out.println(s);
                log.println(s);
            }
        }
        int code = child.waitFor();
        say("viewer: exited " + code);
        logout();
        System.exit(code);
    }

    // Starts this launcher again with the legacy TLS settings. A login typed this run goes
    // along on stdin; the host is saved first, since it is not secret.
    static void relaunch(String[] a, String[] typed) throws Exception {
        if (typed != null && !fromEnv) prefs.put("host", host);
        List<String> cmd = new ArrayList<>(Arrays.asList(java(WIN ? "javaw" : "java"), "-Dmegarac.legacy=1",
            "-Djava.security.properties=" + app.resolve("legacy-tls.security")));
        if (MAC) cmd.add("-Dapple.awt.UIElement=true");
        if (typed != null) cmd.add("-Dmegarac.login-on-stdin=1");
        cmd.addAll(Arrays.asList("-cp", classes.toString(), MegaracConsole.class.getName()));
        cmd.addAll(Arrays.asList(a));
        ProcessBuilder pb = new ProcessBuilder(cmd).inheritIO();
        if (typed != null) pb.redirectInput(ProcessBuilder.Redirect.PIPE);
        Process p = pb.start();
        if (typed != null) try (Writer w = new OutputStreamWriter(p.getOutputStream(), UTF_8)) {
            w.write(typed[1] + "\n" + typed[2] + "\n");
        }
        System.exit(p.waitFor());
    }

    // ---- The diagnosis: everything a bug report needs, and no secret.

    static void report(String jnlp, List<String> args) throws IOException {
        out("login: accepted, CSRF token " + (csrf.isEmpty() ? "absent" : "present"));
        out("launch file: " + args.size() + " arguments, main class " + mainClass(jnlp));
        StringBuffer redacted = new StringBuffer();
        Matcher m = ARGUMENT.matcher(jnlp);
        while (m.find()) {
            String v = xml(m.group(1));
            m.appendReplacement(redacted, Matcher.quoteReplacement("<argument>"
                + (secretLike(v) || secrets.contains(v) ? "(redacted, " + v.length() + " characters)" : m.group(1))
                + "</argument>"));
        }
        m.appendTail(redacted);
        out("---- launch file, secrets redacted ----\n" + scrub(redacted.toString()).trim());
        out("---- jars ----");
        Path d = cache.resolve("diagnose");
        Files.createDirectories(d);
        for (Map.Entry<String, Boolean> j : jarPaths(jnlp).entrySet()) {
            HttpsURLConnection c = open(j.getKey(), 30);
            int code = c.getResponseCode();
            long size = code == 200 ? Files.copy(c.getInputStream(), d.resolve(fileName(j.getKey())),
                StandardCopyOption.REPLACE_EXISTING) : 0;
            out(j.getKey() + (j.getValue() ? "" : " (not listed)") + ": HTTP " + code + (code == 200 ? ", " + size + " bytes" : ""));
        }
        out("---- native libraries, per platform ----");
        for (Matcher r = Pattern.compile("<resources\\b([^>]*)>(.*?)</resources>", Pattern.DOTALL).matcher(jnlp); r.find(); )
            for (Matcher n = Pattern.compile("<nativelib\\b[^>]*\\bhref=\"([^\"]+)\"").matcher(r.group(2)); n.find(); ) {
                String path = resolve(jnlp, n.group(1));
                HttpsURLConnection c = open(path, 30);
                out(r.group(1).trim() + ": " + path + ", HTTP " + c.getResponseCode());
                if (c.getResponseCode() != 200) continue;
                // Kept beside the jars: test-media.sh --intel takes Mac64.jar from here.
                Path saved = d.resolve(fileName(path));
                Files.copy(c.getInputStream(), saved, StandardCopyOption.REPLACE_EXISTING);
                try (ZipInputStream z = new ZipInputStream(Files.newInputStream(saved))) {
                    for (ZipEntry e; (e = z.getNextEntry()) != null; ) {
                        long size = 0;
                        for (byte[] b = new byte[8192]; ; ) {
                            int k = z.read(b);
                            if (k < 0) break;
                            size += k;
                        }
                        out("    " + e.getName() + ", " + size + " bytes");
                    }
                }
            }
    }

    // ---- The saved login: the macOS Keychain, the Windows account's DPAPI, or the
    // freedesktop Secret Service through secret-tool. Without one, ask every time.

    static final String UTF8_CONSOLE =
        "[Console]::InputEncoding = [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false; ";

    static String service() {
        return ID + ":" + host;
    }

    static String[] savedLogin() {
        if (MAC) {
            String found = run(null, "security", "find-generic-password", "-s", service());
            String pass = run(null, "security", "find-generic-password", "-s", service(), "-w");
            String user = found == null ? "" : first("\"acct\"<blob>=\"([^\"\\n]*)\"", found, "");
            return pass == null || user.isEmpty() ? null : new String[] { user, chomp(pass) };
        }
        if (WIN) {
            try {
                List<String> f = Files.readAllLines(windowsLogin(), UTF_8);
                String pass = run(f.get(1) + "\n", "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                    UTF8_CONSOLE + "$s = [Console]::In.ReadLine() | ConvertTo-SecureString; (New-Object Net.NetworkCredential('', $s)).Password");
                return pass == null ? null : new String[] { f.get(0), chomp(pass) };
            } catch (IOException | IndexOutOfBoundsException e) {
                return null;
            }
        }
        String s = run(null, "secret-tool", "lookup", "service", service());
        return s == null || !chomp(s).contains("\n") ? null : chomp(s).split("\n", 2);
    }

    static void saveLogin(String[] login) {
        if (MAC) {
            // Through stdin, so the password is never on a command line. If security reads
            // it back differently, fall back to the argument form.
            run("add-generic-password -U -s " + quote(service()) + " -a " + quote(login[0]) + " -w " + quote(login[1])
                + "\nexit\n", "security", "-i");
            String[] back = savedLogin();
            if ((back == null || !Arrays.equals(back, login))
                && run(null, "security", "add-generic-password", "-U", "-s", service(), "-a", login[0], "-w", login[1]) == null)
                say("could not save the login in the Keychain");
        } else if (WIN) {
            String blob = run(login[1] + "\n", "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                UTF8_CONSOLE + "[Console]::In.ReadLine() | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString");
            try {
                if (blob == null) say("could not save the login: PowerShell did not answer");
                else Files.write(windowsLogin(), Arrays.asList(login[0], blob.trim()), UTF_8);
            } catch (IOException e) {
                say("could not save the login: " + e.getMessage());
            }
        } else if (run(login[0] + "\n" + login[1], "secret-tool", "store", "--label=" + NAME + " (" + host + ")",
            "service", service()) == null) {
            say("no keyring (secret-tool), so the login is not saved");
        }
    }

    static void deleteLogin() {
        if (MAC) run(null, "security", "delete-generic-password", "-s", service());
        else if (WIN) windowsLogin().toFile().delete();
        else run(null, "secret-tool", "clear", "service", service());
    }

    static Path windowsLogin() {
        return Paths.get(System.getenv("LOCALAPPDATA"), ID, "login-" + dir + ".txt");
    }

    static void forget() {
        if (host.isEmpty()) {
            System.out.println("nothing saved");
            return;
        }
        deleteLogin();
        prefs.remove("legacy-tls:" + dir);
        if (host.equals(prefs.get("host", ""))) prefs.remove("host");
        System.out.println("forgot " + service());
    }

    static String quote(String s) {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }

    static String chomp(String s) {
        return s.endsWith("\r\n") ? s.substring(0, s.length() - 2) : s.endsWith("\n") ? s.substring(0, s.length() - 1) : s;
    }

    // Runs a helper with a 20 s limit; its output, or null if it is missing or fails.
    static String run(String input, String... cmd) {
        try {
            Process p = new ProcessBuilder(cmd).redirectError(ProcessBuilder.Redirect.to(new File(WIN ? "NUL" : "/dev/null")))
                .start();
            try (OutputStream o = p.getOutputStream()) {
                if (input != null) o.write(input.getBytes(UTF_8));
            }
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            Thread reader = new Thread(() -> {
                try {
                    copy(p.getInputStream(), b);
                } catch (IOException ignored) {
                }
            });
            reader.start();
            if (!p.waitFor(20, TimeUnit.SECONDS)) {
                p.destroyForcibly();
                say(cmd[0] + (cmd.length > 1 ? " " + cmd[1] : "") + ": no answer in 20 s"); // never the rest: it may hold the password
                return null;
            }
            reader.join(2000);
            return p.exitValue() == 0 ? new String(b.toByteArray(), UTF_8) : null;
        } catch (IOException | InterruptedException e) {
            return null;
        }
    }

    // ---- Talking to the person.

    // Host (when none is known), user and password, from a dialog or, without a display, stdin.
    static String[] ask(String h) {
        if (HEADLESS || STDIN_LOGIN) {
            BufferedReader in = new BufferedReader(new InputStreamReader(System.in, UTF_8));
            if (h.isEmpty()) h = clean(prompt(in, "BMC address: "));
            String user = prompt(in, "BMC user for " + h + ": ").trim();
            Console console = System.console();
            String pass = console != null ? new String(console.readPassword("Password: ")) : prompt(in, "Password: ");
            if (h.isEmpty() || user.isEmpty()) die("No BMC address or user given.");
            return new String[] { h, user, pass };
        }
        JTextField hostField = new JTextField(h, 24), userField = new JTextField("admin", 24);
        JPasswordField passField = new JPasswordField(24);
        JPanel panel = new JPanel(new GridLayout(0, 1, 0, 4));
        if (h.isEmpty()) {
            panel.add(new JLabel("BMC address"));
            panel.add(hostField);
        } else {
            panel.add(new JLabel("Log in to " + h));
        }
        panel.add(new JLabel("User"));
        panel.add(userField);
        panel.add(new JLabel("Password"));
        panel.add(passField);
        JOptionPane pane = new JOptionPane(panel, JOptionPane.PLAIN_MESSAGE, JOptionPane.OK_CANCEL_OPTION);
        JDialog d = pane.createDialog(NAME);
        d.setAlwaysOnTop(true);
        d.setVisible(true);
        d.dispose();
        if (!Integer.valueOf(JOptionPane.OK_OPTION).equals(pane.getValue())) System.exit(0);
        String[] r = { clean(hostField.getText()), userField.getText().trim(), new String(passField.getPassword()) };
        if (r[0].isEmpty() || r[1].isEmpty()) die("No BMC address or user given.");
        return r;
    }

    static String prompt(BufferedReader in, String label) {
        System.err.print(label);
        try {
            String s = in.readLine();
            if (s != null) return s;
        } catch (IOException ignored) {
        }
        die("No answer for \"" + label.trim() + "\".");
        return "";
    }

    static Path cacheRoot() {
        if (MAC) return Paths.get(System.getProperty("user.home"), "Library", "Caches", ID);
        if (WIN) return Paths.get(System.getenv("LOCALAPPDATA"), ID, "cache");
        return xdg("XDG_CACHE_HOME", ".cache").resolve(ID);
    }

    static Path logFile() {
        if (MAC) return Paths.get(System.getProperty("user.home"), "Library", "Logs", ID + ".log");
        if (WIN) return Paths.get(System.getenv("LOCALAPPDATA"), ID, ID + ".log");
        return xdg("XDG_STATE_HOME", ".local/state").resolve(ID).resolve(ID + ".log");
    }

    static Path xdg(String var, String fallback) {
        String v = System.getenv(var);
        return v != null && !v.isEmpty() ? Paths.get(v) : Paths.get(System.getProperty("user.home"), fallback);
    }

    static void openLog() throws IOException {
        Files.createDirectories(logFile().getParent());
        log = new PrintStream(new FileOutputStream(logFile().toFile()), true, "UTF-8");
    }

    static String scrub(String s) {
        for (String secret : secrets) if (secret != null && secret.length() >= 4) s = s.replace(secret, "(redacted)");
        return s;
    }

    static void say(String msg) {
        String s = scrub(msg);
        System.err.println(ID + ": " + s);
        if (log != null) log.println(s);
    }

    static void out(String msg) {
        String s = scrub(msg);
        System.out.println(s);
        if (log != null) log.println(s);
    }

    static void die(String msg) {
        say(msg);
        if (!HEADLESS) {
            JDialog d = new JOptionPane(scrub(msg), JOptionPane.ERROR_MESSAGE).createDialog(NAME);
            d.setAlwaysOnTop(true);
            d.setVisible(true);
            d.dispose();
        }
        System.exit(1);
    }

    static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] b = new byte[8192];
        for (int n; (n = in.read(b)) > 0; ) out.write(b, 0, n);
    }

    static void deleteTree(Path p) throws IOException {
        if (!Files.exists(p)) return;
        if (Files.isDirectory(p)) try (DirectoryStream<Path> s = Files.newDirectoryStream(p)) {
            for (Path q : s) deleteTree(q);
        }
        Files.delete(p);
    }
}
