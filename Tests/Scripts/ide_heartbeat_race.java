import com.google.gson.JsonObject;
import com.lunavect.sessions.BridgeService;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.concurrent.*;

/** Isolated SDK-backed lifecycle fixture. No IDE, account or user session. */
class IDEHeartbeatRace {
  public static void main(String[] args) throws Exception {
    // Keep the normal constructor from discovering/starting a real IDE endpoint.
    System.setProperty("os.name", "Linux");
    BridgeService bridge = new BridgeService();
    Path root = Path.of(args[0]);
    Field idField = BridgeService.class.getDeclaredField("id"); idField.setAccessible(true);
    String id = (String) idField.get(bridge);
    Path record = root.resolve(id + ".json"), fifo = root.resolve(id + ".tmp");
    for (String field : new String[]{"descriptorPath", "socketPath"}) {
      Field value = BridgeService.class.getDeclaredField(field); value.setAccessible(true);
      value.set(bridge, field.equals("descriptorPath") ? record : root.resolve(id + ".sock"));
    }
    if (new ProcessBuilder("/usr/bin/mkfifo", fifo.toString()).start().waitFor() != 0) throw new AssertionError("FIFO fixture failed");
    Method publish = BridgeService.class.getDeclaredMethod("publish", JsonObject.class); publish.setAccessible(true);
    CompletableFuture<Void> written = new CompletableFuture<>();
    Thread writer = new Thread(() -> {
      try { publish.invoke(bridge, new JsonObject()); written.complete(null); }
      catch (Throwable failure) { written.completeExceptionally(failure); }
    });
    writer.setDaemon(true); writer.start();
    long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
    boolean blocked = false;
    while (System.nanoTime() < deadline && !blocked) {
      blocked = java.util.Arrays.stream(writer.getStackTrace()).anyMatch(frame -> frame.getMethodName().equals("open0"));
      Thread.sleep(5);
    }
    if (!blocked) throw new AssertionError("Fixture did not reach blocked FIFO open");
    CompletableFuture<Void> closed = CompletableFuture.runAsync(bridge::dispose);
    closed.get(3, TimeUnit.SECONDS);
    // A reader releases the deliberately stalled publisher; both operations
    // must finish and cleanup must win over the late heartbeat.
    try (var input = Files.newInputStream(fifo)) { input.readAllBytes(); }
    written.get(3, TimeUnit.SECONDS); closed.get(3, TimeUnit.SECONDS);
    if (Files.exists(record) || Files.exists(fifo)) throw new AssertionError("Heartbeat artifact survived deactivation");
    System.out.println("PASS: deactivation cleanup wins over the in-flight heartbeat");
  }
}
