// Hears the battery levels AirPods-like earphones broadcast over Bluetooth LE (Apple's
// "proximity pairing" message). Windows keeps no level for them, so this is the only place to
// get one; nothing is sent to the earphones. It is its own file because Windows PowerShell 5.1
// can neither subscribe to a WinRT event nor compile against WinRT with Add-Type: power.ps1
// builds it with the .NET Framework's compiler (C# 5).
using System;
using System.Collections.Generic;
using System.Threading;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Storage.Streams;

public static class FocusdAppleAdverts {
    static readonly object Gate = new object();
    // Model -> { left, right, case, signal strength } of the last listen.
    static readonly Dictionary<int, int[]> Heard = new Dictionary<int, int[]>();
    static BluetoothLEAdvertisementWatcher watcher;
    static Timer timer;

    // { model, left, right, case } in percent, -1 where the message has no level; null when the
    // bytes are not a proximity pairing message. The model is the device's Bluetooth product id.
    public static int[] Decode(byte[] bytes) {
        if (bytes == null || bytes.Length < 8 || bytes[0] != 0x07) return null;
        int high = bytes[6] >> 4, low = bytes[6] & 0xF;
        // The two pods' levels swap places depending on which pod is sending.
        bool flipped = (bytes[5] & 0x20) == 0;
        return new[] { bytes[3] | bytes[4] << 8, Level(flipped ? high : low), Level(flipped ? low : high), Level(bytes[7] & 0xF) };
    }

    // The message counts in tenths; 15 means unknown.
    static int Level(int tenths) {
        return tenths <= 10 ? tenths * 10 : -1;
    }

    // Listens in the background for this long; Read then answers from what was heard.
    public static void Listen(int milliseconds) {
        lock (Gate) {
            if (watcher != null) return;
            Heard.Clear();
            try {
                var started = new BluetoothLEAdvertisementWatcher();
                started.Received += OnReceived;
                started.Start();
                watcher = started;
            } catch (Exception) {
                return;
            }
            timer = new Timer(Stop, null, milliseconds, Timeout.Infinite);
        }
    }

    static void Stop(object state) {
        lock (Gate) {
            // Stopping throws when Bluetooth was switched off meanwhile.
            try { watcher.Stop(); } catch (Exception) { }
            watcher = null;
            timer.Dispose();
        }
    }

    static void OnReceived(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs received) {
        foreach (var item in received.Advertisement.ManufacturerData) {
            if (item.CompanyId != 0x004C) continue;
            byte[] bytes = new byte[item.Data.Length];
            DataReader.FromBuffer(item.Data).ReadBytes(bytes);
            int[] levels = Decode(bytes);
            if (levels == null) continue;
            int signal = received.RawSignalStrengthInDBm;
            lock (Gate) {
                int[] kept;
                // shortcut: the nearest earphones of a model count as yours, since the sender's
                // address is random and says nothing; upgrade if a neighbor's pair gets shown.
                if (Heard.TryGetValue(levels[0], out kept) && kept[3] > signal) continue;
                Heard[levels[0]] = new[] { levels[1], levels[2], levels[3], signal };
            }
        }
    }

    // { left, right, case } of the nearest earphones of this model, or null when none was heard.
    public static int[] Read(int model) {
        lock (Gate) {
            int[] kept;
            return Heard.TryGetValue(model, out kept) ? new[] { kept[0], kept[1], kept[2] } : null;
        }
    }
}
