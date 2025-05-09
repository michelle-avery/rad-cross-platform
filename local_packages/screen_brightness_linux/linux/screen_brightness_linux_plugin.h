#ifndef FLUTTER_PLUGIN_SCREEN_BRIGHTNESS_LINUX_PLUGIN_H_
#define FLUTTER_PLUGIN_SCREEN_BRIGHTNESS_LINUX_PLUGIN_H_

#include <flutter_linux/flutter_linux.h> 

#include <string>
#include <memory> 
#include <atomic> 
#include <thread> 

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

G_DECLARE_FINAL_TYPE(ScreenBrightnessLinuxPlugin, screen_brightness_linux_plugin,
                     SCREEN_BRIGHTNESS_LINUX, PLUGIN, GObject)

FLUTTER_PLUGIN_EXPORT ScreenBrightnessLinuxPlugin* screen_brightness_linux_plugin_new(
    FlPluginRegistrar* registrar);

FLUTTER_PLUGIN_EXPORT void screen_brightness_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

class StreamHandler {
public:
    StreamHandler(FlEventChannel* event_channel); 
    ~StreamHandler();

    static FlMethodErrorResponse* OnListen_static(FlEventChannel* channel, FlValue* args, gpointer user_data);
    static FlMethodErrorResponse* OnCancel_static(FlEventChannel* channel, FlValue* args, gpointer user_data);

private:
    FlMethodErrorResponse* OnListen(FlValue* args);
    FlMethodErrorResponse* OnCancel(FlValue* args);

    void PollingThread();
    double GetCurrentBrightnessValue();

    FlEventChannel* event_channel_ = nullptr; 
    std::unique_ptr<std::thread> polling_thread_;
    std::atomic_bool stop_polling_;
    double last_known_brightness_ = -1.0;
    bool is_listening_ = false; 
};

#endif  // FLUTTER_PLUGIN_SCREEN_BRIGHTNESS_LINUX_PLUGIN_H_
