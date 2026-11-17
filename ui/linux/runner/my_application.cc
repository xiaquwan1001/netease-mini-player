#include "my_application.h"

#include <dlfcn.h>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // ---- 关闭行为(退出 / 隐藏到托盘), 见下面 "Linux 关闭行为" 一节 ----
  GtkWindow* window;                 // 主窗口(隐藏/恢复都靠它; 退出时置 nullptr)
  FlMethodChannel* desktop_channel;  // ncm/desktop_shell: 与 Dart 交换关闭行为/托盘可用性
  struct _AppIndicator* indicator;   // 托盘图标(dlopen 出来的 AppIndicator, 可能为 nullptr)
  GtkWidget* tray_menu;              // 托盘菜单(自持一份引用, dispose 时销毁)
  gboolean close_to_tray;            // 当前设置: TRUE = 点关闭隐藏到托盘
  gboolean quitting;                 // 正在真退出(此时不再拦截关闭事件)
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// ---------------------------------------------------------------------------
// Linux 关闭行为: 「直接退出」vs「隐藏到系统托盘」(lane/tray-close)
//
// 为什么用 GTK/AppIndicator **原生**实现, 而不是 Flutter 插件(tray_manager /
// system_tray):
//   1. 关闭请求的分流点其实在**Dart**(Flutter 的 FlView 在 realize 时抢连了窗口的
//      "delete-event" 并调 fl_engine_request_app_exit, 见 desktop_shell.dart 的
//      DesktopCloseObserver), 原生只需要"建托盘 + 隐藏/最小化窗口"。
//      tray_manager 那类插件也只管画图标, 但会多一份 pub 依赖与一套插件通道。
//   2. 插件的 Linux 后端最终也是 libayatana-appindicator3, 打包代价完全相同
//      (deb 多一个 Recommends), 换不来任何东西。
//   3. 原生实现能**运行期 dlopen**(见下): 没有该库的机器照常启动, 只是托盘降级;
//      插件是构建期硬链接, 缺库直接 "error while loading shared libraries"。
//
// 降级口径(必须优雅, 不能崩、不能让窗口凭空消失): 没有 StatusNotifierWatcher
// (裸窗口管理器 / GNOME 没装 AppIndicator 扩展 / 无 session bus)或没有
// libayatana-appindicator3 时, 点关闭退化为「最小化到任务栏」(hideToTray 返回
// false, Dart 弹一次提示), 设置页也会显示"当前桌面没有托盘"。
// ---------------------------------------------------------------------------

namespace {

/// 托盘宿主在会话总线上的 well-known name(StatusNotifier 规范, KDE/GNOME 扩展都用它)。
constexpr const char* kTrayWatcherBusName = "org.kde.StatusNotifierWatcher";

/// 与 Dart 约定的通道名(见 ui/lib/src/desktop_shell.dart)。
constexpr const char* kDesktopChannelName = "ncm/desktop_shell";

// libayatana-appindicator3 的最小 ABI 子集: 不引头文件 ⇒ 构建期零依赖,
// 运行期 dlopen 探测 ⇒ 缺库只降级不崩。枚举值取自 app-indicator.h, 0.4 起未变:
//   APP_INDICATOR_CATEGORY_APPLICATION_STATUS = 0
//   APP_INDICATOR_STATUS_PASSIVE = 0 / ACTIVE = 1
constexpr int kIndicatorCategoryApplicationStatus = 0;
constexpr int kIndicatorStatusPassive = 0;
constexpr int kIndicatorStatusActive = 1;

using AppIndicatorRef = struct _AppIndicator;
using AppIndicatorNewFn = AppIndicatorRef* (*)(const gchar*, const gchar*, int);
using AppIndicatorStatusFn = void (*)(AppIndicatorRef*, int);
using AppIndicatorIconFn = void (*)(AppIndicatorRef*, const gchar*, const gchar*);
using AppIndicatorWidgetFn = void (*)(AppIndicatorRef*, GtkWidget*);
using AppIndicatorStringFn = void (*)(AppIndicatorRef*, const gchar*);

struct AppIndicatorApi {
  AppIndicatorNewFn create = nullptr;
  AppIndicatorStatusFn set_status = nullptr;
  AppIndicatorIconFn set_icon_full = nullptr;
  AppIndicatorWidgetFn set_menu = nullptr;
  AppIndicatorWidgetFn set_secondary_activate_target = nullptr;
  AppIndicatorStringFn set_title = nullptr;

  bool ready() const {
    return create != nullptr && set_status != nullptr &&
           set_icon_full != nullptr && set_menu != nullptr;
  }
};

/// 懒加载: 第一次用到关闭行为时才 dlopen(找不到库也只是返回空 api)。
AppIndicatorApi& appindicator_api() {
  static AppIndicatorApi api = [] {
    AppIndicatorApi loaded;
    // 优先 Ayatana(appindicator 分支后的事实标准), 再退回老的 libappindicator3。
    void* handle =
        dlopen("libayatana-appindicator3.so.1", RTLD_LAZY | RTLD_LOCAL);
    if (handle == nullptr) {
      handle = dlopen("libappindicator3.so.1", RTLD_LAZY | RTLD_LOCAL);
    }
    if (handle == nullptr) return loaded;
    loaded.create = reinterpret_cast<AppIndicatorNewFn>(
        dlsym(handle, "app_indicator_new"));
    loaded.set_status = reinterpret_cast<AppIndicatorStatusFn>(
        dlsym(handle, "app_indicator_set_status"));
    loaded.set_icon_full = reinterpret_cast<AppIndicatorIconFn>(
        dlsym(handle, "app_indicator_set_icon_full"));
    loaded.set_menu = reinterpret_cast<AppIndicatorWidgetFn>(
        dlsym(handle, "app_indicator_set_menu"));
    loaded.set_secondary_activate_target = reinterpret_cast<AppIndicatorWidgetFn>(
        dlsym(handle, "app_indicator_set_secondary_activate_target"));
    loaded.set_title = reinterpret_cast<AppIndicatorStringFn>(
        dlsym(handle, "app_indicator_set_title"));
    if (!loaded.ready()) {
      dlclose(handle);
      return AppIndicatorApi();
    }
    return loaded;
  }();
  return api;
}

/// 托盘宿主是否存在: 会话总线上 org.kde.StatusNotifierWatcher 有 owner 才算。
/// 没有它时托盘图标不会出现在任何地方 —— 这种时候如果照常隐藏窗口, 用户就
/// "点关闭后再也找不到应用"(任务栏也没了), 所以必须降级。
gboolean tray_watcher_available() {
  GError* error = nullptr;
  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus == nullptr) {
    g_message("close-to-tray: 连不上会话总线(%s), 托盘不可用",
              error != nullptr ? error->message : "unknown");
    g_clear_error(&error);
    return FALSE;
  }
  gboolean owned = FALSE;
  GVariant* reply = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner",
      g_variant_new("(s)", kTrayWatcherBusName), G_VARIANT_TYPE("(b)"),
      G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, &error);
  if (reply != nullptr) {
    g_variant_get(reply, "(b)", &owned);
    g_variant_unref(reply);
  } else {
    g_message("close-to-tray: 查询 %s 失败(%s), 托盘不可用",
              kTrayWatcherBusName,
              error != nullptr ? error->message : "unknown");
    g_clear_error(&error);
  }
  g_object_unref(bus);
  return owned;
}

/// 恢复主窗口(托盘菜单 / 第二次启动激活都会走这里)。
void present_window(MyApplication* self) {
  if (self->window == nullptr) return;
  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_present(self->window);
}

/// 真退出: 销毁主窗口(GtkApplication 于是退出) + 显式 quit 兜底。
///
/// 这是"真退出才停播放"的落点: 进程结束后 Rust 的音频线程(symphonia/CORE
/// 解码 + CPAL/ALSA 输出)随之销毁; 而"隐藏到托盘"完全不碰进程、Dart isolate
/// 与音频线程, 所以播放继续。
void desktop_quit(MyApplication* self) {
  self->quitting = TRUE;
  if (self->window != nullptr) {
    GtkWindow* window = self->window;
    self->window = nullptr;
    gtk_widget_destroy(GTK_WIDGET(window));
  }
  g_application_quit(G_APPLICATION(self));
}

/// 托盘菜单「显示主界面」。
void tray_show_window_cb(GtkMenuItem* /*item*/, gpointer user_data) {
  present_window(MY_APPLICATION(user_data));
}

/// 托盘菜单「退出」= 真的终止进程(不是再隐藏一次)。
void tray_quit_cb(GtkMenuItem* /*item*/, gpointer user_data) {
  desktop_quit(MY_APPLICATION(user_data));
}

/// 确保托盘图标存在(幂等)。返回 FALSE = 这台机器上没有可用托盘宿主。
gboolean ensure_tray(MyApplication* self) {
  if (self->indicator != nullptr) return TRUE;
  AppIndicatorApi& api = appindicator_api();
  if (!api.ready()) {
    g_message("close-to-tray: 没有 libayatana-appindicator3, 托盘不可用");
    return FALSE;
  }
  if (!tray_watcher_available()) {
    g_message("close-to-tray: 没有 StatusNotifierWatcher 宿主, 托盘不可用");
    return FALSE;
  }
  // 图标: deb 装到 hicolor 主题里叫 minincm; 源码运行/AppImage 未集成时退回主题
  // 自带的音乐图标(否则托盘是个空白方块)。
  const char* icon_name = "minincm";
  GtkIconTheme* icon_theme = gtk_icon_theme_get_default();
  if (icon_theme == nullptr ||
      !gtk_icon_theme_has_icon(icon_theme, icon_name)) {
    icon_name = "audio-x-generic";
  }
  AppIndicatorRef* indicator = api.create(
      APPLICATION_ID, icon_name, kIndicatorCategoryApplicationStatus);
  if (indicator == nullptr) {
    g_message("close-to-tray: app_indicator_new 失败, 托盘不可用");
    return FALSE;
  }
  GtkWidget* menu = gtk_menu_new();
  GtkWidget* show_item = gtk_menu_item_new_with_label("显示主界面");
  g_signal_connect(show_item, "activate", G_CALLBACK(tray_show_window_cb),
                   self);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), show_item);
  GtkWidget* quit_item = gtk_menu_item_new_with_label("退出");
  g_signal_connect(quit_item, "activate", G_CALLBACK(tray_quit_cb), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit_item);
  gtk_widget_show_all(menu);

  api.set_menu(indicator, menu);
  if (api.set_secondary_activate_target != nullptr) {
    // 次要激活键(中键)直接恢复窗口。主键行为由宿主决定(SNI 只定义了菜单):
    // KDE/GNOME 扩展左键都打开菜单, 菜单第一项就是「显示主界面」。
    api.set_secondary_activate_target(indicator, show_item);
  }
  if (api.set_title != nullptr) api.set_title(indicator, "轻音 MiniNCM");
  api.set_icon_full(indicator, icon_name, "轻音 MiniNCM");
  api.set_status(indicator, kIndicatorStatusActive);

  self->indicator = indicator;
  self->tray_menu = menu;
  g_message("close-to-tray: 托盘已就绪(图标 %s)", icon_name);
  return TRUE;
}

/// 处理"用户点了关闭按钮"的**落地动作**(分流点在 Dart: Flutter 的 FlView 自己连了
/// toplevel 的 delete-event 并返回 TRUE 调 fl_engine_request_app_exit, 信号到不了这里;
/// Dart 侧在 didRequestAppExit 里决定 hide 还是 exit, 见 desktop_shell.dart)。
///
/// 本函数只做原生能做的那一件事: 有托盘就隐藏主窗口(进程/播放继续), 没托盘就
/// 最小化到任务栏(窗口不消失、也不会假装有托盘)。返回值 = 是否真的隐藏到了托盘。
gboolean hide_or_minimize(MyApplication* self) {
  if (self->window == nullptr) return FALSE;
  if (ensure_tray(self)) {
    gtk_widget_hide(GTK_WIDGET(self->window));
    g_message("close-to-tray: 主窗口已隐藏到托盘, 播放继续");
    return TRUE;
  }
  // 降级分支: 没有托盘宿主 ⇒ 最小化到任务栏(任务栏里还能点回来)
  gtk_window_iconify(self->window);
  g_message("close-to-tray: 无托盘宿主, 降级为最小化到任务栏");
  return FALSE;
}

/// 托盘/关闭能力的状态快照(Dart 侧设置页与启动日志都用它)。
FlValue* tray_status_value(MyApplication* self) {
  AppIndicatorApi& api = appindicator_api();
  const gboolean appindicator = api.ready();
  const gboolean watcher = appindicator && tray_watcher_available();
  const char* reason = "ok";
  if (!appindicator) {
    reason = "no-libappindicator";
  } else if (!watcher) {
    reason = "no-status-notifier-host";
  }
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "trayAvailable",
                           fl_value_new_bool(self->indicator != nullptr ||
                                             watcher));
  fl_value_set_string_take(map, "libAppIndicator",
                           fl_value_new_bool(appindicator));
  fl_value_set_string_take(map, "closeToTray",
                           fl_value_new_bool(self->close_to_tray));
  fl_value_set_string_take(map, "reason", fl_value_new_string(reason));
  return map;
}

/// ncm/desktop_shell 的方法实现(Dart → 原生)。
void desktop_channel_on_method_call(FlMethodChannel* /*channel*/,
                                    FlMethodCall* method_call,
                                    gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "getStatus") == 0) {
    FlValue* status = tray_status_value(self);
    fl_method_call_respond_success(method_call, status, nullptr);
    fl_value_unref(status);
    return;
  }
  if (g_strcmp0(method, "setCloseBehavior") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    const gchar* behavior = (args != nullptr &&
                             fl_value_get_type(args) == FL_VALUE_TYPE_STRING)
                                ? fl_value_get_string(args)
                                : "quit";
    self->close_to_tray = g_strcmp0(behavior, "tray") == 0;
    g_message("close-to-tray: 关闭行为 = %s",
              self->close_to_tray ? "隐藏到托盘" : "直接退出");
    if (self->close_to_tray) {
      // 提前建好托盘: 首次点关闭时才是"即时隐藏", 不用等首次探测。
      ensure_tray(self);
    }
    FlValue* active = fl_value_new_bool(self->indicator != nullptr);
    fl_method_call_respond_success(method_call, active, nullptr);
    fl_value_unref(active);
    return;
  }
  if (g_strcmp0(method, "hideToTray") == 0) {
    FlValue* hidden = fl_value_new_bool(hide_or_minimize(self));
    fl_method_call_respond_success(method_call, hidden, nullptr);
    fl_value_unref(hidden);
    return;
  }
  if (g_strcmp0(method, "showWindow") == 0) {
    present_window(self);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    return;
  }
  if (g_strcmp0(method, "quit") == 0) {
    // 先回包再退出, 否则 Dart 侧拿到的是"通道已关闭"异常。
    fl_method_call_respond_success(method_call, nullptr, nullptr);
    desktop_quit(self);
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

}  // namespace

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // 启动就探测一次托盘能力并写日志: 无头冒烟据此断言"探测跑了 + 缺宿主也不崩",
  // 真实桌面出问题时也能从日志判断托盘为何没出现(没有宿主 vs 没有库)。
  {
    AppIndicatorApi& api = appindicator_api();
    g_message("close-to-tray: 启动探测 libayatana-appindicator3=%s, "
              "StatusNotifierWatcher=%s",
              api.ready() ? "有" : "无",
              (api.ready() && tray_watcher_available()) ? "有" : "无");
  }

  // 严格单实例(P-18 后半): 第二个进程的 activate 会被 GApplication 转发到主实例
  // (my_application_new 里不再用 G_APPLICATION_NON_UNIQUE), 这里只把已有窗口提到前台,
  // 不再开第二个窗口 —— 否则同一份 dataDir 会被两个窗口并发写(设置/播放现场/TTML 缓存)。
  // 迁移窗口期例外: 旧版本(com.minincm.minincm)与新版本 id 不同, 两者互不可见, 可同时运行。
  GList* existing = gtk_application_get_windows(GTK_APPLICATION(application));
  if (existing != nullptr) {
    // 隐藏到托盘后再启动一个实例: 这里要连隐藏的窗口一起提回前台。
    gtk_widget_show(GTK_WIDGET(existing->data));
    gtk_window_present(GTK_WINDOW(existing->data));
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    // 窗口标题两平台统一(轻音 MiniNCM): 与 ui/windows/runner/main.cpp 的
    // window.Create 标题保持一致, 改一处要同步另一处(P-18).
    gtk_header_bar_set_title(header_bar, "轻音 MiniNCM");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "轻音 MiniNCM");
  }

  // 默认窗口尺寸两平台统一 1280x720: 与 ui/windows/runner/main.cpp 的
  // Win32Window::Size 保持一致, 改一处要同步另一处(P-18).
  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // ---- 关闭行为 / 托盘: 主窗口登记 + Dart 通道 ----
  //
  // 注意不要在这里连 GtkWindow 的 "delete-event": Flutter 的 FlView 在 realize 时
  // 已经连了同一个信号, 且它的回调返回 TRUE(调 fl_engine_request_app_exit) —— 信号
  // 到不了后连的处理器(实测: 我们的回调一次都不会被调, 进程被 Dart 侧正常退出)。
  // 所以"点关闭"的分流点在 Dart(didRequestAppExit), 这里只提供隐藏/最小化与托盘。
  self->window = window;
  {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    FlBinaryMessenger* messenger =
        fl_engine_get_binary_messenger(fl_view_get_engine(view));
    self->desktop_channel = fl_method_channel_new(
        messenger, kDesktopChannelName, FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(
        self->desktop_channel, desktop_channel_on_method_call, self, nullptr);
  }

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  if (self->desktop_channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->desktop_channel, nullptr,
                                              nullptr, nullptr);
    g_clear_object(&self->desktop_channel);
  }
  if (self->indicator != nullptr) {
    AppIndicatorApi& api = appindicator_api();
    if (api.set_status != nullptr) {
      api.set_status(self->indicator, kIndicatorStatusPassive);
    }
    g_object_unref(self->indicator);
    self->indicator = nullptr;
  }
  if (self->tray_menu != nullptr) {
    gtk_widget_destroy(self->tray_menu);
    self->tray_menu = nullptr;
  }
  self->window = nullptr;
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  // 注意: g_set_prgname 同时决定 WM_CLASS(res_name 与 res_class), 所以
  // packaging/linux 里 .desktop 的 StartupWMClass 必须与 APPLICATION_ID 完全一致,
  // 否则任务栏会出现两个图标/图标不归组。
  g_set_prgname(APPLICATION_ID);

  // flags = 0(P-18 后半: 严格单实例)。原来是 G_APPLICATION_NON_UNIQUE(每次启动都是
  // 独立实例, 两个窗口会同时写同一份 dataDir)。用显式强转而不是
  // G_APPLICATION_DEFAULT_FLAGS: 后者 Since 2.74, 而 CMakeLists 把 GLib 基线钉在 2.72。
  // 代价: 需要 session bus(桌面环境都有); 无 bus 时 g_application_register 失败并退 1。
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     static_cast<GApplicationFlags>(0), nullptr));
}
