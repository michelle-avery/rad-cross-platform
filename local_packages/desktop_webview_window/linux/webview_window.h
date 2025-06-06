//
// Created by boyan on 10/21/21.
// Modified by Michelle Avery on 04/22/25.
//

#ifndef WEBVIEW_WINDOW_LINUX_WEBVIEW_WINDOW_H_
#define WEBVIEW_WINDOW_LINUX_WEBVIEW_WINDOW_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <libsoup/soup.h>
#include <webkit2/webkit2.h>

#include <functional>
#include <string>

typedef struct {
    GMainLoop *loop;
    GList *cookies;
} CookieData;

void get_cookies_callback(WebKitCookieManager *manager, GAsyncResult *res,
                          gpointer user_data);

GList *get_cookies_sync(WebKitWebView *web_view);

class WebviewWindow {
 public:
  WebviewWindow(FlMethodChannel *method_channel, int64_t window_id,
                std::function<void()> on_close_callback,
                const std::string &title, int width, int height,
                int title_bar_height, 
                bool open_maximized,
                bool open_fullscreen,
                bool force_native_chromeless);

  virtual ~WebviewWindow();

  void Navigate(const char *url);

  void RunJavaScriptWhenContentReady(const char *java_script);

  void Close();

  void SetApplicationNameForUserAgent(const std::string &app_name);

  void OnLoadChanged(WebKitLoadEvent load_event);

  void GoBack();

  void GoForward();

  void Reload();

  void StopLoading();

  FlValue* GetAllCookies();

  gboolean DecidePolicy(WebKitPolicyDecision *decision,
                        WebKitPolicyDecisionType type);

  void EvaluateJavaScript(const char *java_script, FlMethodCall *call);

 private:
  FlMethodChannel *method_channel_;
  int64_t window_id_;
  std::function<void()> on_close_callback_;

  std::string default_user_agent_;

  GtkWidget *window_ = nullptr;
  GtkWidget *webview_ = nullptr;
  GtkBox *box_ = nullptr;
};

#endif  // WEBVIEW_WINDOW_LINUX_WEBVIEW_WINDOW_H_
