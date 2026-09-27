package com.lunavect.sessions;

import com.google.gson.*;
import com.intellij.openapi.Disposable;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.application.PathManager;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.project.ProjectManager;
import com.intellij.openapi.wm.IdeFocusManager;
import com.intellij.openapi.wm.ToolWindow;
import com.intellij.openapi.wm.ToolWindowManager;
import com.intellij.openapi.wm.WindowManager;
import com.intellij.terminal.frontend.toolwindow.TerminalToolWindowTab;
import com.intellij.terminal.frontend.toolwindow.TerminalToolWindowTabsManager;
import com.intellij.terminal.frontend.view.TerminalView;
import com.intellij.terminal.frontend.view.TerminalViewSessionState;
import com.intellij.ui.content.Content;
import org.jetbrains.plugins.terminal.ShellTerminalWidget;
import org.jetbrains.plugins.terminal.TerminalToolWindowManager;

import javax.swing.*;
import java.awt.*;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.time.Instant;
import java.util.*;
import java.util.List;
import java.util.concurrent.*;

/** User-owned local focus endpoint. Never reads terminal output or sends shell input. */
public final class BridgeService implements Disposable {
    private final ScheduledExecutorService workers = Executors.newScheduledThreadPool(4, task -> {
        Thread thread = new Thread(task, "Lunavect IDE focus"); thread.setDaemon(true); return thread;
    });
    private final Set<SocketChannel> clients = ConcurrentHashMap.newKeySet();
    private ServerSocketChannel server;
    private Path descriptorPath, socketPath;
    private volatile boolean disposed;
    private final String id = UUID.randomUUID().toString();
    private final Gson gson = new Gson();

    public BridgeService() {
        workers.execute(() -> {
            try { start(); }
            catch (Exception failure) { dispose(); }
        });
    }

    private void start() throws Exception {
        if (!System.getProperty("os.name", "").startsWith("Mac")) return;
        Path home = Path.of(System.getProperty("user.home"));
        int uid = ((Number) Files.getAttribute(home, "unix:uid")).intValue();
        Path root = home.resolve("Library/Application Support/Lunavect/IDEBridge");
        Path sockets = Path.of("/tmp/lunavect-ide-" + uid);
        privateDirectory(root, uid); privateDirectory(sockets, uid);
        Path app = Path.of(PathManager.getHomePath());
        while (app != null && !app.toString().endsWith(".app")) app = app.getParent();
        if (app == null) throw new IOException("IDE application bundle is unavailable");
        Process plist = new ProcessBuilder("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier",
                app.resolve("Contents/Info.plist").toString()).start();
        if (!plist.waitFor(2, TimeUnit.SECONDS) || plist.exitValue() != 0) { plist.destroyForcibly(); throw new IOException("IDE identity is unavailable"); }
        String bundle = new String(plist.getInputStream().readNBytes(200), StandardCharsets.UTF_8).trim();
        if (!bundle.startsWith("com.jetbrains.")) throw new IOException("Unsupported IDE identity");
        socketPath = sockets.resolve(id + ".sock"); descriptorPath = root.resolve(id + ".json");
        server = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
        server.bind(UnixDomainSocketAddress.of(socketPath));
        Files.setPosixFilePermissions(socketPath, PosixFilePermissions.fromString("rw-------"));
        JsonObject descriptor = new JsonObject();
        descriptor.addProperty("version", 1); descriptor.addProperty("id", id); descriptor.addProperty("editor", "jetbrains");
        descriptor.addProperty("pid", ProcessHandle.current().pid()); descriptor.addProperty("appPath", app.toString());
        descriptor.addProperty("bundleIdentifier", bundle); descriptor.addProperty("socketPath", socketPath.toString());
        publish(descriptor);
        workers.scheduleWithFixedDelay(() -> { try { publish(descriptor); } catch (IOException ignored) {} }, 30, 30, TimeUnit.SECONDS);
        while (!disposed) {
            SocketChannel client = server.accept();
            if (clients.size() >= 8) { client.close(); continue; }
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
            clients.add(client); workers.execute(() -> handle(client, deadline));
        }
    }

    private static void privateDirectory(Path directory, int uid) throws IOException {
        Files.createDirectories(directory);
        if (Files.isSymbolicLink(directory) || !Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS) ||
                ((Number) Files.getAttribute(directory, "unix:uid", LinkOption.NOFOLLOW_LINKS)).intValue() != uid) throw new IOException("Unsafe bridge directory");
        Files.setPosixFilePermissions(directory, PosixFilePermissions.fromString("rwx------"));
    }

    private void publish(JsonObject descriptor) throws IOException {
        if (disposed) return;
        descriptor.addProperty("updatedAt", Instant.now().toEpochMilli() / 1000.0);
        Path temporary = descriptorPath.resolveSibling(id + ".tmp");
        try {
            Files.writeString(temporary, gson.toJson(descriptor), StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
            Files.setPosixFilePermissions(temporary, PosixFilePermissions.fromString("rw-------"));
            if (disposed) return;
            Files.move(temporary, descriptorPath, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally {
            // Shutdown may race either the write or the rename. Do not wait on
            // disk I/O on the IDE thread; the last publisher retires its output.
            try { Files.deleteIfExists(temporary); }
            finally { if (disposed) Files.deleteIfExists(descriptorPath); }
        }
    }

    private void handle(SocketChannel client, long deadline) {
        try (client; Selector selector = Selector.open()) {
            client.configureBlocking(false); client.register(selector, SelectionKey.OP_READ);
            ByteBuffer bytes = ByteBuffer.allocate(16385);
            String request = null;
            while (System.nanoTime() < deadline && bytes.hasRemaining()) {
                if (selector.select(500) == 0) continue;
                selector.selectedKeys().clear();
                int count = client.read(bytes);
                if (count < 0) return;
                for (int i = 0; i < bytes.position(); i++) if (bytes.get(i) == '\n') {
                    request = new String(bytes.array(), 0, i, StandardCharsets.UTF_8); break;
                }
                if (request != null) break;
            }
            if (request == null || request.length() > 16384 || System.nanoTime() >= deadline) return;
            JsonObject message = JsonParser.parseString(request).getAsJsonObject();
            JsonObject reply = route(message, deadline);
            ByteBuffer response = StandardCharsets.UTF_8.encode(gson.toJson(reply) + "\n");
            client.keyFor(selector).interestOps(SelectionKey.OP_WRITE);
            while (response.hasRemaining() && System.nanoTime() < deadline) {
                if (selector.select(500) == 0) continue;
                selector.selectedKeys().clear(); client.write(response);
            }
        } catch (Exception ignored) {
            // Invalid/stale clients receive no focus; never log their session metadata.
        } finally { clients.remove(client); }
    }

    private JsonObject route(JsonObject message, long deadline) throws Exception {
        if (message.get("version").getAsInt() != 1) return status("unsupported");
        String action = message.get("action").getAsString();
        if (!Set.of("probe", "open").contains(action)) return status("unsupported");
        JsonObject target = message.getAsJsonObject("target");
        if (!target.get("kind").getAsString().equals("terminal")) return status("unsupportedProvider");
        JsonArray ancestors = target.getAsJsonArray("ancestors");
        if (ancestors == null || ancestors.isEmpty() || ancestors.size() > 24) return status("unsupported");
        Set<Long> pids = new HashSet<>();
        for (JsonElement element : ancestors) {
            long pid = element.getAsLong();
            if (pid <= 1 || pid > Integer.MAX_VALUE || element.getAsDouble() != pid) return status("unsupported");
            pids.add(pid);
        }
        CompletableFuture<JsonObject> result = new CompletableFuture<>();
        ApplicationManager.getApplication().invokeLater(() -> {
            if (result.isDone() || disposed || System.nanoTime() >= deadline) { result.cancel(false); return; }
            try {
                List<TerminalMatch> matches = findTerminals(pids);
                if (matches.size() != 1) { result.complete(status(matches.isEmpty() ? "notFound" : "ambiguous")); return; }
                TerminalMatch match = matches.getFirst();
                if (action.equals("open")) { focus(match, result); return; }
                JsonObject reply = status("matched");
                reply.addProperty("shellPID", match.pid); result.complete(reply);
            } catch (Throwable failure) { result.complete(status("failed")); }
        });
        try { return result.get(Math.max(1, Math.min(TimeUnit.SECONDS.toNanos(5), deadline - System.nanoTime())), TimeUnit.NANOSECONDS); }
        catch (TimeoutException timeout) { result.cancel(false); return status("timeout"); }
    }

    private record TerminalMatch(Project project, Content content, JComponent component, long pid) {}

    private static List<TerminalMatch> findTerminals(Set<Long> pids) {
        List<TerminalMatch> result = new ArrayList<>();
        for (Project project : ProjectManager.getInstance().getOpenProjects()) {
            if (project.isDisposed()) continue;
            ToolWindow toolWindow = ToolWindowManager.getInstance(project).getToolWindow("Terminal");
            if (toolWindow == null) continue;
            for (TerminalToolWindowTab tab : TerminalToolWindowTabsManager.getInstance(project).getTabs()) {
                TerminalView view = tab.getView();
                if (!(view.getSessionState().getValue() instanceof TerminalViewSessionState.Running)) continue;
                if (!view.getStartupOptionsDeferred().isCompleted() || view.getStartupOptionsDeferred().isCancelled()) continue;
                Long pid = view.getStartupOptionsDeferred().getCompleted().getPid();
                if (pid != null && pids.contains(pid)) result.add(new TerminalMatch(project, tab.getContent(), view.getPreferredFocusableComponent(), pid));
            }
            // Classic terminal tabs use a different API; never cast Reworked tabs to it.
            for (Content content : toolWindow.getContentManager().getContentsRecursively()) {
                var widget = TerminalToolWindowManager.getWidgetByContent(content);
                if (!(widget instanceof ShellTerminalWidget shell)) continue;
                var connector = shell.getProcessTtyConnector();
                if (connector == null || !connector.isConnected()) continue;
                long pid = connector.getProcess().pid();
                if (pids.contains(pid)) result.add(new TerminalMatch(project, content, shell.getPreferredFocusableComponent(), pid));
            }
        }
        return result;
    }

    private static void focus(TerminalMatch match, CompletableFuture<JsonObject> result) {
        JFrame frame = WindowManager.getInstance().getFrame(match.project);
        if (frame != null) { frame.setExtendedState(frame.getExtendedState() & ~Frame.ICONIFIED); frame.toFront(); frame.requestFocus(); }
        match.content.getManager().setSelectedContent(match.content, true);
        ToolWindow toolWindow = ToolWindowManager.getInstance(match.project).getToolWindow("Terminal");
        toolWindow.activate(() -> IdeFocusManager.getInstance(match.project).requestFocus(match.component, true), true);
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(2500);
        javax.swing.Timer timer = new javax.swing.Timer(25, null);
        timer.addActionListener(event -> {
            if (result.isDone()) { timer.stop(); return; }
            Component owner = KeyboardFocusManager.getCurrentKeyboardFocusManager().getFocusOwner();
            if (frame != null && frame.isFocused() && owner != null &&
                    (owner == match.component || SwingUtilities.isDescendingFrom(owner, match.component))) {
                JsonObject reply = status("focused"); reply.addProperty("shellPID", match.pid);
                result.complete(reply); timer.stop();
            } else if (System.nanoTime() > deadline || match.project.isDisposed()) {
                result.complete(status("timeout")); timer.stop();
            }
        });
        timer.start();
    }

    private static JsonObject status(String value) { JsonObject object = new JsonObject(); object.addProperty("status", value); return object; }

    @Override public void dispose() {
        disposed = true;
        try { if (server != null) server.close(); } catch (IOException ignored) {}
        for (SocketChannel client : clients) try { client.close(); } catch (IOException ignored) {}
        workers.shutdownNow();
        for (Path file : new Path[]{descriptorPath, socketPath}) if (file != null) try { Files.deleteIfExists(file); } catch (IOException ignored) {}
    }
}
