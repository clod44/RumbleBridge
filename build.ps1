Stop-Process -Name "RumbleBridge" -Force -ErrorAction SilentlyContinue
$dir = "$env:USERPROFILE\RumbleBridge"
New-Item -ItemType Directory -Path "$dir\logs" -Force | Out-Null

if (-not (Test-Path "$dir\Nefarius.ViGEm.Client.dll")) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $pkgZip = "$env:TEMP\vigem.zip"
    $pkgDir = "$env:TEMP\vigem_extracted"
    Remove-Item $pkgZip, $pkgDir -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Nefarius.ViGEm.Client/1.21.256" -OutFile $pkgZip -UseBasicParsing
    Expand-Archive -Path $pkgZip -DestinationPath $pkgDir -Force
    $foundDll = Get-ChildItem -Path "$pkgDir\lib\net452" -Filter "Nefarius.ViGEm.Client.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $foundDll) { $foundDll = Get-ChildItem -Path "$pkgDir\lib" -Filter "Nefarius.ViGEm.Client.dll" -Recurse | Select-Object -First 1 }
    Copy-Item -Path $foundDll.FullName -Destination "$dir\Nefarius.ViGEm.Client.dll" -Force
    Remove-Item $pkgZip, $pkgDir -Recurse -Force -ErrorAction SilentlyContinue
}

$cs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using Nefarius.ViGEm.Client;
using Nefarius.ViGEm.Client.Targets;
using Nefarius.ViGEm.Client.Targets.Xbox360;

// ============================================================================
// 1. PERSISTENT + LIVE TELEMETRY LOGGER (DISK-SAFE)
// ============================================================================
static class Logger {
    private static readonly object _fileLock = new object();
    private static string _logDir;
    public static volatile bool IsWindowVisible = false;
    public static volatile bool WritePacketsToDisk = false;
    public static event Action<string> OnLogLine;

    public static void Init(string baseDir) {
        _logDir = Path.Combine(baseDir, "logs");
        Directory.CreateDirectory(_logDir);
        Info("Logger", "Initialized persistent logging at " + _logDir);
    }

    public static string CurrentLogFile {
        get { return Path.Combine(_logDir ?? ".", "RumbleBridge_" + DateTime.Now.ToString("yyyy-MM-dd") + ".log"); }
    }

    // High-frequency packet traffic: only emitted when debug window is visible (and only written to disk if explicitly enabled)
    public static void Trace(string component, string message) {
        if (!IsWindowVisible && !WritePacketsToDisk) return;
        Write("TRCE", component, message, WritePacketsToDisk, IsWindowVisible);
    }

    // Important lifecycle events (connect/disconnect/bus changes): always saved to disk
    public static void Info(string component, string message) { Write("INFO", component, message, true, true); }
    public static void Warn(string component, string message) { Write("WARN", component, message, true, true); }
    public static void Error(string component, string message, Exception ex = null) {
        Write("ERR ", component, ex != null ? (message + " | " + ex.GetType().Name + ": " + ex.Message) : message, true, true);
        if (ex != null && ex.StackTrace != null) {
            Write("STCK", component, ex.StackTrace.Replace(Environment.NewLine, " -> "), true, true);
        }
    }

    private static void Write(string level, string component, string message, bool toDisk, bool toUi) {
        string formatted = string.Format("[{0}] [{1}] [{2}] {3}",
            DateTime.Now.ToString("HH:mm:ss.fff"), level, component, message);

        if (toDisk) {
            try {
                lock (_fileLock) {
                    if (_logDir != null) {
                        File.AppendAllText(CurrentLogFile, formatted + Environment.NewLine, Encoding.UTF8);
                    }
                }
            } catch {}
        }

        if (toUi) {
            var handler = OnLogLine;
            if (handler != null) {
                try { handler(formatted); } catch {}
            }
        }
    }
}

// ============================================================================
// 2. USB HID MOTOR DRIVER (DECOUPLED + AUTO-RECONNECT)
// ============================================================================
class HidMotorDriver : IDisposable {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, IntPtr Enumerator, IntPtr hwndParent, uint Flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr DeviceInfoSet, IntPtr DeviceInfoData, ref Guid InterfaceClassGuid, uint MemberIndex, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr DeviceInfoSet, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData, IntPtr DeviceInterfaceDetailData, int DeviceInterfaceDetailDataSize, out int RequiredSize, IntPtr DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    private readonly string _vidPidMatch;
    private readonly object _ioLock = new object();
    private SafeFileHandle _handle;
    private FileStream _stream;
    private byte _lastSpeed = 0;
    private long _framesSent = 0;
    private bool _disposed = false;

    public bool IsConnected { get { lock (_ioLock) { return _stream != null && _handle != null && !_handle.IsInvalid && !_handle.IsClosed; } } }
    public string DevicePath { get; private set; }
    public byte CurrentSpeed { get { return _lastSpeed; } }
    public long FramesSent { get { return _framesSent; } }
    public string LastError { get; private set; }

    public HidMotorDriver(string vidPidMatch) {
        _vidPidMatch = vidPidMatch;
        LastError = "None";
    }

    public bool Connect() {
        lock (_ioLock) {
            CloseStreamInternal();
            try {
                string path = FindHidPath(_vidPidMatch);
                if (path == null) {
                    LastError = "Device " + _vidPidMatch + " not enumerated";
                    return false;
                }
                SafeFileHandle h = CreateFile(path, 0x40000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                if (h.IsInvalid) {
                    int err = Marshal.GetLastWin32Error();
                    LastError = "CreateFile Win32Error=" + err;
                    Logger.Error("HID", "Failed opening HID handle (" + LastError + ")");
                    return false;
                }
                _handle = h;
                _stream = new FileStream(_handle, FileAccess.Write);
                DevicePath = path;
                LastError = "None";
                Logger.Info("HID", "Opened HID output handle: " + path);
                return true;
            } catch (Exception ex) {
                LastError = ex.Message;
                Logger.Error("HID", "Exception during Connect()", ex);
                return false;
            }
        }
    }

    public void WriteMotorSpeed(byte speed, string source) {
        if (_disposed) return;
        lock (_ioLock) {
            if (!IsConnected && !Connect()) {
                return;
            }
            try {
                _stream.Write(new byte[] { 0x00, 0x51, 0x00, 0x00, 0x00, speed, 0x00, 0x00, 0x00 }, 0, 9);
                _stream.Flush();
                Thread.Sleep(15);
                _stream.Write(new byte[] { 0x00, 0xFA, 0xFE, 0x00, 0x00, speed, 0x00, 0x00, 0x00 }, 0, 9);
                _stream.Flush();

                _lastSpeed = speed;
                _framesSent++;
                LastError = "None";
                Logger.Trace("HID", string.Format("{0} -> Outgoing={1} (0x{1:X2}) [Frames={2}]", source, speed, _framesSent));
            } catch (Exception ex) {
                LastError = ex.Message;
                Logger.Error("HID", "Write failed, closing stale handle for auto-reconnect", ex);
                CloseStreamInternal();
            }
        }
    }

    private void CloseStreamInternal() {
        try { if (_stream != null) _stream.Dispose(); } catch {}
        try { if (_handle != null && !_handle.IsClosed) _handle.Dispose(); } catch {}
        _stream = null;
        _handle = null;
        _lastSpeed = 0;
    }

    private static string FindHidPath(string match) {
        Guid guid = new Guid("4d1e55b2-f16f-11cf-88cb-001111000030");
        IntPtr info = SetupDiGetClassDevs(ref guid, IntPtr.Zero, IntPtr.Zero, 0x12);
        if (info == new IntPtr(-1)) return null;
        try {
            SP_DEVICE_INTERFACE_DATA data = new SP_DEVICE_INTERFACE_DATA();
            data.cbSize = Marshal.SizeOf(data);
            for (uint i = 0; SetupDiEnumDeviceInterfaces(info, IntPtr.Zero, ref guid, i, ref data); i++) {
                int reqSize = 0;
                SetupDiGetDeviceInterfaceDetail(info, ref data, IntPtr.Zero, 0, out reqSize, IntPtr.Zero);
                IntPtr detail = Marshal.AllocHGlobal(reqSize);
                try {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (SetupDiGetDeviceInterfaceDetail(info, ref data, detail, reqSize, out reqSize, IntPtr.Zero)) {
                        string path = Marshal.PtrToStringAuto(new IntPtr(detail.ToInt64() + 4));
                        if (path != null && path.IndexOf(match, StringComparison.OrdinalIgnoreCase) >= 0) return path;
                    }
                } finally { Marshal.FreeHGlobal(detail); }
            }
        } finally { SetupDiDestroyDeviceInfoList(info); }
        return null;
    }

    public void Dispose() {
        _disposed = true;
        try { WriteMotorSpeed(0, "ShutdownZero"); } catch {}
        lock (_ioLock) { CloseStreamInternal(); }
    }
}

// ============================================================================
// 3. VIGEM VIRTUAL XINPUT RECEIVER (DECOUPLED)
// ============================================================================
class VirtualXInputBridge : IDisposable {
    private readonly HidMotorDriver _motor;
    private readonly object _padLock = new object();
    private ViGEmClient _client;
    private IXbox360Controller _pad;

    public byte LastLargeMotor { get; private set; }
    public byte LastSmallMotor { get; private set; }

    public VirtualXInputBridge(HidMotorDriver motor) {
        _motor = motor;
        _client = new ViGEmClient();
    }

    public void Connect() {
        lock (_padLock) {
            if (_pad != null) {
                Logger.Info("ViGEm", "Disconnecting existing virtual controller...");
                try { _pad.Disconnect(); } catch (Exception ex) { Logger.Warn("ViGEm", "Disconnect warning: " + ex.Message); }
                _pad = null;
                Thread.Sleep(250);
            }

            _pad = _client.CreateXbox360Controller();
            _pad.FeedbackReceived += (sender, e) => {
                LastLargeMotor = e.LargeMotor;
                LastSmallMotor = e.SmallMotor;
                byte target = Math.Max(e.LargeMotor, e.SmallMotor);
                if (target != _motor.CurrentSpeed) {
                    _motor.WriteMotorSpeed(target, string.Format("XInputFFB(L={0},S={1})", e.LargeMotor, e.SmallMotor));
                }
            };
            _pad.Connect();
            Logger.Info("ViGEm", "Virtual Xbox 360 controller connected (UserIndex=" + GetUserIndex() + ")");
        }
    }

    public int GetUserIndex() {
        lock (_padLock) {
            if (_pad == null) return -1;
            try { return _pad.UserIndex; } catch { return -1; }
        }
    }

    public string GetSlotDisplay() {
        int idx = GetUserIndex();
        return (idx >= 0 && idx <= 3) ? ("XInput " + (idx + 1)) : "Unassigned";
    }

    public string GetShortBadge() {
        int idx = GetUserIndex();
        return (idx >= 0 && idx <= 3) ? ("R" + (idx + 1)) : "R?";
    }

    public void Dispose() {
        lock (_padLock) {
            try { if (_pad != null) _pad.Disconnect(); } catch {}
            try { if (_client != null) _client.Dispose(); } catch {}
        }
    }
}

// ============================================================================
// 4. SYSTEM CONTROLLER SCANNER (JOY.CPL / WINMM + XINPUT BUS)
// ============================================================================
class JoyCplDeviceInfo {
    public int JoyId;
    public string Name;
    public string VidPid;
    public string Status;
}

static class SystemDeviceScanner {
    [DllImport("winmm.dll")]
    static extern uint joyGetNumDevs();

    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    static extern uint joyGetDevCaps(UIntPtr uJoyID, ref JOYCAPS pjc, uint cbjc);

    [DllImport("winmm.dll")]
    static extern uint joyGetPosEx(uint uJoyID, ref JOYINFOEX pji);

    [DllImport("xinput1_4.dll", EntryPoint = "XInputGetState")]
    static extern uint XInputGetState(uint dwUserIndex, ref XINPUT_STATE pState);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    struct JOYCAPS {
        public ushort wMid;
        public ushort wPid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szPname;
        public uint wXmin; public uint wXmax;
        public uint wYmin; public uint wYmax;
        public uint wZmin; public uint wZmax;
        public uint wNumButtons;
        public uint wPeriodMin; public uint wPeriodMax;
        public uint wRmin; public uint wRmax;
        public uint wUmin; public uint wUmax;
        public uint wVmin; public uint wVmax;
        public uint wCaps;
        public uint wMaxAxes;
        public uint wNumAxes;
        public uint wMaxButtons;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szRegKey;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szOEMVxD;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOYINFOEX {
        public uint dwSize;
        public uint dwFlags;
        public uint dwXpos; public uint dwYpos; public uint dwZpos;
        public uint dwRpos; public uint dwUpos; public uint dwVpos;
        public uint dwButtons; public uint dwButtonNumber;
        public uint dwPOV;
        public uint dwReserved1; public uint dwReserved2;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct XINPUT_STATE {
        public uint dwPacketNumber;
        public ushort wButtons;
        public byte bLeftTrigger; public byte bRightTrigger;
        public short sThumbLX; public short sThumbLY;
        public short sThumbRX; public short sThumbRY;
    }

    public static List<JoyCplDeviceInfo> GetInstalledControllers() {
        var list = new List<JoyCplDeviceInfo>();
        uint maxDevs = joyGetNumDevs();
        if (maxDevs > 16) maxDevs = 16;

        for (uint i = 0; i < maxDevs; i++) {
            JOYCAPS caps = new JOYCAPS();
            uint capsRes = joyGetDevCaps((UIntPtr)i, ref caps, (uint)Marshal.SizeOf(typeof(JOYCAPS)));
            if (capsRes != 0) continue;

            JOYINFOEX pos = new JOYINFOEX { dwSize = (uint)Marshal.SizeOf(typeof(JOYINFOEX)), dwFlags = 0xFF };
            uint posRes = joyGetPosEx(i, ref pos);
            if (posRes != 0) continue;

            string oemName = ResolveOemName(caps.wMid, caps.wPid, caps.szRegKey, caps.szPname);
            list.Add(new JoyCplDeviceInfo {
                JoyId = (int)i,
                Name = oemName,
                VidPid = string.Format("VID_{0:X4}&PID_{1:X4}", caps.wMid, caps.wPid),
                Status = "OK"
            });
        }
        return list;
    }

    public static bool[] GetXInputActiveSlots() {
        bool[] active = new bool[4];
        for (uint i = 0; i < 4; i++) {
            XINPUT_STATE st = new XINPUT_STATE();
            active[i] = (XInputGetState(i, ref st) == 0);
        }
        return active;
    }

    private static string ResolveOemName(ushort vid, ushort pid, string regKey, string fallback) {
        try {
            string vidPidKey = string.Format(@"SYSTEM\CurrentControlSet\Control\MediaProperties\PrivateProperties\Joystick\OEM\VID_{0:X4}&PID_{1:X4}", vid, pid);
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(vidPidKey) ?? Registry.LocalMachine.OpenSubKey(vidPidKey)) {
                if (k != null) {
                    object val = k.GetValue("OEMName");
                    if (val != null && !string.IsNullOrWhiteSpace(val.ToString())) return val.ToString();
                }
            }
            if (!string.IsNullOrEmpty(regKey)) {
                string fullKey = @"SYSTEM\CurrentControlSet\Control\MediaProperties\PrivateProperties\Joystick\OEM\" + regKey;
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(fullKey) ?? Registry.LocalMachine.OpenSubKey(fullKey)) {
                    if (k != null) {
                        object val = k.GetValue("OEMName");
                        if (val != null && !string.IsNullOrWhiteSpace(val.ToString())) return val.ToString();
                    }
                }
            }
        } catch {}
        return string.IsNullOrWhiteSpace(fallback) ? "Unknown Game Controller" : fallback;
    }
}

// ============================================================================
// 5. MAIN APPLICATION + LIVE MONITOR WINDOW
// ============================================================================
class Program {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    extern static bool DestroyIcon(IntPtr handle);

    static Icon CreateSlotIcon(string label, bool hidOk) {
        using (Bitmap bmp = new Bitmap(16, 16))
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.Clear(Color.Transparent);
            g.FillRectangle(hidOk ? Brushes.LimeGreen : Brushes.OrangeRed, 0, 0, 16, 16);
            using (Font f = new Font("Arial", 7.5f, FontStyle.Bold)) {
                g.DrawString(label, f, Brushes.Black, -1, 2);
            }
            return Icon.FromHandle(bmp.GetHicon());
        }
    }

    [STAThread]
    static void Main() {
        string baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "RumbleBridge");
        Logger.Init(baseDir);

        AppDomain.CurrentDomain.UnhandledException += (s, e) => {
            Logger.Error("CRASH", "Unhandled AppDomain exception", e.ExceptionObject as Exception);
        };
        Application.ThreadException += (s, e) => {
            Logger.Error("CRASH", "Unhandled UI Thread exception", e.Exception);
        };

        bool createdNew;
        using (Mutex mutex = new Mutex(true, "RumbleBridge_SingleInstance_Mutex", out createdNew)) {
            if (!createdNew) {
                Logger.Warn("Startup", "Duplicate instance blocked by Mutex.");
                MessageBox.Show("RumbleBridge is already running! Double-click the icon in your system tray to open the Monitor window.", "RumbleBridge", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            HidMotorDriver motor = new HidMotorDriver("VID_0079&PID_0006");
            if (!motor.Connect()) {
                Logger.Warn("Startup", "Initial HID device not found; background auto-reconnect remains armed.");
            }

            VirtualXInputBridge bridge = null;
            try {
                bridge = new VirtualXInputBridge(motor);
                bridge.Connect();
            } catch (Exception ex) {
                Logger.Error("Startup", "ViGEmBus initialization failed", ex);
                MessageBox.Show("Failed to initialize ViGEmBus virtual controller:\n" + ex.Message, "RumbleBridge Fatal Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                motor.Dispose();
                return;
            }

            Color bg = SystemColors.Control;
            Form win = new Form {
                Text = "RumbleBridge - Hardware & XInput Monitor",
                Size = new Size(600, 645),
                StartPosition = FormStartPosition.CenterScreen,
                FormBorderStyle = FormBorderStyle.FixedSingle,
                MaximizeBox = false,
                BackColor = bg
            };

            Label lblVirtualSlot = new Label { Location = new Point(15, 12), Size = new Size(555, 22), Font = new Font("Segoe UI", 10, FontStyle.Bold), Text = "Virtual XInput Receiver: Detecting..." };
            Label lblXInputBus = new Label { Location = new Point(15, 36), Size = new Size(555, 18), Font = new Font("Consolas", 9), Text = "XInput Slots (0-3): Scanning..." };
            Label lblHidStatus = new Label { Location = new Point(15, 56), Size = new Size(555, 18), Font = new Font("Consolas", 8.5f), ForeColor = Color.DimGray, Text = "Physical USB HID: Scanning..." };

            Label lblJoyHeader = new Label { Location = new Point(15, 82), Size = new Size(555, 18), Font = new Font("Segoe UI", 9, FontStyle.Bold), Text = "Installed Game Controllers (Live Windows joy.cpl View)" };
            ListView lvControllers = new ListView {
                Location = new Point(15, 102),
                Size = new Size(555, 105),
                View = View.Details,
                FullRowSelect = true,
                GridLines = true,
                HeaderStyle = ColumnHeaderStyle.Nonclickable
            };
            lvControllers.Columns.Add("ID", 40);
            lvControllers.Columns.Add("Controller Name", 285);
            lvControllers.Columns.Add("Hardware ID", 145);
            lvControllers.Columns.Add("Status", 65);

            Label lblLargeText = new Label { Location = new Point(15, 218), Size = new Size(270, 18), Text = "Large Motor (Low-Freq): 0 / 255" };
            ProgressBar barLarge = new ProgressBar { Location = new Point(15, 238), Size = new Size(270, 16), Maximum = 255 };

            Label lblSmallText = new Label { Location = new Point(300, 218), Size = new Size(270, 18), Text = "Small Motor (High-Freq): 0 / 255" };
            ProgressBar barSmall = new ProgressBar { Location = new Point(300, 238), Size = new Size(270, 16), Maximum = 255 };

            Label lblOutText = new Label { Location = new Point(15, 264), Size = new Size(555, 18), Font = new Font("Segoe UI", 9, FontStyle.Bold), Text = "HID Output Duty: 0 / 255 (0%) | HID Frames: 0" };
            ProgressBar barOut = new ProgressBar { Location = new Point(15, 284), Size = new Size(555, 18), Maximum = 255 };

            Label lblManual = new Label { Location = new Point(15, 314), Size = new Size(215, 20), Text = "Manual Duty Override: 0" };
            TrackBar sliderManual = new TrackBar {
                Location = new Point(235, 310),
                Size = new Size(335, 26),
                AutoSize = false,
                Minimum = 0,
                Maximum = 255,
                TickStyle = TickStyle.None,
                BackColor = bg
            };

            Button btnPulse = new Button { Location = new Point(15, 348), Size = new Size(115, 28), Text = "Pulse Test" };
            Button btnRestart = new Button { Location = new Point(138, 348), Size = new Size(125, 28), Text = "Restart Virtual Pad" };
            Button btnOpenLogs = new Button { Location = new Point(271, 348), Size = new Size(110, 28), Text = "Open Log Folder" };
            Button btnClear = new Button { Location = new Point(389, 348), Size = new Size(85, 28), Text = "Clear View" };
            Button btnHide = new Button { Location = new Point(482, 348), Size = new Size(88, 28), Text = "Hide to Tray" };

            CheckBox chkLogPackets = new CheckBox {
                Location = new Point(15, 383),
                Size = new Size(555, 20),
                Text = "Save motor packet traffic to disk log (Errors & device events are always saved)"
            };
            chkLogPackets.CheckedChanged += (s, e) => {
                Logger.WritePacketsToDisk = chkLogPackets.Checked;
                Logger.Info("Logger", "Disk packet tracing " + (chkLogPackets.Checked ? "ENABLED" : "DISABLED"));
            };

            TextBox txtLog = new TextBox {
                Location = new Point(15, 408),
                Size = new Size(555, 185),
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Vertical,
                Font = new Font("Consolas", 8.25f),
                BackColor = Color.FromArgb(22, 22, 22),
                ForeColor = Color.LimeGreen
            };

            win.Controls.AddRange(new Control[] {
                lblVirtualSlot, lblXInputBus, lblHidStatus,
                lblJoyHeader, lvControllers,
                lblLargeText, barLarge, lblSmallText, barSmall,
                lblOutText, barOut,
                lblManual, sliderManual,
                btnPulse, btnRestart, btnOpenLogs, btnClear, btnHide,
                chkLogPackets, txtLog
            });

            win.VisibleChanged += (s, e) => {
                Logger.IsWindowVisible = win.Visible;
            };

            Logger.OnLogLine += (line) => {
                if (win.IsHandleCreated && !win.IsDisposed && win.Visible) {
                    try {
                        win.BeginInvoke((Action)(() => {
                            if (txtLog.TextLength > 15000) txtLog.Clear();
                            txtLog.AppendText(line + Environment.NewLine);
                        }));
                    } catch {}
                }
            };

            sliderManual.Scroll += (s, e) => {
                byte val = (byte)sliderManual.Value;
                lblManual.Text = "Manual Duty Override: " + val;
                ThreadPool.QueueUserWorkItem(_ => motor.WriteMotorSpeed(val, "ManualOverride"));
            };

            btnPulse.Click += (s, e) => {
                ThreadPool.QueueUserWorkItem(_ => {
                    motor.WriteMotorSpeed(255, "PulseStart");
                    Thread.Sleep(400);
                    motor.WriteMotorSpeed(0, "PulseStop");
                });
            };

            btnRestart.Click += (s, e) => {
                ThreadPool.QueueUserWorkItem(_ => {
                    motor.Connect();
                    bridge.Connect();
                });
            };

            btnOpenLogs.Click += (s, e) => {
                try { System.Diagnostics.Process.Start("explorer.exe", Path.Combine(baseDir, "logs")); } catch {}
            };

            btnClear.Click += (s, e) => txtLog.Clear();
            btnHide.Click += (s, e) => win.Hide();

            bool exiting = false;
            win.FormClosing += (s, e) => {
                if (!exiting) {
                    e.Cancel = true;
                    win.Hide();
                }
            };

            MenuItem statusItem = new MenuItem("Virtual Pad: " + bridge.GetSlotDisplay());
            statusItem.Enabled = false;

            ContextMenu menu = new ContextMenu();
            menu.MenuItems.Add(statusItem);
            menu.MenuItems.Add("Open Monitor Window", (s, e) => { win.Show(); win.Activate(); });
            menu.MenuItems.Add("Test Rumble", (s, e) => {
                ThreadPool.QueueUserWorkItem(_ => {
                    motor.WriteMotorSpeed(255, "TrayPulseStart");
                    Thread.Sleep(400);
                    motor.WriteMotorSpeed(0, "TrayPulseStop");
                });
            });
            menu.MenuItems.Add("Restart", (s, e) => {
                ThreadPool.QueueUserWorkItem(_ => {
                    motor.Connect();
                    bridge.Connect();
                });
            });
            menu.MenuItems.Add("-");
            menu.MenuItems.Add("Exit", (s, e) => {
                exiting = true;
                Logger.Info("Shutdown", "User requested exit from tray.");
                try { bridge.Dispose(); motor.Dispose(); } catch {}
                Application.Exit();
            });

            string lastBadge = bridge.GetShortBadge();
            bool lastHidState = motor.IsConnected;
            NotifyIcon tray = new NotifyIcon {
                Icon = CreateSlotIcon(lastBadge, lastHidState),
                Text = "RumbleBridge (" + bridge.GetSlotDisplay() + ")",
                ContextMenu = menu,
                Visible = true
            };
            tray.DoubleClick += (s, e) => { win.Show(); win.Activate(); };

            string lastControllerSignature = "";
            int slowTick = 0;

            System.Windows.Forms.Timer pollTimer = new System.Windows.Forms.Timer { Interval = 100 };
            pollTimer.Tick += (s, e) => {
                if (win.Visible) {
                    barLarge.Value = bridge.LastLargeMotor;
                    lblLargeText.Text = "Large Motor (Low-Freq): " + bridge.LastLargeMotor + " / 255";
                    barSmall.Value = bridge.LastSmallMotor;
                    lblSmallText.Text = "Small Motor (High-Freq): " + bridge.LastSmallMotor + " / 255";

                    byte curOut = motor.CurrentSpeed;
                    barOut.Value = curOut;
                    int pct = (int)Math.Round((curOut / 255.0) * 100.0);
                    lblOutText.Text = string.Format("HID Output Duty: {0} / 255 ({1}%) | HID Frames: {2}", curOut, pct, motor.FramesSent);
                }

                slowTick++;
                if (slowTick >= 10) {
                    slowTick = 0;

                    if (!motor.IsConnected) {
                        motor.Connect();
                    }

                    string slotText = bridge.GetSlotDisplay();
                    string badge = bridge.GetShortBadge();
                    bool hidOk = motor.IsConnected;

                    statusItem.Text = "Virtual Pad: " + slotText;
                    tray.Text = "RumbleBridge (" + slotText + ")";

                    if (win.Visible) {
                        lblVirtualSlot.Text = "Virtual XInput Receiver: " + slotText + "  (ViGEm UserIndex=" + bridge.GetUserIndex() + ")";
                        lblHidStatus.Text = hidOk
                            ? ("Physical USB HID: Connected (VID_0079&PID_0006) | Last Error: " + motor.LastError)
                            : ("Physical USB HID: Disconnected — Auto-Retrying... (" + motor.LastError + ")");
                        lblHidStatus.ForeColor = hidOk ? Color.DarkGreen : Color.Firebrick;

                        bool[] xSlots = SystemDeviceScanner.GetXInputActiveSlots();
                        lblXInputBus.Text = string.Format("XInput Bus:  [1:{0}]  [2:{1}]  [3:{2}]  [4:{3}]",
                            xSlots[0] ? "ACTIVE" : "EMPTY ",
                            xSlots[1] ? "ACTIVE" : "EMPTY ",
                            xSlots[2] ? "ACTIVE" : "EMPTY ",
                            xSlots[3] ? "ACTIVE" : "EMPTY ");

                        var installed = SystemDeviceScanner.GetInstalledControllers();
                        StringBuilder sig = new StringBuilder();
                        foreach (var d in installed) sig.Append(d.JoyId).Append('|').Append(d.Name).Append('|').Append(d.VidPid).Append(';');
                        string currentSig = sig.ToString();

                        if (currentSig != lastControllerSignature) {
                            lastControllerSignature = currentSig;
                            lvControllers.BeginUpdate();
                            lvControllers.Items.Clear();
                            foreach (var d in installed) {
                                var item = new ListViewItem(d.JoyId.ToString());
                                item.SubItems.Add(d.Name);
                                item.SubItems.Add(d.VidPid);
                                item.SubItems.Add(d.Status);
                                lvControllers.Items.Add(item);
                            }
                            lvControllers.EndUpdate();
                        }
                    }

                    if (badge != lastBadge || hidOk != lastHidState) {
                        Icon oldIcon = tray.Icon;
                        tray.Icon = CreateSlotIcon(badge, hidOk);
                        if (oldIcon != null) DestroyIcon(oldIcon.Handle);
                        lastBadge = badge;
                        lastHidState = hidOk;
                    }
                }
            };
            pollTimer.Start();

            Logger.Info("Startup", "RumbleBridge UI ready.");
            win.Show();
            Application.Run();
            pollTimer.Stop();
            tray.Visible = false;
        }
    }
}
'@

$netdir = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
Set-Content -Path "$env:TEMP\RumbleBridge.cs" -Value $cs
& "$netdir\csc.exe" /target:winexe `
    /r:"$netdir\netstandard.dll" `
    /r:"$dir\Nefarius.ViGEm.Client.dll" `
    /r:"System.Windows.Forms.dll" `
    /r:"System.Drawing.dll" `
    /out:"$dir\RumbleBridge.exe" "$env:TEMP\RumbleBridge.cs"

Remove-Item "$env:TEMP\RumbleBridge.cs" -Force -ErrorAction SilentlyContinue
Start-Process "$dir\RumbleBridge.exe"