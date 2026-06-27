using System;
using System.Runtime.InteropServices;
using System.Text;

namespace ServerLogin {
    public class WindowInfo {
        public IntPtr Handle { get; set; }
        public int ProcessId { get; set; }
        public string Title { get; set; }
        public int Left { get; set; }
        public int Top { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
    }

    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll", SetLastError=true)]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

        [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    }

    public static class WindowInterop {
        public static WindowInfo GetActiveWindowInfo() {
            IntPtr handle = NativeMethods.GetForegroundWindow();
            if (handle == IntPtr.Zero) {
                throw new InvalidOperationException("Failed to get the foreground window.");
            }

            NativeMethods.RECT rect;
            if (!NativeMethods.GetWindowRect(handle, out rect)) {
                throw new InvalidOperationException("Failed to get the foreground window bounds.");
            }

            uint processId;
            NativeMethods.GetWindowThreadProcessId(handle, out processId);

            int titleLength = NativeMethods.GetWindowTextLength(handle);
            StringBuilder titleBuilder = new StringBuilder(Math.Max(titleLength + 1, 256));
            NativeMethods.GetWindowText(handle, titleBuilder, titleBuilder.Capacity);

            return new WindowInfo {
                Handle = handle,
                ProcessId = (int)processId,
                Title = titleBuilder.ToString(),
                Left = rect.Left,
                Top = rect.Top,
                Width = rect.Right - rect.Left,
                Height = rect.Bottom - rect.Top
            };
        }

        public static bool RegisterAppHotKey(IntPtr hWnd, int id, uint modifiers, uint key) {
            return NativeMethods.RegisterHotKey(hWnd, id, modifiers, key);
        }

        public static bool UnregisterAppHotKey(IntPtr hWnd, int id) {
            return NativeMethods.UnregisterHotKey(hWnd, id);
        }
    }
}
