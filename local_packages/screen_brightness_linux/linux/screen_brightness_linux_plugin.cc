#include "screen_brightness_linux_plugin.h" 

#include <gtk/gtk.h> 

#include <cstring>
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <algorithm> 
#include <chrono>   
#include <cmath> 

#define SCREEN_BRIGHTNESS_LINUX_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), screen_brightness_linux_plugin_get_type(), \
                              ScreenBrightnessLinuxPlugin))

namespace fs = std::filesystem;

struct _ScreenBrightnessLinuxPlugin {
  GObject parent_instance;
  FlMethodChannel* channel;
  StreamHandler* stream_handler; 
};

G_DEFINE_TYPE(ScreenBrightnessLinuxPlugin, screen_brightness_linux_plugin, g_object_get_type())

std::string get_backlight_device_path() {
  const std::string backlight_dir = "/sys/class/backlight/";
  try {
    if (fs::exists(backlight_dir) && fs::is_directory(backlight_dir)) {
      for (const auto& entry : fs::directory_iterator(backlight_dir)) {
        if (entry.is_directory() || entry.is_symlink()) {
          return entry.path().string();
        }
      }
    }
  } catch (const fs::filesystem_error& e) {
    std::cerr << "Filesystem error while finding backlight device: " << e.what() << std::endl;
    return "";
  }
  return "";
}

int read_int_from_file(const std::string& file_path) {
  std::ifstream file(file_path);
  if (!file.is_open()) { return -1; }
  int value = -1;
  file >> value;
  if (file.fail() && !file.eof()) { file.close(); return -1; }
  file.close();
  return value;
}

bool write_int_to_file(const std::string& file_path, int value) {
  std::ofstream file(file_path);
  if (!file.is_open()) { return false; }
  file << value;
  file.close();
  return !file.fail();
}

static void screen_brightness_linux_plugin_handle_method_call(
    FlMethodChannel* source_channel, 
    FlMethodCall* method_call,
    gpointer user_data) {
  (void)source_channel;
  (void)user_data;

  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "getSystemBrightness") == 0) {
    std::string device_path = get_backlight_device_path();
    if (device_path.empty()) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "UNAVAILABLE", "No backlight device found", nullptr));
    } else {
      int current_brightness = read_int_from_file(device_path + "/brightness");
      int max_brightness = read_int_from_file(device_path + "/max_brightness");
      if (current_brightness < 0 || max_brightness <= 0) { 
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "UNAVAILABLE", "Failed to read valid brightness values from device", nullptr));
      } else {
        double brightness_value = static_cast<double>(current_brightness) / max_brightness;
        g_autoptr(FlValue) result = fl_value_new_float(brightness_value);
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
      }
    }
  } else if (strcmp(method, "setSystemBrightness") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    if (fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "INVALID_ARGUMENT", "Argument must be a map", nullptr));
    } else {
      FlValue* brightness_value_fl = fl_value_lookup_string(args, "brightness");
      if (brightness_value_fl == nullptr || fl_value_get_type(brightness_value_fl) != FL_VALUE_TYPE_FLOAT) {
          response = FL_METHOD_RESPONSE(fl_method_error_response_new(
              "INVALID_ARGUMENT", "Brightness argument missing or not a float", nullptr));
      } else {
        double brightness_double = fl_value_get_float(brightness_value_fl);
        std::string device_path = get_backlight_device_path();
        if (device_path.empty()) {
          response = FL_METHOD_RESPONSE(fl_method_error_response_new(
              "UNAVAILABLE", "No backlight device found", nullptr));
        } else {
          int max_brightness = read_int_from_file(device_path + "/max_brightness");
          if (max_brightness <= 0) { 
            response = FL_METHOD_RESPONSE(fl_method_error_response_new(
                "UNAVAILABLE", "Failed to read valid max_brightness from device", nullptr));
          } else {
            int brightness_to_set = static_cast<int>(brightness_double * max_brightness);
            brightness_to_set = std::max(0, std::min(brightness_to_set, max_brightness));
            
            bool success = write_int_to_file(device_path + "/brightness", brightness_to_set);

            // If the target brightness was 0 AND the first write was successful,
            // perform a second write of 0. This works around an odd driver behavior
            // where writing 0 once doesn't always set the brightness to 0.
            if (brightness_to_set == 0 && success) {
                std::this_thread::sleep_for(std::chrono::milliseconds(130));
                success = write_int_to_file(device_path + "/brightness", 0);
            }

            if (!success) {
              response = FL_METHOD_RESPONSE(fl_method_error_response_new(
                  "IO_ERROR", "Failed to write brightness value (check permissions or device error after potential second attempt for 0)", nullptr));
            } else {
              response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
            }
          }
        }
      }
    }
  } else if (strcmp(method, "canChangeSystemBrightness") == 0) {
    std::string device_path = get_backlight_device_path();
    bool can_write = false;
    if (!device_path.empty()) {
        std::string brightness_file = device_path + "/brightness";
        std::ofstream test_write(brightness_file, std::ios_base::out | std::ios_base::app);
        if (test_write.is_open()) {
            can_write = true;
            test_write.close();
        }
    }
    g_autoptr(FlValue) result = fl_value_new_bool(can_write); 
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send method call response: %s", error->message);
  }
}

static void screen_brightness_linux_plugin_dispose(GObject* object) {
  ScreenBrightnessLinuxPlugin* self = SCREEN_BRIGHTNESS_LINUX_PLUGIN(object);
  if (self->stream_handler) {
    delete self->stream_handler; 
    self->stream_handler = nullptr;
  }
  g_clear_object(&self->channel);
  G_OBJECT_CLASS(screen_brightness_linux_plugin_parent_class)->dispose(object);
}

static void screen_brightness_linux_plugin_class_init(ScreenBrightnessLinuxPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = screen_brightness_linux_plugin_dispose;
}

static void screen_brightness_linux_plugin_init(ScreenBrightnessLinuxPlugin* self) {}

StreamHandler::StreamHandler(FlEventChannel* event_channel) 
    : event_channel_(FL_EVENT_CHANNEL(g_object_ref(event_channel))), 
      stop_polling_(false), 
      is_listening_(false) {
    fl_event_channel_set_stream_handlers(event_channel_,
                                         StreamHandler::OnListen_static,
                                         StreamHandler::OnCancel_static,
                                         this,  
                                         nullptr); 
}

StreamHandler::~StreamHandler() {
    stop_polling_ = true; 
    if (polling_thread_ && polling_thread_->joinable()) {
        polling_thread_->join();
    }
    if (event_channel_) {
        fl_event_channel_set_stream_handlers(event_channel_, nullptr, nullptr, nullptr, nullptr);
        g_object_unref(event_channel_);
        event_channel_ = nullptr;
    }
}

FlMethodErrorResponse* StreamHandler::OnListen_static(FlEventChannel* channel, FlValue* args, gpointer user_data) {
    StreamHandler* self = static_cast<StreamHandler*>(user_data);
    return self->OnListen(args);
}

FlMethodErrorResponse* StreamHandler::OnCancel_static(FlEventChannel* channel, FlValue* args, gpointer user_data) {
    StreamHandler* self = static_cast<StreamHandler*>(user_data);
    return self->OnCancel(args);
}

FlMethodErrorResponse* StreamHandler::OnListen(FlValue* args) {
    if (is_listening_) { 
        return fl_method_error_response_new("ALREADY_LISTENING", "Stream is already being listened to.", nullptr);
    }
    is_listening_ = true;
    stop_polling_ = false;
    
    last_known_brightness_ = GetCurrentBrightnessValue(); 
    
    if (event_channel_) { 
        if (last_known_brightness_ >= 0.0) { 
            g_autoptr(FlValue) fl_brightness = fl_value_new_float(last_known_brightness_);
            fl_event_channel_send(event_channel_, fl_brightness, nullptr, nullptr);
        } else {
            fl_event_channel_send_error(event_channel_, "UNAVAILABLE", "Brightness device not available on listen.", nullptr, nullptr, nullptr);
        }
    }

    polling_thread_ = std::make_unique<std::thread>(&StreamHandler::PollingThread, this);
    return nullptr; 
}

FlMethodErrorResponse* StreamHandler::OnCancel(FlValue* args) {
    if (!is_listening_) {
        return fl_method_error_response_new("NOT_LISTENING", "Stream is not being listened to.", nullptr);
    }
    is_listening_ = false;
    stop_polling_ = true; 
    if (polling_thread_ && polling_thread_->joinable()) {
        polling_thread_->join(); 
        polling_thread_.reset();  
    }
    last_known_brightness_ = -1.0; 
    return nullptr; 
}

double StreamHandler::GetCurrentBrightnessValue() {
    std::string device_path = get_backlight_device_path();
    if (device_path.empty()) { return -1.0; }
    int current_brightness = read_int_from_file(device_path + "/brightness");
    int max_brightness = read_int_from_file(device_path + "/max_brightness");
    if (current_brightness < 0 || max_brightness <= 0) { return -1.0; }
    return static_cast<double>(current_brightness) / max_brightness;
}

void StreamHandler::PollingThread() {
    while (!stop_polling_) {
        std::this_thread::sleep_for(std::chrono::milliseconds(500)); 
        if (stop_polling_ || !is_listening_ || !event_channel_) { 
            break;
        }

        double current_brightness = GetCurrentBrightnessValue();
        bool send_update = false;
        bool send_error = false;

        if (current_brightness >= 0.0) {
            if (std::abs(current_brightness - last_known_brightness_) > 0.001) { 
                 last_known_brightness_ = current_brightness;
                 send_update = true;
            }
        } else { 
            if (last_known_brightness_ >= 0.0) { 
                last_known_brightness_ = -1.0; 
                send_error = true;
            }
        }
        
        if (send_update) {
             if (is_listening_ && event_channel_ && !stop_polling_) { 
                 g_autoptr(FlValue) fl_brightness = fl_value_new_float(last_known_brightness_);
                 fl_event_channel_send(event_channel_, fl_brightness, nullptr, nullptr);
             }
        } else if (send_error) {
            if (is_listening_ && event_channel_ && !stop_polling_) {
                fl_event_channel_send_error(event_channel_, "UNAVAILABLE", "Brightness device became unavailable or error reading.", nullptr, nullptr, nullptr);
            }
        }
    }
}

void screen_brightness_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  ScreenBrightnessLinuxPlugin* plugin = SCREEN_BRIGHTNESS_LINUX_PLUGIN(
      g_object_new(screen_brightness_linux_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "screen_brightness_linux", FL_METHOD_CODEC(codec));
  
  fl_method_channel_set_method_call_handler(plugin->channel, 
                                            screen_brightness_linux_plugin_handle_method_call,
                                            g_object_ref(plugin), 
                                            g_object_unref);      

  g_autofree gchar* event_channel_name = g_strconcat("screen_brightness_linux_stream", nullptr);
  FlEventChannel* event_channel = fl_event_channel_new(fl_plugin_registrar_get_messenger(registrar),
                                                       event_channel_name,
                                                       FL_METHOD_CODEC(codec));
  plugin->stream_handler = new StreamHandler(event_channel); 
  
  g_object_unref(plugin); 
}
