// fm-call-mic-in-use.c - print every process that is capturing audio input right now.
// One line per process: PID<TAB>bundle id (bundle id may be empty).
// Asks coreaudiod directly (macOS 14.2+ process objects), so it costs a few
// milliseconds instead of a unified-log scan.
// bin/fm-call-watch.sh builds it on first use into state/calls/mic-in-use:
//   clang -O2 -framework CoreAudio -framework CoreFoundation -o mic-in-use fm-call-mic-in-use.c
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

static AudioObjectPropertyAddress addr(AudioObjectPropertySelector selector) {
  AudioObjectPropertyAddress a = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  return a;
}

int main(void) {
  AudioObjectPropertyAddress list = addr(kAudioHardwarePropertyProcessObjectList);
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &list, 0, NULL, &size) != noErr) {
    fprintf(stderr, "mic-in-use: cannot read the CoreAudio process list\n");
    return 1;
  }
  UInt32 count = size / sizeof(AudioObjectID);
  if (count == 0) return 0;
  AudioObjectID *objects = calloc(count, sizeof(AudioObjectID));
  if (!objects) return 1;
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &list, 0, NULL, &size, objects) != noErr) {
    fprintf(stderr, "mic-in-use: cannot read the CoreAudio process list\n");
    free(objects);
    return 1;
  }
  count = size / sizeof(AudioObjectID);
  for (UInt32 i = 0; i < count; i++) {
    AudioObjectPropertyAddress running = addr(kAudioProcessPropertyIsRunningInput);
    UInt32 is_running = 0, len = sizeof(is_running);
    if (AudioObjectGetPropertyData(objects[i], &running, 0, NULL, &len, &is_running) != noErr || !is_running) continue;
    AudioObjectPropertyAddress pid_addr = addr(kAudioProcessPropertyPID);
    pid_t pid = 0;
    len = sizeof(pid);
    if (AudioObjectGetPropertyData(objects[i], &pid_addr, 0, NULL, &len, &pid) != noErr) continue;
    char bundle[512] = "";
    AudioObjectPropertyAddress bundle_addr = addr(kAudioProcessPropertyBundleID);
    CFStringRef bundle_ref = NULL;
    len = sizeof(bundle_ref);
    if (AudioObjectGetPropertyData(objects[i], &bundle_addr, 0, NULL, &len, &bundle_ref) == noErr && bundle_ref) {
      CFStringGetCString(bundle_ref, bundle, sizeof(bundle), kCFStringEncodingUTF8);
      CFRelease(bundle_ref);
    }
    printf("%d\t%s\n", (int)pid, bundle);
  }
  free(objects);
  return 0;
}
