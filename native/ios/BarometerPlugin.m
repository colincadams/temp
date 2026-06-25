// Registers BarometerPlugin (Swift) with Capacitor so JS can reach it as the
// "Barometer" plugin. Capacitor discovers any CAP_PLUGIN registration compiled
// into the app target, so dropping this file + BarometerPlugin.swift into the
// App target is all that's needed — no Podspec required for an in-app plugin.
#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

CAP_PLUGIN(BarometerPlugin, "Barometer",
    CAP_PLUGIN_METHOD(isAvailable, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(start, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(stop, CAPPluginReturnPromise);
)
