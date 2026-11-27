using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Web.WebView2.WinForms;

namespace GaoYanJiu.Portal
{
    internal enum PortalStatus
    {
        Ready,
        Busy,
        Warning
    }

    internal sealed class PortalTheme
    {
        internal readonly Color Canvas;
        internal readonly Color Card;
        internal readonly Color Raised;
        internal readonly Color Border;
        internal readonly Color Text;
        internal readonly Color Muted;
        internal readonly Color Accent;
        internal readonly Color OnAccent;
        internal readonly Color Warning;
        internal readonly bool Dark;

        internal PortalTheme(string appearance)
        {
            Dark = appearance == "dark" || (appearance != "light" && SystemUsesDarkTheme());
            if (SystemInformation.HighContrast)
            {
                Canvas = Raised = Card = SystemColors.Window;
                Text = Muted = Border = Warning = SystemColors.WindowText;
                Accent = SystemColors.Highlight;
                OnAccent = SystemColors.HighlightText;
                return;
            }
            Canvas = Tone(0xeef2f4, 0x131b21);
            Card = Tone(0xffffff, 0x1d2931);
            Raised = Tone(0xf5f8f8, 0x24323a);
            Border = Tone(0xd4dfe1, 0x3a4a53);
            Text = Tone(0x1a3238, 0xe8f4f4);
            Muted = Tone(0x446069, 0xaebfc6);
            Accent = Tone(0x12665a, 0x7bd6c2);
            OnAccent = Tone(0xffffff, 0x092822);
            Warning = Tone(0x8b451c, 0xffbc87);
        }

        private Color Tone(int light, int dark) { return Color.FromArgb(unchecked((int)0xff000000) | (Dark ? dark : light)); }

        private static bool SystemUsesDarkTheme()
        {
            const string key = @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
            try { return Convert.ToInt32(Microsoft.Win32.Registry.GetValue(key, "AppsUseLightTheme", 1)) == 0; }
            catch (Exception) { return false; }
        }

        [DllImport("dwmapi.dll", ExactSpelling = true)]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        internal void ApplyCaption(Form window)
        {
            if (SystemInformation.HighContrast) return;
            window.HandleCreated += delegate
            {
                int preference = Dark ? 1 : 0;
                DwmSetWindowAttribute(window.Handle, 20, ref preference, sizeof(int));
            };
        }
    }

    internal sealed class PortalChrome : TableLayoutPanel
    {
        internal readonly PortalWebView Browser = new PortalWebView { Dock = DockStyle.Fill, Margin = new Padding(0), TabIndex = 1 };
        internal readonly TextBox Address = new TextBox { Dock = DockStyle.Fill, TabIndex = 3 };
        internal readonly Button Back;
        internal readonly Button Forward;
        internal readonly Button Reload;
        internal readonly Button Go;
        internal readonly Button Finish;
        private readonly Label status;
        private readonly Panel indicator;
        private readonly PortalTheme theme;
        private readonly bool english;
        private readonly ToolTip tips = new ToolTip();
        private float layoutDpi;

        internal PortalChrome(PortalTheme palette, bool useEnglish, string journal, bool signIn)
        {
            theme = palette;
            english = useEnglish;
            Dock = DockStyle.Fill;
            BackColor = theme.Canvas;
            ForeColor = theme.Text;
            ColumnCount = 1;
            RowCount = 6;
            RowStyles.Add(new RowStyle(SizeType.Absolute, 43));
            RowStyles.Add(new RowStyle(SizeType.Absolute, 47));
            RowStyles.Add(new RowStyle(SizeType.Absolute, 1));
            RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            RowStyles.Add(new RowStyle(SizeType.Absolute, 1));
            RowStyles.Add(new RowStyle(SizeType.Absolute, 57));

            var mast = Row(11, 3, 11, 1);
            mast.ColumnCount = 2;
            mast.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            mast.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            var title = new Label
            {
                AutoSize = true, Anchor = AnchorStyles.Left,
                Text = signIn ? TextFor("登录投稿门户", "Portal sign-in") : TextFor("投稿门户", "Submission portal"),
                Font = new Font(UiFont, 12, FontStyle.Bold), Margin = new Padding(0, 0, 11, 0),
                ForeColor = theme.Text
            };
            var context = new Label
            {
                Text = journal, AutoEllipsis = true, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft,
                Margin = new Padding(0), ForeColor = theme.Muted
            };
            mast.Controls.Add(title, 0, 0);
            mast.Controls.Add(context, 1, 0);

            var navigation = Row(11, 4, 11, 7);
            navigation.TabIndex = 0;
            navigation.ColumnCount = signIn ? 4 : 5;
            for (int i = 0; i < 3; ++i) navigation.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            navigation.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            if (!signIn) navigation.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            Back = NavigationButton("←", TextFor("后退", "Back"), "Alt+←", 0);
            Forward = NavigationButton("→", TextFor("前进", "Forward"), "Alt+→", 1);
            Reload = NavigationButton("↻", TextFor("重新载入", "Reload"), "F5", 2);
            navigation.Controls.Add(Back, 0, 0);
            navigation.Controls.Add(Forward, 1, 0);
            navigation.Controls.Add(Reload, 2, 0);
            var field = new TableLayoutPanel
            {
                Dock = DockStyle.Fill, BackColor = theme.Card, ColumnCount = 1, RowCount = 1,
                Margin = new Padding(2, 0, signIn ? 0 : 6, 0), TabIndex = 3
            };
            field.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            field.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            field.Paint += delegate(object sender, PaintEventArgs args)
            {
                Color border = field.ContainsFocus ? theme.Accent : theme.Border;
                using (var pen = new Pen(border))
                    args.Graphics.DrawRectangle(pen, 0, 0, field.Width - 1, field.Height - 1);
            };
            Address.BorderStyle = BorderStyle.None;
            Address.Dock = DockStyle.None;
            Address.Anchor = AnchorStyles.Left | AnchorStyles.Right;
            Address.Margin = new Padding(8, 0, 8, 0);
            Address.BackColor = theme.Card;
            Address.ForeColor = theme.Text;
            Address.ReadOnly = signIn;
            Address.AccessibleName = TextFor("投稿网站地址", "Portal address");
            Address.AccessibleDescription = TextFor("按 Ctrl+L 选择当前地址。", "Press Ctrl+L to select the address.");
            Address.Font = new Font("Segoe UI", 10f);
            Address.Enter += delegate { field.Invalidate(); };
            Address.Leave += delegate { field.Invalidate(); };
            field.Controls.Add(Address, 0, 0);
            navigation.Controls.Add(field, 3, 0);
            if (!signIn)
            {
                Go = ActionButton(TextFor("前往", "Go"), TextFor("打开此网站地址", "Open this address"), "Enter", false);
                Go.TabIndex = 4;
                Go.Enabled = false;
                navigation.Controls.Add(Go, 4, 0);
            }

            Browser.BackColor = theme.Card;
            Browser.DefaultBackgroundColor = theme.Card;
            Browser.AccessibleName = signIn ? TextFor("投稿登录网页", "Portal sign-in page") : TextFor("投稿网页", "Submission web page");
            var footer = Row(11, 9, 11, 9);
            footer.TabIndex = 2;
            footer.ColumnCount = 3;
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 4));
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            indicator = new Panel { BackColor = theme.Muted, Dock = DockStyle.Fill, Margin = new Padding(0, 4, 0, 4) };
            status = new Label
            {
                Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, ForeColor = theme.Muted,
                Margin = new Padding(8, 0, 9, 0), AccessibleRole = AccessibleRole.StatusBar
            };
            Finish = signIn
                ? ActionButton(TextFor("返回投稿门户", "Return to portal"), TextFor("关闭登录窗口", "Close sign-in window"), "Esc", false)
                : ActionButton(TextFor("提取稿件并审核", "Extract for review"), TextFor("提取当前页面的稿件", "Extract submissions on this page"), "Ctrl+Enter", true);
            footer.Controls.Add(indicator, 0, 0);
            footer.Controls.Add(status, 1, 0);
            footer.Controls.Add(Finish, 2, 0);

            Controls.Add(mast, 0, 0);
            Controls.Add(navigation, 0, 1);
            Controls.Add(Separator(), 0, 2);
            Controls.Add(Browser, 0, 3);
            Controls.Add(Separator(), 0, 4);
            Controls.Add(footer, 0, 5);
        }

        private string TextFor(string zh, string en) { return english ? en : zh; }

        private string UiFont { get { return english ? "Segoe UI" : "Microsoft YaHei UI"; } }

        private TableLayoutPanel Row(int left, int top, int right, int bottom)
        {
            var row = new TableLayoutPanel { Dock = DockStyle.Fill, Margin = new Padding(0), Padding = new Padding(left, top, right, bottom),
                RowCount = 1, BackColor = theme.Canvas, TabStop = false };
            row.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            return row;
        }

        private Control Separator() { return new Panel { Dock = DockStyle.Fill, Margin = new Padding(0), BackColor = theme.Border }; }

        private Button NavigationButton(string arrow, string name, string shortcut, int tabIndex)
        {
            var button = ActionButton(arrow, name, shortcut, false);
            button.Font = new Font("Segoe UI Symbol", 13f);
            button.Padding = new Padding(0);
            button.MinimumSize = new Size(38, 28);
            button.TabIndex = tabIndex;
            button.Enabled = false;
            button.Margin = new Padding(0, 0, 5, 0);
            return button;
        }

        private Button ActionButton(string text, string name, string shortcut, bool primary)
        {
            var button = new Button
            {
                Text = text, AccessibleName = name, AccessibleDescription = shortcut,
                AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Dock = DockStyle.Fill,
                Margin = new Padding(0), Padding = new Padding(11, 0, 11, 0), FlatStyle = FlatStyle.Flat,
                BackColor = primary ? theme.Accent : theme.Card, ForeColor = primary ? theme.OnAccent : theme.Text,
                Font = new Font(UiFont, 9.5f, primary ? FontStyle.Bold : FontStyle.Regular)
            };
            button.FlatAppearance.BorderColor = primary ? theme.Accent : theme.Border;
            button.FlatAppearance.MouseOverBackColor = primary ? theme.Accent : theme.Raised;
            button.FlatAppearance.MouseDownBackColor = primary ? theme.Accent : theme.Border;
            if (primary)
            {
                button.EnabledChanged += delegate
                {
                    button.BackColor = button.Enabled ? theme.Accent : theme.Raised;
                    button.ForeColor = button.Enabled ? theme.OnAccent : theme.Muted;
                    button.FlatAppearance.BorderColor = button.Enabled ? theme.Accent : theme.Border;
                    button.FlatAppearance.MouseOverBackColor = button.BackColor;
                };
            }
            tips.SetToolTip(button, name + " (" + shortcut + ")");
            return button;
        }

        internal void SetStatus(string message, PortalStatus mood)
        {
            indicator.BackColor = mood == PortalStatus.Warning ? theme.Warning
                : mood == PortalStatus.Busy ? theme.Accent : theme.Muted;
            status.ForeColor = mood == PortalStatus.Warning ? theme.Warning : theme.Muted;
            status.Text = message;
            status.AccessibleName = message;
        }

        internal string StatusText { get { return status.Text; } }

        internal void SetAddress(string value)
        {
            Uri uri;
            Address.Text = Uri.TryCreate(value, UriKind.Absolute, out uri) && PortalWindow.IsWebUri(value)
                ? uri.GetLeftPart(UriPartial.Path) : "";
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) tips.Dispose();
            base.Dispose(disposing);
        }

        protected override void OnLayout(LayoutEventArgs args)
        {
            if (IsHandleCreated && RowStyles.Count == 6)
            {
                using (Graphics graphics = CreateGraphics())
                {
                    float dpi = graphics.DpiX;
                    if (dpi != layoutDpi)
                    {
                        layoutDpi = dpi;
                        // WinForms sizes child controls at the current DPI but
                        // does not scale these absolute table rows with them.
                        float scale = dpi / 96f;
                        RowStyles[0].Height = (float)Math.Round(43 * scale);
                        RowStyles[1].Height = (float)Math.Round(47 * scale);
                        RowStyles[4].Height = RowStyles[2].Height = (float)Math.Round(scale);
                        RowStyles[5].Height = (float)Math.Round(57 * scale);
                    }
                }
            }
            base.OnLayout(args);
        }
    }

    internal sealed class PortalWebView : WebView2
    {
        internal Func<Keys, bool> HandleShortcut { get; set; }

        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            if (HandleShortcut != null && HandleShortcut(keyData)) return true;
            return base.ProcessCmdKey(ref message, keyData);
        }
    }
}
