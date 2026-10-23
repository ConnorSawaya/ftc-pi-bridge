package org.firstinspires.ftc.teamcode;

import android.content.Context;

import com.qualcomm.ftccommon.FtcEventLoop;
import com.qualcomm.hardware.lynx.LynxModule;
import com.qualcomm.robotcore.eventloop.opmode.OpMode;
import com.qualcomm.robotcore.eventloop.opmode.OpModeManagerImpl;
import com.qualcomm.robotcore.eventloop.opmode.OpModeManagerNotifier;
import com.qualcomm.robotcore.hardware.DcMotorEx;
import com.qualcomm.robotcore.hardware.HardwareDevice;
import com.qualcomm.robotcore.hardware.HardwareMap;
import com.qualcomm.robotcore.hardware.VoltageSensor;

import org.firstinspires.ftc.ftccommon.external.OnCreateEventLoop;
import org.firstinspires.ftc.robotcore.external.navigation.AngleUnit;
import org.firstinspires.ftc.robotcore.external.navigation.DistanceUnit;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.lang.reflect.Method;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentSkipListMap;

/**
 * Records robot data during every OpMode, by itself, to /sdcard/FIRST/bridge-data/ as one CSV per
 * run. `ftc-bridge data pull` copies the runs to your computer, and AI tools can read them.
 *
 * Drop this file into TeamCode; nothing else is needed. Each row has: time, phase (init/run),
 * every motor's power, position and velocity, battery voltage, a goBILDA Pinpoint's position and
 * heading if there is one, and anything your code adds with {@code BridgeLog.put("name", value)}.
 *
 * It reads the hubs with its own bulk reads (one request per hub per row), so it never changes
 * what your OpMode reads. That's still extra traffic on the hubs: lower {@link #hz}, or set
 * {@link #enabled} to false, if your loop timing matters more than the data.
 */
public final class BridgeLog {
    /** Rows per second. */
    public static volatile int hz = 25;
    /** Turn recording off entirely. */
    public static volatile boolean enabled = true;
    /** Runs kept on the robot; older ones are deleted. */
    public static int keepRuns = 40;

    public static final File DIR = new File("/sdcard/FIRST/bridge-data");

    private static final Map<String, Double> custom = new ConcurrentSkipListMap<>();
    private static volatile Recorder recorder;

    private BridgeLog() {}

    /** Adds a value to the next rows (e.g. pose, a target, a state number). Cheap; call it in your loop. */
    public static void put(String name, double value) {
        custom.put(name, value);
    }

    public static void put(String name, boolean value) {
        custom.put(name, value ? 1.0 : 0.0);
    }

    /** Called by the FTC SDK when the robot app starts: start and stop a recording with every OpMode. */
    @OnCreateEventLoop
    public static void attachEventLoop(Context context, FtcEventLoop eventLoop) {
        final OpModeManagerImpl manager = eventLoop.getOpModeManager();
        manager.registerListener(new OpModeManagerNotifier.Notifications() {
            @Override public void onOpModePreInit(OpMode opMode) {
                String name = manager.getActiveOpModeName();
                if (!enabled || OpModeManagerImpl.DEFAULT_OP_MODE_NAME.equals(name)) return;
                stop();
                custom.clear();
                recorder = new Recorder(opMode.hardwareMap, name);
                recorder.start();
            }
            @Override public void onOpModePreStart(OpMode opMode) {
                Recorder r = recorder;
                if (r != null) r.running = true;
            }
            @Override public void onOpModePostStop(OpMode opMode) {
                stop();
            }
        });
    }

    private static void stop() {
        Recorder r = recorder;
        recorder = null;
        if (r != null) r.finish();
    }

    /** One OpMode run: a background thread writing rows until the OpMode stops. */
    private static final class Recorder extends Thread {
        private final HardwareMap map;
        private final String opMode;
        volatile boolean running;          // false during init, true after Start
        private volatile boolean stopping;

        private final List<LynxModule> hubs = new ArrayList<>();
        private final List<String> motorNames = new ArrayList<>();
        private final List<DcMotorEx> motors = new ArrayList<>();
        private final List<Integer> motorHub = new ArrayList<>();   // index into hubs, or -1
        private VoltageSensor battery;
        private HardwareDevice pinpoint;
        private double lastVolts = Double.NaN;

        Recorder(HardwareMap map, String opMode) {
            super("BridgeLog");
            this.map = map;
            this.opMode = opMode;
            setDaemon(true);
            setPriority(Thread.MIN_PRIORITY);
        }

        void finish() {
            stopping = true;
            try { join(1000); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
        }

        private void discover() {
            hubs.addAll(map.getAll(LynxModule.class));
            for (DcMotorEx m : map.getAll(DcMotorEx.class)) {
                motors.add(m);
                motorNames.add(first(map.getNamesOf(m), "motor" + motors.size()));
                // Which hub the motor is on: its controller reports the same connection as the hub.
                int hub = -1;
                String info = m.getController().getConnectionInfo();
                for (int i = 0; i < hubs.size(); i++) if (hubs.get(i).getConnectionInfo().equals(info)) hub = i;
                motorHub.add(hub);
            }
            List<VoltageSensor> sensors = map.getAll(VoltageSensor.class);
            if (!sensors.isEmpty()) battery = sensors.get(0);
            for (HardwareDevice d : map.getAll(HardwareDevice.class)) {
                if (d.getClass().getSimpleName().contains("Pinpoint")) { pinpoint = d; break; }
            }
        }

        @Override public void run() {
            try {
                discover();
                if (!DIR.isDirectory() && !DIR.mkdirs()) return;
                prune();
                String stamp = new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new Date());
                String base = stamp + "_" + opMode.replaceAll("[^A-Za-z0-9._-]", "_");
                long t0 = System.nanoTime();
                int part = 1, row = 0;
                List<String> header = null;
                BufferedWriter out = null;
                try {
                    while (!stopping) {
                        long next = System.nanoTime() + 1_000_000_000L / Math.max(1, hz);
                        List<String> names = new ArrayList<>();
                        List<String> values = new ArrayList<>();
                        sample(names, values, (System.nanoTime() - t0) / 1e9, row);
                        // A value added with put() after the header was written starts a new part file.
                        if (header == null || !header.equals(names)) {
                            if (out != null) { out.close(); part++; }
                            header = names;
                            File f = new File(DIR, base + (part > 1 ? "_part" + part : "") + ".csv");
                            out = new BufferedWriter(new FileWriter(f));
                            out.write(csvLine(header));
                            out.newLine();
                        }
                        out.write(csvLine(values));
                        out.newLine();
                        if (++row % 25 == 0) out.flush();
                        long wait = next - System.nanoTime();
                        if (wait > 0) Thread.sleep(wait / 1_000_000L, (int) (wait % 1_000_000L));
                    }
                } finally {
                    if (out != null) out.close();
                }
            } catch (InterruptedException ignored) {
            } catch (IOException | RuntimeException e) {
                // Never take the robot down because of logging.
            }
        }

        private void sample(List<String> names, List<String> values, double t, int row) {
            col(names, values, "t", fmt(t));
            col(names, values, "phase", running ? "run" : "init");

            LynxModule.BulkData[] bulk = new LynxModule.BulkData[hubs.size()];
            for (int i = 0; i < hubs.size(); i++) {
                try { bulk[i] = hubs.get(i).getBulkData(); } catch (RuntimeException e) { bulk[i] = null; }
            }
            for (int i = 0; i < motors.size(); i++) {
                DcMotorEx m = motors.get(i);
                String n = motorNames.get(i);
                col(names, values, n + "_power", fmt(m.getPower()));
                LynxModule.BulkData b = motorHub.get(i) >= 0 ? bulk[motorHub.get(i)] : null;
                int port = m.getPortNumber();
                col(names, values, n + "_pos", b != null ? Integer.toString(b.getMotorCurrentPosition(port)) : "");
                col(names, values, n + "_vel", b != null ? Integer.toString(b.getMotorVelocity(port)) : "");
            }
            if (battery != null) {
                if (row % 10 == 0) {   // a separate read: only every 10th row
                    try { lastVolts = battery.getVoltage(); } catch (RuntimeException ignored) {}
                }
                col(names, values, "battery_v", fmt(lastVolts));
            }
            if (pinpoint != null) {
                // The Pinpoint's last update() from your code (no extra reads). Works with old and new drivers.
                col(names, values, "pinpoint_x_in", fmt(call(pinpoint, "getPosX", DistanceUnit.INCH)));
                col(names, values, "pinpoint_y_in", fmt(call(pinpoint, "getPosY", DistanceUnit.INCH)));
                col(names, values, "pinpoint_heading_deg", fmt(call(pinpoint, "getHeading", AngleUnit.DEGREES)));
            }
            for (Map.Entry<String, Double> e : custom.entrySet()) {
                col(names, values, e.getKey().replace(',', '_'), fmt(e.getValue()));
            }
        }

        private void prune() {
            File[] runs = DIR.listFiles((dir, name) -> name.endsWith(".csv"));
            if (runs == null || runs.length < keepRuns) return;
            Arrays.sort(runs);   // names start with the date and time
            for (int i = 0; i <= runs.length - keepRuns; i++) runs[i].delete();
        }
    }

    private static void col(List<String> names, List<String> values, String name, String value) {
        names.add(name);
        values.add(value);
    }

    /** String.join isn't on the Control Hub's Android version, so join by hand. */
    private static String csvLine(List<String> parts) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < parts.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(parts.get(i));
        }
        return sb.toString();
    }

    private static String fmt(double v) {
        if (Double.isNaN(v)) return "";
        return String.format(Locale.US, "%.4f", v);
    }

    private static String first(Iterable<String> names, String fallback) {
        for (String n : names) return n.replace(',', '_');
        return fallback;
    }

    /** obj.method(unit) if the driver has it, else obj.method() (older drivers); NaN if neither. */
    private static double call(Object obj, String method, Object unit) {
        try {
            Method m = obj.getClass().getMethod(method, unit.getClass());
            return ((Number) m.invoke(obj, unit)).doubleValue();
        } catch (ReflectiveOperationException | RuntimeException ignored) {}
        try {
            Method m = obj.getClass().getMethod(method);
            double v = ((Number) m.invoke(obj)).doubleValue();
            return method.equals("getHeading") ? Math.toDegrees(v) : v / 25.4;   // old drivers: radians, mm
        } catch (ReflectiveOperationException | RuntimeException ignored) {}
        return Double.NaN;
    }
}
