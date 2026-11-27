using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
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
        private readonly PortalTheme theme;
        private readonly PortalChrome chrome;
        private readonly Uri origin;
        private CoreWebView2Environment environment;
        private bool loaded;
        private bool extracting;
        private bool captured;
        private bool hasFatalError;
        private int navigationGeneration;
        private bool probeAuthRequested;

        private WebView2 browser { get { return chrome.Browser; } }

        internal PortalWindow(PortalInput settings, StreamReader inputPipe, StreamWriter outputPipe, bool smokeMode)
        {
            config = settings;
            input = inputPipe;
            output = outputPipe;
            smoke = smokeMode;
            english = settings.language == "en";
            theme = new PortalTheme(settings.appearance);
            chrome = new PortalChrome(theme, english, settings.name, false);
            origin = new Uri(config.url, UriKind.Absolute);
            Text = Translate("搞研究 · 投稿门户", "GaoYanJiu · Submission portal");
            Font = new Font(english ? "Segoe UI" : "Microsoft YaHei UI", 9.5f);
            AutoScaleDimensions = new SizeF(96, 96);
            AutoScaleMode = AutoScaleMode.Dpi;
            MinimumSize = new Size(590, 450);
            ClientSize = new Size(1080, 702);
            StartPosition = FormStartPosition.CenterScreen;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            theme.ApplyCaption(this);
            if (smoke)
            {
                ShowInTaskbar = false;
                StartPosition = FormStartPosition.Manual;
                Location = new Point(-32000, -32000);
                ClientSize = new Size(840, 588);
            }

            BackColor = theme.Canvas;
            chrome.SetAddress(origin.AbsoluteUri);
            chrome.Finish.Enabled = false;
            Controls.Add(chrome);
            BindNavigation(chrome);
            chrome.Go.Click += delegate { NavigateAddress(); };
            chrome.Address.KeyDown += delegate(object sender, KeyEventArgs args)
            {
                if (args.KeyCode != Keys.Enter || args.Modifiers != Keys.None) return;
                args.SuppressKeyPress = true;
                NavigateAddress();
            };
            chrome.Finish.Click += async delegate { await ExtractAsync(); };
            BindBrowserShortcuts(this, chrome, false);
            SetStatus(Translate("正在启动投稿窗口…", "Opening the submission portal…"), PortalStatus.Busy);
            Shown += async delegate
            {
                if (!smoke) FitToWorkingArea(this);
                await InitializeAsync();
            };
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

        private static void FitToWorkingArea(Form window)
        {
            Rectangle desktop = Screen.FromControl(window).WorkingArea;
            int width = Math.Max(window.MinimumSize.Width, Math.Min(window.Width, desktop.Width - 18));
            int height = Math.Max(window.MinimumSize.Height, Math.Min(window.Height, desktop.Height - 18));
            if (width != window.Width || height != window.Height)
                window.Bounds = new Rectangle(desktop.Left + (desktop.Width - width) / 2,
                    desktop.Top + (desktop.Height - height) / 2, width, height);
        }

        private static void BindNavigation(PortalChrome windowChrome)
        {
            WebView2 view = windowChrome.Browser;
            windowChrome.Back.Click += delegate { if (view.CanGoBack) view.GoBack(); };
            windowChrome.Forward.Click += delegate { if (view.CanGoForward) view.GoForward(); };
            windowChrome.Reload.Click += delegate { if (view.CoreWebView2 != null) view.Reload(); };
        }

        private static Action Shortcut(PortalChrome windowChrome, bool signIn, Keys keyData)
        {
            if (keyData == (Keys.Control | Keys.L))
                return delegate { windowChrome.Address.Focus(); windowChrome.Address.SelectAll(); };
            if (keyData == Keys.F5 || keyData == (Keys.Control | Keys.R)) return windowChrome.Reload.PerformClick;
            if (keyData == (Keys.Alt | Keys.Left)) return windowChrome.Back.PerformClick;
            if (keyData == (Keys.Alt | Keys.Right)) return windowChrome.Forward.PerformClick;
            if (keyData == (signIn ? Keys.Escape : Keys.Control | Keys.Enter)) return windowChrome.Finish.PerformClick;
            return null;
        }

        private static void BindBrowserShortcuts(Form window, PortalChrome windowChrome, bool signIn)
        {
            window.KeyPreview = true;
            window.KeyDown += delegate(object sender, KeyEventArgs args)
            {
                Action action = Shortcut(windowChrome, signIn, args.KeyData);
                if (action == null) return;
                args.SuppressKeyPress = true;
                action();
            };
            windowChrome.Browser.HandleShortcut = delegate(Keys keyData)
            {
                Action action = Shortcut(windowChrome, signIn, keyData);
                if (action == null || window.IsDisposed) return false;
                window.BeginInvoke(action);
                return true;
            };
            // The WinForms SDK raises KeyDown for accelerators originating in
            // the focused web page, outside the form's own message handling.
            windowChrome.Browser.KeyDown += delegate(object sender, KeyEventArgs args)
            {
                if (windowChrome.Browser.HandleShortcut(args.KeyData)) args.SuppressKeyPress = true;
            };
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
                        if (!smoke) continue;
                        if (command == "extract") BeginInvoke((Action)chrome.Finish.PerformClick);
                        if (command == "layout-compact") BeginInvoke((Action)ProbeCompactLayout);
                        if (command == "layout-auth") BeginInvoke((Action)ProbeAuthLayout);
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
                ConfigureCore(chrome);
                browser.CoreWebView2.NavigationStarting += MainNavigationStarting;
                browser.CoreWebView2.NavigationCompleted += MainNavigationCompleted;
                browser.CoreWebView2.SourceChanged += delegate
                {
                    chrome.SetAddress(browser.CoreWebView2.Source);
                    UpdateButtons();
                };
                browser.CoreWebView2.HistoryChanged += delegate { UpdateButtons(); };
                chrome.Go.Enabled = true;
                chrome.Reload.Enabled = true;
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

        private void ConfigureCore(PortalChrome windowChrome)
        {
            CoreWebView2 core = windowChrome.Browser.CoreWebView2;
            var settings = core.Settings;
            settings.AreHostObjectsAllowed = false;
            settings.IsWebMessageEnabled = false;
            settings.IsStatusBarEnabled = false;
            settings.AreDevToolsEnabled = false;
            settings.AreDefaultContextMenusEnabled = false;
            settings.IsPasswordAutosaveEnabled = false;
            settings.IsGeneralAutofillEnabled = false;
            core.Profile.PreferredColorScheme = theme.Dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
            core.NavigationStarting += delegate(object sender, CoreWebView2NavigationStartingEventArgs args) { GuardNavigation(windowChrome, args); };
            core.FrameNavigationStarting += delegate(object sender, CoreWebView2NavigationStartingEventArgs args) { GuardNavigation(windowChrome, args); };
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

        private void GuardNavigation(PortalChrome windowChrome, CoreWebView2NavigationStartingEventArgs args)
        {
            if (NavigationAllowed(args.Uri)) return;
            args.Cancel = true;
            windowChrome.SetStatus(Translate("此地址已拦截，请返回投稿站或登录站。", "This address was blocked. Return to the portal or its sign-in page."), PortalStatus.Warning);
        }

        private async void OpenPopup(object sender, CoreWebView2NewWindowRequestedEventArgs args)
        {
            if (!args.IsUserInitiated || !NavigationAllowed(args.Uri) || (smoke && !probeAuthRequested))
            {
                args.Handled = true;
                return;
            }
            using (args.GetDeferral())
            {
                var popup = new PortalPopup(smoke)
                {
                    Text = Translate("搞研究 · 投稿登录", "GaoYanJiu · Portal sign-in"), ShowInTaskbar = false,
                    AutoScaleDimensions = new SizeF(96, 96), AutoScaleMode = AutoScaleMode.Dpi,
                    ClientSize = new Size(870, 640), MinimumSize = new Size(530, 420),
                    StartPosition = smoke ? FormStartPosition.Manual : FormStartPosition.CenterParent, BackColor = theme.Canvas,
                    Font = new Font(english ? "Segoe UI" : "Microsoft YaHei UI", 9.5f), Icon = Icon
                };
                if (smoke) popup.Location = new Point(-32000, -32000);
                else popup.Shown += delegate { FitToWorkingArea(popup); };
                theme.ApplyCaption(popup);
                var popupChrome = new PortalChrome(theme, english, config.name, true);
                popupChrome.SetAddress(args.Uri);
                popupChrome.SetStatus(Translate("正在打开登录网站…", "Opening the sign-in website…"), PortalStatus.Busy);
                popupChrome.Finish.Click += delegate { popup.Close(); };
                BindNavigation(popupChrome);
                BindBrowserShortcuts(popup, popupChrome, true);
                popup.Controls.Add(popupChrome);
                try
                {
                    WebView2 popupBrowser = popupChrome.Browser;
                    await popupBrowser.EnsureCoreWebView2Async(environment);
                    ConfigureCore(popupChrome);
                    popupChrome.Reload.Enabled = true;
                    popupBrowser.CoreWebView2.SourceChanged += delegate { popupChrome.SetAddress(popupBrowser.CoreWebView2.Source); };
                    popupBrowser.CoreWebView2.HistoryChanged += delegate
                    {
                        popupChrome.Back.Enabled = popupBrowser.CanGoBack;
                        popupChrome.Forward.Enabled = popupBrowser.CanGoForward;
                    };
                    popupBrowser.CoreWebView2.NavigationStarting += delegate(object source, CoreWebView2NavigationStartingEventArgs navigation)
                    {
                        if (!navigation.Cancel)
                            popupChrome.SetStatus(Translate("正在加载登录页面…", "Loading sign-in page…"), PortalStatus.Busy);
                    };
                    popupBrowser.CoreWebView2.NavigationCompleted += async delegate(object source, CoreWebView2NavigationCompletedEventArgs navigation)
                    {
                        if (navigation.IsSuccess)
                            popupChrome.SetStatus(Translate("登录完成后返回投稿门户。", "Return to the portal when sign-in is complete."), PortalStatus.Ready);
                        else
                            popupChrome.SetStatus(Translate("登录页面加载失败，可以重新载入。", "The sign-in page could not load. Reload to try again."), PortalStatus.Warning);
                        if (smoke && probeAuthRequested)
                        {
                            probeAuthRequested = false;
                            await SaveProbe(popup, popupChrome, "auth");
                            popup.Close();
                        }
                    };
                    popupBrowser.CoreWebView2.WindowCloseRequested += delegate { popup.Close(); };
                    args.NewWindow = popupBrowser.CoreWebView2;
                    args.Handled = true;
                    popup.Show(this);
                }
                catch (Exception)
                {
                    popup.Dispose();
                    args.Handled = true;
                    SetStatus(Translate("无法打开投稿登录窗口，请从当前页面重试。", "The sign-in window could not open. Try again from the current page."), PortalStatus.Warning);
                }
            }
        }

        private async void ProbeCompactLayout()
        {
            if (!loaded || !SameOrigin(browser.Source)) return;
            using (Graphics graphics = CreateGraphics())
            {
                float dpi = graphics.DpiX / 96f;
                ClientSize = new Size((int)(600 * dpi), (int)(460 * dpi));
            }
            await Task.Delay(150);
            await SaveProbe(this, chrome, "compact");
        }

        private async void ProbeAuthLayout()
        {
            if (!loaded || !SameOrigin(browser.Source)) return;
            probeAuthRequested = true;
            try
            {
                await DevTools("Runtime.evaluate", new
                {
                    expression = "window.open('/gao-fixture-sign-in?temporary=hidden', 'gaoFixtureSignIn')",
                    userGesture = true
                });
            }
            catch (Exception) { probeAuthRequested = false; }
        }

        private async Task SaveProbe(Form window, PortalChrome surface, string name)
        {
            try
            {
                using (var page = new MemoryStream())
                {
                    Task capture = surface.Browser.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, page);
                    if (await Task.WhenAny(capture, Task.Delay(5000)) != capture) throw new TimeoutException();
                    await capture;
                    page.Position = 0;
                    using (var image = new Bitmap(window.ClientSize.Width, window.ClientSize.Height))
                    {
                        surface.DrawToBitmap(image, window.ClientRectangle);
                        using (var content = Image.FromStream(page))
                        using (Graphics graphics = Graphics.FromImage(image))
                        {
                            Rectangle view = window.RectangleToClient(surface.Browser.RectangleToScreen(surface.Browser.ClientRectangle));
                            graphics.DrawImage(content, view);
                        }
                        image.Save(Path.Combine(config.profile, name + ".png"), ImageFormat.Png);
                    }
                }
                using (Graphics graphics = window.CreateGraphics())
                {
                    Rectangle action = window.RectangleToClient(surface.Finish.RectangleToScreen(surface.Finish.ClientRectangle));
                    Rectangle navigation = window.RectangleToClient(surface.Reload.RectangleToScreen(surface.Reload.ClientRectangle));
                    Rectangle page = window.RectangleToClient(surface.Browser.RectangleToScreen(surface.Browser.ClientRectangle));
                    var layout = new
                    {
                        theme = theme.Dark ? "dark" : "light",
                        dpi = graphics.DpiX,
                        width = window.ClientSize.Width,
                        height = window.ClientSize.Height,
                        addressWidth = surface.Address.Width,
                        buttonHeight = surface.Finish.Height,
                        rows = surface.GetRowHeights(),
                        actionFits = window.ClientRectangle.Contains(action)
                            && action.Width >= surface.Finish.GetPreferredSize(Size.Empty).Width
                            && navigation.Bottom <= page.Top && action.Top >= page.Bottom,
                        status = surface.StatusText,
                        address = surface.Address.Text
                    };
                    File.WriteAllText(Path.Combine(config.profile, name + ".json"), Program.Json.Serialize(layout));
                }
            }
            catch (Exception)
            {
                File.WriteAllText(Path.Combine(config.profile, name + ".json"), "{\"error\":\"visual-capture-failed\"}");
            }
        }

        private void MainNavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs args)
        {
            if (args.Cancel) return;
            ++navigationGeneration;
            loaded = false;
            UpdateButtons();
            SetStatus(Translate("正在加载投稿页面…", "Loading portal page…"), PortalStatus.Busy);
        }

        private void MainNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs args)
        {
            loaded = args.IsSuccess;
            UpdateButtons();
            if (!loaded)
            {
                SetStatus(Translate("页面加载失败。检查地址或重新载入。", "The page could not load. Check the address or reload."), PortalStatus.Warning);
                Send("ready", "navigation-failed", null);
                return;
            }
            if (SameOrigin(browser.Source))
            {
                SetStatus(Translate("打开稿件列表或详情后，即可提取并审核。", "Open a submission list or article page, then extract for review."), PortalStatus.Ready);
                Send("ready", "", null);
            }
            else
            {
                SetStatus(Translate("请在本页登录。返回投稿站后即可提取。", "Sign in here. You can extract submissions after returning to the portal."), PortalStatus.Ready);
                Send("ready", "different-origin", null);
            }
        }

        private void NavigateAddress()
        {
            if (browser.CoreWebView2 == null) return;
            string value = chrome.Address.Text.Trim();
            if (!value.Contains("://")) value = "https://" + value;
            if (!NavigationAllowed(value))
            {
                SetStatus(Translate("请输入有效的投稿网站地址。", "Enter a valid submission website address."), PortalStatus.Warning);
                return;
            }
            browser.CoreWebView2.Navigate(value);
        }

        private void UpdateButtons()
        {
            chrome.Back.Enabled = browser.CanGoBack;
            chrome.Forward.Enabled = browser.CanGoForward;
            chrome.Finish.Enabled = loaded && !extracting && SameOrigin(browser.Source);
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
            SetStatus(Translate("正在提取当前页面的稿件…", "Extracting submissions from this page…"), PortalStatus.Busy);
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
                    SetStatus(Translate("未找到稿件标题或状态。请打开稿件列表后重试。", "No submission titles or statuses found. Open the submission list and try again."), PortalStatus.Warning);
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
                    SetStatus(Translate("提取失败。请在页面加载完成后重试。", "Extraction failed. Try again after the page finishes loading."), PortalStatus.Warning);
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

        private void SetStatus(string text, PortalStatus mood) { if (!IsDisposed) chrome.SetStatus(text, mood); }

        private void Fail(string notice, string text)
        {
            if (IsDisposed) return;
            hasFatalError = true;
            SetStatus(text, PortalStatus.Warning);
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

    internal sealed class PortalPopup : Form
    {
        private readonly bool offscreen;

        internal PortalPopup(bool offscreenMode) { offscreen = offscreenMode; }

        protected override bool ShowWithoutActivation { get { return offscreen; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams parameters = base.CreateParams;
                if (offscreen) parameters.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                return parameters;
            }
        }
    }
}
