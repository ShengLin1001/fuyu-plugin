# Battery readings for main.ps1, as one small C# class compiled when the plugin starts:
#   [FocusdPower]::Battery()  this computer's battery (GetSystemPowerStatus)
#   [FocusdPower]::Devices()  paired Bluetooth devices with the level Windows keeps for them
# and Import-AppleAdverts, which builds adverts.cs for the earphones Windows has no level for.
# Why C# and not Get-PnpDeviceProperty: that cmdlet goes through WMI and took about 10 s per
# device node on the machine this was written on (35 nodes); the same properties read straight
# from the Configuration Manager (cfgmgr32) take milliseconds. Nothing here needs administrator
# rights, talks to a device or goes online: it only reads what Windows already knows.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

public class FocusdBluetoothDevice {
    public string Address;
    public string Name;
    // -1: Windows has no level for this device.
    public int Percent = -1;
    public bool Connected;
    // An Apple device's product id, which its broadcasts carry too (adverts.cs); -1 for others.
    public int AppleModel = -1;
}

public static class FocusdPower {
    [StructLayout(LayoutKind.Sequential)]
    struct PowerStatus {
        public byte AcLine; public byte Flag; public byte Percent; public byte Saver;
        public uint SecondsLeft; public uint SecondsFull;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey {
        public Guid Id; public uint Pid;
        public PropertyKey(string id, uint pid) { Id = new Guid(id); Pid = pid; }
    }

    [DllImport("kernel32.dll")]
    static extern bool GetSystemPowerStatus(out PowerStatus status);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Device_ID_List_SizeW(out int length, string filter, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Device_ID_ListW(string filter, char[] buffer, int length, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Locate_DevNodeW(out int node, string id, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_DevNode_PropertyW(int node, ref PropertyKey key, out int type, byte[] buffer, ref int size, int flags);

    // CM_GETIDLIST_FILTER_ENUMERATOR | CM_GETIDLIST_FILTER_PRESENT
    const int ListFlags = 0x1 | 0x100;
    // DEVPKEY_Bluetooth_Battery (a byte, 0-100): on a BLE device's own node, and on the
    // Hands-Free service node of a classic headset.
    static readonly PropertyKey BatteryKey = new PropertyKey("104EA319-6EE2-4701-BD47-8DDBF425BBE5", 2);
    // DEVPKEY_Device_IsConnected and DEVPKEY_Device_FriendlyName, read from the device's own node.
    static readonly PropertyKey ConnectedKey = new PropertyKey("83DA6326-97A6-4088-9453-A1923F573B29", 15);
    static readonly PropertyKey NameKey = new PropertyKey("A45C254E-DF1C-4EFD-8020-67D146A850E0", 14);
    // The device's address in an instance id: BTHENUM\DEV_<address>, BTHLE\DEV_<address>, or
    // the tail ...&<address>_C00000000 of a classic device's service node.
    static readonly Regex AddressIn = new Regex(@"\\DEV_([0-9A-F]{12})|&([0-9A-F]{12})_C[0-9A-F]{8}$", RegexOptions.IgnoreCase);
    // A classic device's service nodes name its vendor (here Apple, 004C) and product.
    static readonly Regex AppleIn = new Regex(@"_VID&0001004C_PID&([0-9A-F]{4})", RegexOptions.IgnoreCase);

    // { percent, plugged in (1/0), seconds left or -1 }; null on a computer without a battery.
    public static int[] Battery() {
        PowerStatus status;
        if (!GetSystemPowerStatus(out status) || (status.Flag & 128) != 0 || status.Percent > 100) return null;
        int left = status.SecondsLeft == uint.MaxValue ? -1 : (int)status.SecondsLeft;
        return new[] { (int)status.Percent, status.AcLine == 1 ? 1 : 0, left };
    }

    static byte[] Read(int node, PropertyKey key) {
        int type;
        int size = 0;
        CM_Get_DevNode_PropertyW(node, ref key, out type, null, ref size, 0);
        if (size <= 0) return null;
        byte[] buffer = new byte[size];
        return CM_Get_DevNode_PropertyW(node, ref key, out type, buffer, ref size, 0) == 0 ? buffer : null;
    }

    // Every paired Bluetooth device, its nodes merged by address.
    public static FocusdBluetoothDevice[] Devices() {
        var found = new Dictionary<string, FocusdBluetoothDevice>();
        foreach (string enumerator in new[] { "BTHENUM", "BTHLE" }) {
            int length;
            if (CM_Get_Device_ID_List_SizeW(out length, enumerator, ListFlags) != 0 || length <= 1) continue;
            char[] ids = new char[length];
            if (CM_Get_Device_ID_ListW(enumerator, ids, length, ListFlags) != 0) continue;
            foreach (string id in new string(ids).Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries)) {
                Match match = AddressIn.Match(id);
                int node;
                if (!match.Success || CM_Locate_DevNodeW(out node, id, 0) != 0) continue;
                bool own = match.Groups[1].Success;
                string address = match.Groups[own ? 1 : 2].Value.ToUpperInvariant();
                FocusdBluetoothDevice device;
                if (!found.TryGetValue(address, out device)) {
                    device = new FocusdBluetoothDevice { Address = address };
                    found[address] = device;
                }
                byte[] battery = Read(node, BatteryKey);
                if (device.Percent < 0 && battery != null && battery.Length >= 1 && battery[0] <= 100) device.Percent = battery[0];
                Match apple = AppleIn.Match(id);
                if (apple.Success) device.AppleModel = Convert.ToInt32(apple.Groups[1].Value, 16);
                if (!own) continue;
                byte[] connected = Read(node, ConnectedKey);
                device.Connected |= connected != null && connected.Length >= 1 && connected[0] != 0;
                byte[] name = Read(node, NameKey);
                if (device.Name == null && name != null) device.Name = Encoding.Unicode.GetString(name).TrimEnd('\0').Trim();
            }
        }
        return new List<FocusdBluetoothDevice>(found.Values).ToArray();
    }
}
'@

# Builds adverts.cs and loads [FocusdAppleAdverts]; see that file for why Add-Type cannot.
# Throws where this Windows has no compiler or no WinRT metadata.
function Import-AppleAdverts {
    $runtime = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $metadata = Join-Path $env:windir 'System32\WinMetadata'
    $lreference = @(
        (Join-Path $runtime 'System.Runtime.dll'), (Join-Path $runtime 'System.Runtime.InteropServices.WindowsRuntime.dll'),
        (Join-Path $metadata 'Windows.Devices.winmd'), (Join-Path $metadata 'Windows.Foundation.winmd'), (Join-Path $metadata 'Windows.Storage.winmd')
    ) | ForEach-Object { "/reference:$_" }
    $path_out = Join-Path ([IO.Path]::GetTempPath()) "focusd-battery-adverts-$PID.dll"
    # The compiler's messages are captured: the plugin's standard output belongs to the host.
    $output = & (Join-Path $runtime 'csc.exe') /nologo /target:library "/out:$path_out" $lreference (Join-Path $PSScriptRoot 'adverts.cs')
    if ($LASTEXITCODE -ne 0) { throw "adverts.cs did not compile: $($output -join ' ')" }
    # Loaded from memory, so the file can go at once, also when loading fails.
    try { [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($path_out)) }
    finally { Remove-Item -LiteralPath $path_out -ErrorAction SilentlyContinue }
}
