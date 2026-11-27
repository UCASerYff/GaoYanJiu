using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace GaoYanJiu.Portal
{
    internal sealed class PortalInput
    {
        public string url { get; set; }
        public string name { get; set; }
        public string kind { get; set; }
        public string profile { get; set; }
        public string extractorPath { get; set; }
        public string language { get; set; }
        public string appearance { get; set; }
    }

    internal static class Program
    {
        internal const int CaptureLimit = 8 * 1024 * 1024;
        internal static readonly JavaScriptSerializer Json = new JavaScriptSerializer
        {
            MaxJsonLength = CaptureLimit, RecursionLimit = 30
        };

        [STAThread]
        private static int Main(string[] args)
        {
            var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
            try
            {
                var input = new StreamReader(Console.OpenStandardInput(), Encoding.UTF8);
                var config = Json.Deserialize<PortalInput>(input.ReadLine() ?? "");
                bool smoke = args.Length == 1 && args[0] == "--smoke-loopback";
                if (config == null || (args.Length != 0 && !smoke) || !PortalWindow.IsWebUri(config.url)
                    || (smoke && !new Uri(config.url).IsLoopback))
                {
                    output.WriteLine("{\"state\":\"error\",\"notice\":\"cannot-initialize\"}");
                    return 2;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (var window = new PortalWindow(config, input, output, smoke))
                    Application.Run(window);
                return 0;
            }
            catch (Exception)
            {
                // Do not print the exception, redirect URL, configuration, or DOM.
                output.WriteLine("{\"state\":\"error\",\"notice\":\"cannot-initialize\"}");
                return 1;
            }
        }
    }

    internal sealed class PortalWindow : Form
    {
        private readonly PortalInput config;
        private readonly StreamReader input;
        private readonly StreamWriter output;
        private readonly bool smoke;
        private readonly bool english;
        private readonly bool dark;
        private readonly Uri origin;
        private readonly TextBox address = new TextBox { Dock = DockStyle.Fill };
        private readonly Label status = new Label { AutoSize = false, Dock = DockStyle.Bottom, Height = 31, TextAlign = ContentAlignment.MiddleLeft };
        private readonly Button back;
        private readonly Button forward;
        private readonly Button reload;
        private readonly Button go;
        private readonly Button extract;
        private readonly WebView2 browser = new WebView2 { Dock = DockStyle.Fill };
        private CoreWebView2Environment environment;
        private bool loaded;
        private bool extracting;
        private bool captured;
        private bool hasFatalError;
        private int navigationGeneration;

        internal PortalWindow(PortalInput settings, StreamReader inputPipe, StreamWriter outputPipe, bool smokeMode)
        {
            config = settings;
            input = inputPipe;
            output = outputPipe;
            smoke = smokeMode;
            english = settings.language == "en";
            dark = settings.appearance == "dark" || (settings.appearance != "light" && SystemUsesDarkTheme());
            origin = new Uri(config.url, UriKind.Absolute);
            Text = Translate("搞研究 · 投稿门户", "GaoYanJiu · Submission Portal") + " — " + config.name;
            Font = new Font("Segoe UI", 10f);
            AutoScaleMode = AutoScaleMode.Dpi;
            MinimumSize = new Size(740, 520);
            Size = new Size(1160, 800);
            StartPosition = FormStartPosition.CenterScreen;
            KeyPreview = true;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            if (smoke)
            {
                ShowInTaskbar = false;
                StartPosition = FormStartPosition.Manual;
                Location = new Point(-32000, -32000);
                Size = new Size(880, 620);
            }

            BackColor = dark ? Color.FromArgb(23, 27, 25) : Color.FromArgb(243, 240, 232);
            ForeColor = dark ? Color.WhiteSmoke : Color.FromArgb(36, 43, 40);
            address.BackColor = dark ? Color.FromArgb(35, 42, 38) : Color.White;
            address.ForeColor = ForeColor;
            status.ForeColor = ForeColor;
            status.Padding = new Padding(11, 0, 11, 0);
            browser.DefaultBackgroundColor = BackColor;
            address.AccessibleName = Translate("投稿网站地址", "Portal address");
            address.Text = origin.AbsoluteUri;

            back = ButtonWithAction("←", Translate("后退", "Back"), delegate { if (browser.CanGoBack) browser.GoBack(); });
            forward = ButtonWithAction("→", Translate("前进", "Forward"), delegate { if (browser.CanGoForward) browser.GoForward(); });
            reload = ButtonWithAction("⟳", Translate("重新载入", "Reload"), delegate { if (browser.CoreWebView2 != null) browser.Reload(); });
            go = ButtonWithAction(Translate("前往", "Go"), Translate("前往当前地址", "Go to address"), NavigateAddress);
            extract = ButtonWithAction(Translate("提取稿件并审核", "Extract for review"), Translate("提取当前页面的稿件", "Extract submissions on this page"),
                async delegate { await ExtractAsync(); });
            extract.BackColor = dark ? Color.FromArgb(154, 215, 185) : Color.FromArgb(36, 75, 66);
            extract.ForeColor = dark ? Color.FromArgb(14, 25, 20) : Color.White;
            extract.Enabled = false;
            back.Enabled = false;
            forward.Enabled = false;
            go.Enabled = false;
            reload.Enabled = false;

            var nav = new TableLayoutPanel { ColumnCount = 6, RowCount = 1, Dock = DockStyle.Top, Height = 49, Padding = new Padding(9, 8, 9, 7) };
            for (int i = 0; i < 3; i++) nav.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            nav.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            nav.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            nav.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            nav.Controls.Add(back, 0, 0);
            nav.Controls.Add(forward, 1, 0);
            nav.Controls.Add(reload, 2, 0);
            nav.Controls.Add(address, 3, 0);
            nav.Controls.Add(go, 4, 0);
            nav.Controls.Add(extract, 5, 0);
            Controls.Add(browser);
            Controls.Add(status);
            Controls.Add(nav);

            SetStatus(Translate("正在启动内嵌投稿门户…", "Starting the embedded submission portal…"));
            address.KeyDown += OnAddressKeyDown;
            KeyDown += OnWindowKeyDown;
            Shown += async delegate { await InitializeAsync(); };
            FormClosed += delegate { if (!captured && !hasFatalError) Send("closed", "", null); };
        }

        protected override bool ShowWithoutActivation { get { return smoke; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams parameters = base.CreateParams;
                if (smoke) parameters.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                return parameters;
            }
        }

        internal static bool IsWebUri(string value)
        {
            Uri uri;
            return Uri.TryCreate(value, UriKind.Absolute, out uri) && uri.UserInfo.Length == 0
                && (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp);
        }

        private string Translate(string zh, string en) { return english ? en : zh; }

        private static bool SystemUsesDarkTheme()
        {
            const string key = @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
            try { return Convert.ToInt32(Microsoft.Win32.Registry.GetValue(key, "AppsUseLightTheme", 1)) == 0; }
            catch (Exception) { return false; }
        }

        private Button ButtonWithAction(string title, string accessibleName, Action action)
        {
            var button = new Button
            {
                Text = title,
                AccessibleName = accessibleName,
                AutoSize = true,
                Dock = DockStyle.Fill,
                MinimumSize = new Size(33, 27),
                Margin = new Padding(3, 0, 3, 0),
                FlatStyle = FlatStyle.Flat,
                BackColor = BackColor,
                ForeColor = ForeColor
            };
            button.FlatAppearance.BorderColor = dark ? Color.FromArgb(69, 79, 74) : Color.FromArgb(210, 210, 199);
            button.Click += delegate { action(); };
            return button;
        }

        private void OnAddressKeyDown(object sender, KeyEventArgs args)
        {
            if (args.KeyCode != Keys.Enter) return;
            args.SuppressKeyPress = true;
            NavigateAddress();
        }

        private void OnWindowKeyDown(object sender, KeyEventArgs args)
        {
            if (args.Control && args.KeyCode == Keys.L)
            {
                address.Focus();
                address.SelectAll();
                args.SuppressKeyPress = true;
            }
            else if ((args.Control && args.KeyCode == Keys.R) || args.KeyCode == Keys.F5)
            {
                if (browser.CoreWebView2 != null) browser.Reload();
                args.SuppressKeyPress = true;
            }
            else if (args.Alt && args.KeyCode == Keys.Left && browser.CanGoBack)
            {
                browser.GoBack();
                args.SuppressKeyPress = true;
            }
            else if (args.Alt && args.KeyCode == Keys.Right && browser.CanGoForward)
            {
                browser.GoForward();
                args.SuppressKeyPress = true;
            }
        }

        private void WatchForParentClose()
        {
            // EOF from the private parent pipe closes the browsing session.
            Task.Factory.StartNew(delegate
            {
                try
                {
                    string command;
                    while ((command = input.ReadLine()) != null)
                    {
                        // The offscreen probe uses the same button as the user.
                        if (smoke && command == "extract") BeginInvoke((Action)extract.PerformClick);
                    }
                }
                catch (IOException) { }
                catch (InvalidOperationException) { }
                try { BeginInvoke((Action)Close); }
                catch (InvalidOperationException) { }
            }, TaskCreationOptions.LongRunning);
        }

        private async Task InitializeAsync()
        {
            WatchForParentClose();
            try
            {
                string profile = Path.GetFullPath(config.profile);
                if (!Directory.Exists(profile) || new DirectoryInfo(profile).Attributes.HasFlag(FileAttributes.ReparsePoint))
                    throw new IOException("Invalid profile directory");
                environment = await CoreWebView2Environment.CreateAsync(null, profile);
                if (!String.Equals(Path.GetFullPath(environment.UserDataFolder), profile, StringComparison.OrdinalIgnoreCase))
                {
                    Fail("unsupported-profile", Translate("Windows 策略替换了应用资料路径，内嵌门户已停止。", "Windows policy redirected the isolated browsing profile."));
                    return;
                }
                await browser.EnsureCoreWebView2Async(environment);
                ConfigureCore(browser.CoreWebView2);
                browser.CoreWebView2.NavigationStarting += MainNavigationStarting;
                browser.CoreWebView2.NavigationCompleted += MainNavigationCompleted;
                browser.CoreWebView2.SourceChanged += delegate
                {
                    address.Text = browser.CoreWebView2.Source;
                    UpdateButtons();
                };
                browser.CoreWebView2.HistoryChanged += delegate { UpdateButtons(); };
                go.Enabled = true;
                reload.Enabled = true;
                browser.CoreWebView2.Navigate(origin.AbsoluteUri);
                Send("ready", "loading", null);
            }
            catch (WebView2RuntimeNotFoundException)
            {
                Fail("missing-runtime", Translate("需要安装 Microsoft Edge WebView2 Runtime。", "Microsoft Edge WebView2 Runtime is required."));
            }
            catch (ObjectDisposedException) { }
            catch (Exception)
            {
                Fail("cannot-initialize", Translate("内嵌投稿门户启动失败。", "The embedded submission portal could not start."));
            }
        }

        private void ConfigureCore(CoreWebView2 core)
        {
            var settings = core.Settings;
            settings.AreHostObjectsAllowed = false;
            settings.IsWebMessageEnabled = false;
            settings.IsStatusBarEnabled = false;
            settings.AreDevToolsEnabled = false;
            settings.AreDefaultContextMenusEnabled = false;
            settings.IsPasswordAutosaveEnabled = false;
            settings.IsGeneralAutofillEnabled = false;
            core.Profile.PreferredColorScheme = dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
            core.NavigationStarting += GuardNavigation;
            core.FrameNavigationStarting += GuardNavigation;
            core.NewWindowRequested += OpenPopup;
            core.PermissionRequested += delegate(object sender, CoreWebView2PermissionRequestedEventArgs args)
            {
                args.State = CoreWebView2PermissionState.Deny;
            };
            core.DownloadStarting += delegate(object sender, CoreWebView2DownloadStartingEventArgs args)
            {
                args.Cancel = true;
            };
            // A third-party page must not reach this app's local API or another
            // local service by navigating, loading a frame, or making a subrequest.
            core.AddWebResourceRequestedFilter("http://*", CoreWebView2WebResourceContext.All);
            core.AddWebResourceRequestedFilter("https://*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += delegate(object sender, CoreWebView2WebResourceRequestedEventArgs args)
            {
                Uri requested;
                if (Uri.TryCreate(args.Request.Uri, UriKind.Absolute, out requested) && requested.IsLoopback
                    && !SameOrigin(requested))
                    args.Response = environment.CreateWebResourceResponse(null, 403, "Blocked", "");
            };
        }

        private bool SameOrigin(Uri uri)
        {
            if (uri == null || !IsWebUri(uri.AbsoluteUri)) return false;
            return uri.Scheme == origin.Scheme && uri.Port == origin.Port
                && String.Equals(uri.IdnHost.TrimEnd('.'), origin.IdnHost.TrimEnd('.'), StringComparison.OrdinalIgnoreCase);
        }

        private bool NavigationAllowed(string value)
        {
            if (value == "about:blank") return true;
            if (!IsWebUri(value)) return false;
            var uri = new Uri(value);
            if (SameOrigin(uri)) return true;
            return uri.Scheme == Uri.UriSchemeHttps && !uri.IsLoopback;
        }

        private void GuardNavigation(object sender, CoreWebView2NavigationStartingEventArgs args)
        {
            if (NavigationAllowed(args.Uri)) return;
            args.Cancel = true;
            SetStatus(Translate("已拦截不支持的地址。", "This navigation is blocked."));
        }

        private async void OpenPopup(object sender, CoreWebView2NewWindowRequestedEventArgs args)
        {
            if (!args.IsUserInitiated || !NavigationAllowed(args.Uri) || smoke)
            {
                args.Handled = true;
                return;
            }
            using (args.GetDeferral())
            {
                var popup = new Form { Text = Translate("投稿门户登录", "Portal sign-in"), Size = new Size(900, 700), StartPosition = FormStartPosition.CenterParent };
                var popupBrowser = new WebView2 { Dock = DockStyle.Fill };
                var popupAddress = new TextBox { Dock = DockStyle.Top, ReadOnly = true, AccessibleName = Translate("登录地址", "Sign-in address") };
                popup.Controls.Add(popupBrowser);
                popup.Controls.Add(popupAddress);
                try
                {
                    await popupBrowser.EnsureCoreWebView2Async(environment);
                    ConfigureCore(popupBrowser.CoreWebView2);
                    popupBrowser.CoreWebView2.SourceChanged += delegate { popupAddress.Text = popupBrowser.CoreWebView2.Source; };
                    popupBrowser.CoreWebView2.WindowCloseRequested += delegate { popup.Close(); };
                    args.NewWindow = popupBrowser.CoreWebView2;
                    args.Handled = true;
                    popup.Show(this);
                }
                catch (Exception)
                {
                    popup.Dispose();
                    args.Handled = true;
                    SetStatus(Translate("无法打开投稿门户登录窗口。", "Could not open the portal sign-in window."));
                }
            }
        }

        private void MainNavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs args)
        {
            if (args.Cancel) return;
            ++navigationGeneration;
            loaded = false;
            UpdateButtons();
            SetStatus(Translate("正在加载投稿页面…", "Loading portal page…"));
        }

        private void MainNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs args)
        {
            loaded = args.IsSuccess;
            UpdateButtons();
            if (!loaded)
            {
                SetStatus(Translate("页面加载失败。请检查地址或重新载入。", "Could not load the page. Check the address or reload."));
                Send("ready", "navigation-failed", null);
                return;
            }
            if (SameOrigin(browser.Source))
            {
                SetStatus(Translate("在稿件列表或详情页点击「提取稿件并审核」。", "On a submission list or details page, click Extract for review."));
                Send("ready", "", null);
            }
            else
            {
                SetStatus(Translate("可在此页面登录。请回到所选投稿门户后提取。", "You can sign in here. Return to the selected portal to extract submissions."));
                Send("ready", "different-origin", null);
            }
        }

        private void NavigateAddress()
        {
            if (browser.CoreWebView2 == null) return;
            string value = address.Text.Trim();
            if (!value.Contains("://")) value = "https://" + value;
            if (!NavigationAllowed(value))
            {
                SetStatus(Translate("请输入有效的 HTTPS 投稿地址。", "Enter a supported HTTPS portal address."));
                return;
            }
            browser.CoreWebView2.Navigate(value);
        }

        private void UpdateButtons()
        {
            back.Enabled = browser.CanGoBack;
            forward.Enabled = browser.CanGoForward;
            extract.Enabled = loaded && !extracting && SameOrigin(browser.Source);
        }

        private async Task<Dictionary<string, object>> DevTools(string method, object parameters)
        {
            var task = browser.CoreWebView2.CallDevToolsProtocolMethodAsync(method, Program.Json.Serialize(parameters));
            if (await Task.WhenAny(task, Task.Delay(10000)) != task) throw new TimeoutException();
            return Program.Json.Deserialize<Dictionary<string, object>>(await task);
        }

        private async Task ExtractAsync()
        {
            if (!loaded || extracting || !SameOrigin(browser.Source)) return;
            int generation = navigationGeneration;
            extracting = true;
            UpdateButtons();
            SetStatus(Translate("正在提取当前页面稿件…", "Extracting submissions from this page…"));
            try
            {
                var frames = await DevTools("Page.getFrameTree", new object());
                var frameTree = (Dictionary<string, object>)frames["frameTree"];
                var frame = (Dictionary<string, object>)frameTree["frame"];
                var frameUri = new Uri((string)frame["url"]);
                if (generation != navigationGeneration || !SameOrigin(frameUri)) return;
                var world = await DevTools("Page.createIsolatedWorld", new
                {
                    frameId = (string)frame["id"],
                    worldName = "GaoYanJiuPortalExtractor"
                });
                if (generation != navigationGeneration || !SameOrigin(browser.Source)) return;
                string script = File.ReadAllText(config.extractorPath, Encoding.UTF8);
                string source = Program.Json.Serialize(new { name = config.name, kind = config.kind });
                string expression = "(async()=>{\n" + script + "\n"
                    + "const result = await globalThis.PaperSignalExtractor.extract(" + source + ");"
                    + "result.url = location.origin + location.pathname;"
                    + "return result;})()";
                var evaluated = await DevTools("Runtime.evaluate", new
                {
                    expression = expression, contextId = world["executionContextId"], awaitPromise = true, returnByValue = true
                });
                if (generation != navigationGeneration || !SameOrigin(browser.Source)) return;
                Dictionary<string, object> reply = (Dictionary<string, object>)evaluated["result"];
                Dictionary<string, object> result = reply.ContainsKey("value") ? reply["value"] as Dictionary<string, object> : null;
                if (evaluated.ContainsKey("exceptionDetails") || result == null || !result.ContainsKey("url"))
                    throw new InvalidDataException();
                Uri resultUri;
                if (!Uri.TryCreate(result["url"] as string, UriKind.Absolute, out resultUri) || !SameOrigin(resultUri))
                    throw new InvalidDataException();
                var papers = result.ContainsKey("papers") ? result["papers"] as IList : null;
                if (papers == null || papers.Count == 0)
                {
                    SetStatus(Translate("本页没有识别到完整的稿件标题和状态。", "No complete submission title and status were found on this page."));
                    Send("ready", "no-papers", null);
                    if (smoke) Close();
                    return;
                }
                Send("captured", "", result);
                captured = true;
                Close();
            }
            catch (ObjectDisposedException) { }
            catch (Exception)
            {
                if (!IsDisposed)
                {
                    SetStatus(Translate("提取失败。请确认页面已加载完成并重试。", "Extraction failed. Wait for the page to finish loading and retry."));
                    Send("ready", "extract-failed", null);
                    if (smoke) Close();
                }
            }
            finally
            {
                extracting = false;
                if (!IsDisposed) UpdateButtons();
            }
        }

        private void SetStatus(string text) { if (!IsDisposed) status.Text = text; }

        private void Fail(string notice, string text)
        {
            if (IsDisposed) return;
            hasFatalError = true;
            SetStatus(text);
            Send("error", notice, null);
            Close();
        }

        private void Send(string state, string notice, object capture)
        {
            if (capture == null) output.WriteLine(Program.Json.Serialize(new { state = state, notice = notice }));
            else
            {
                string response = Program.Json.Serialize(new { state = state, capture = capture });
                if (Encoding.UTF8.GetByteCount(response) >= Program.CaptureLimit) throw new InvalidDataException();
                output.WriteLine(response);
            }
        }
    }
}
